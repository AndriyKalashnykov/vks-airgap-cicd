#!/usr/bin/env bash
# check-kind-kubeconfig.sh — a `kind` invocation must never write the AMBIENT $KUBECONFIG.
#
# WHY (2026-08-26). kind writes to $KUBECONFIG when --kubeconfig is absent -- its own help:
# "--kubeconfig string  sets kubeconfig path instead of $KUBECONFIG or $HOME/.kube/config".
# load_env applies the REAL-LAB path as a CODE default (lib/os.sh:692), so $KUBECONFIG is a LAB slot
# on any lab box, and after the scenario docs' `export KUBECONFIG=./secrets/supervisor.kubeconfig`
# (scenario-1.md:322, scenario-2.md:148) it is the SUPERVISOR.
#
# MEASURED, kind v0.32.0 -- kind MERGES, so nothing is lost; the damage is a CONTEXT HIJACK:
#   create -> adds its entries and repoints `current-context` to `kind-<name>`
#   delete -> removes its own entries; if `current-context` was the kind one, DELETES THE KEY
#             ("current-context is not set" on every later bare kubectl). With no `kind-*` entries
#             present the file comes back BYTE-IDENTICAL, so fixing CREATE defuses DELETE.
# Sharp victim: a SCENARIO-2 tenant, whose $KUBECONFIG is secrets/vks.kubeconfig -- the credential
# the platform team HANDED them, which they cannot self-service (CLAUDE.md RULE ZERO-A0).
#
# THE PREDICATE IS ORDERING, NOT A FLAG, AND THAT IS THE WHOLE POINT. The first version of this gate
# grepped each call for `--kubeconfig` and was BLIND to the actual defect: 05-kind-up.sh assembles
# the subcommand in an ARRAY (`create_args=(create cluster ...)`; `run kind "${create_args[@]}"`), so
# the string `kind create` never appears. Measured: that gate returned the SAME 6-of-6 clean on the
# fixed AND the unfixed tree -- it would have shipped green over the bug it was written for.
#
# Predicate, per `kind` invocation at a command position (comments stripped):
#   SAFE if the line carries --kubeconfig, OR a NON-DEFAULTING `export KUBECONFIG=` appears EARLIER.
# KNOWN FP CLASSES (line-oriented scan, stated not hidden): a `\`-continuation whose --kubeconfig
# is on the NEXT line; a TRAILING comment that quotes a kind command; heredoc prose. Only a
# whole-line `#` is skipped.
#   Read-only verbs (get/version/build/completion/--help) are exempt: they do not write a kubeconfig.
#   An UNKNOWN or VARIABLE verb is NOT exempt -- that is the array case, and it must be covered.
#
# RED-PROOF: delete the early `export KUBECONFIG="$KUBECONFIG_PATH"` from scripts/05-kind-up.sh.
# `run kind "${create_args[@]}"` then has neither cover -> this gate must exit non-zero and name it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Composed so this gate's OWN source contributes no match (the first version counted its own line 45).
K="$(printf 'ki%s' 'nd')"
# The command-position grammar, SINGLE-SOURCED because the matcher and the verb-extractor must
# agree. It is the shape hooks.md already publishes: line start or after ; & | ` $( , then any
# number of env-assignments / modifier words / a sudo with flags, then an optional absolute path.
# The old version had only `run|sudo` and MISSED 9 real shapes -- including `if kind delete`,
# which is ALREADY the idiom at 05-kind-up.sh:76.
CMDPOS='(^|[;&|`]|\$\()[[:space:]]*(if[[:space:]]+|while[[:space:]]+|until[[:space:]]+|then[[:space:]]+|else[[:space:]]+|do[[:space:]]+|![[:space:]]*|run[[:space:]]+|env[[:space:]]+|exec[[:space:]]+|command[[:space:]]+|time[[:space:]]+|sudo[[:space:]]+(-[A-Za-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(/[^[:space:]]*/)?'

# kind's REAL verb set (`kind --help`): build completion create delete export get help load version.
# The enumerated list was WRONG and the error was ASYMMETRIC: `kind load docker-image` and
# `kind export logs` were flagged, and NEITHER accepts --kubeconfig (measured: 0 occurrences in their
# --help) -- so the only way to go green was a SPURIOUS `export KUBECONFIG=`, i.e. a gate whose only
# remedy degrades the artifact. `kind load docker-image` is a predictable addition here: CLAUDE.md's
# own gotcha table names it.
# NOT exempt: create, delete, `export kubeconfig`, and any UNKNOWN/variable verb (the array case).
READONLY_VERBS=" get version build completion help load "

files=$(git ls-files 'scripts/*.sh' 'scripts/**/*.sh' 'Makefile' 2>/dev/null) || files=""
[ -n "$files" ] || { echo "check-kind-kubeconfig: ERROR — could not list tracked files" >&2; exit 2; }

fail=0 seen=0 covered=0 exempt=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  # ⚠️ A DEFAULTING EXPORT IS NOT COVER, AND THIS IS THE WHOLE DIFFERENCE BETWEEN A GATE AND A
  # FORMALITY. `export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_PATH}"` re-introduces the exact bug --
  # MEASURED: `load_env` ALWAYS leaves KUBECONFIG non-empty (unset -> the lab slot via os.sh:692;
  # set -> the caller's), so the `:-` branch is DEAD and the ambient value wins 100% of runs. It is
  # also the edit a future session is most likely to make, because os.sh:679-692 argues FOR honouring
  # a caller's KUBECONFIG. So: reject any export whose RHS mentions ${KUBECONFIG.
  # shellcheck disable=SC2016  # '${KUBECONFIG' is a LITERAL to match in the file, not an expansion.
  exp_line=$(grep -nE '^[[:space:]]*export[[:space:]]+KUBECONFIG=' "$f" 2>/dev/null \
               | grep -v '\${KUBECONFIG' | head -1 | cut -d: -f1)
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '#'*|'') continue ;; esac
    # a `kind` invocation at a command position: line start, or after ; & | ` $( or `run `
    printf '%s' "$line" | grep -qE "${CMDPOS}${K}[[:space:]]" || continue
    # NOTE the delimiter is `#`, not `/`: the command-position group contains `/` (absolute
    # paths), and an unescaped delimiter inside the pattern is a classic sed footgun.
    verb=$(printf '%s' "$line" | sed -E "s#.*${CMDPOS}${K}[[:space:]]+##" | awk '{print $1}')
    case "$READONLY_VERBS" in *" $verb "*) exempt=$((exempt + 1)); continue ;; esac
    # `export` splits by SUBCOMMAND: `export logs` writes no kubeconfig, `export kubeconfig` does.
    if [ "$verb" = export ]; then
      sub=$(printf '%s' "$line" | sed -E "s#.*${K}[[:space:]]+export[[:space:]]+##" | awk '{print $1}')
      [ "$sub" = logs ] && { exempt=$((exempt + 1)); continue; }
    fi
    seen=$((seen + 1))
    if printf '%s' "$line" | grep -q -- '--kubeconfig'; then covered=$((covered + 1)); continue; fi
    if [ -n "$exp_line" ] && [ "$exp_line" -lt "$n" ]; then covered=$((covered + 1)); continue; fi
    fail=1
    # shellcheck disable=SC2016  # the $ below is PROSE about the variable, not an expansion.
    printf 'check-kind-kubeconfig: %s:%s — a kind invocation with NO --kubeconfig and no preceding `export KUBECONFIG=`\n' "$f" "$n" >&2
    printf '    %s\n' "$(printf '%s' "$trimmed" | cut -c1-110)" >&2
    # shellcheck disable=SC2016  # ditto — prose, not an expansion.
    printf '    It writes the AMBIENT $KUBECONFIG, which on a lab box is a LAB slot (lib/os.sh:692).\n' >&2
  done < <(cat "$f"; printf '\n')   # a final line with NO trailing newline was silently DROPPED
done <<< "$files"

if [ "$seen" -eq 0 ]; then
  echo "check-kind-kubeconfig: ERROR — zero writing kind invocations found; the matcher is broken, not the tree." >&2
  exit 2
fi
[ "$fail" -eq 0 ] || exit 1
echo "check-kind-kubeconfig: clean ($covered of $seen writing kind invocation(s) covered; $exempt read-only exempt)"
