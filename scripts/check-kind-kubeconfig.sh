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
#   SAFE if the line carries --kubeconfig, OR an `export KUBECONFIG=` appears EARLIER in the file.
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
READONLY_VERBS=" get version build completion "

files=$(git ls-files 'scripts/*.sh' 'scripts/**/*.sh' 'Makefile' 2>/dev/null) || files=""
[ -n "$files" ] || { echo "check-kind-kubeconfig: ERROR — could not list tracked files" >&2; exit 2; }

fail=0 seen=0 covered=0 exempt=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  exp_line=$(grep -nE '^[[:space:]]*export[[:space:]]+KUBECONFIG=' "$f" 2>/dev/null | head -1 | cut -d: -f1)
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in '#'*|'') continue ;; esac
    # a `kind` invocation at a command position: line start, or after ; & | ` $( or `run `
    printf '%s' "$line" | grep -qE "(^|[;&|\`]|\\\$\()[[:space:]]*(run[[:space:]]+|sudo[[:space:]]+)*${K}[[:space:]]" || continue
    verb=$(printf '%s' "$line" | sed -E "s/.*(^|[;&|\`]|\\\$\()[[:space:]]*(run[[:space:]]+|sudo[[:space:]]+)*${K}[[:space:]]+//" | awk '{print $1}')
    case "$READONLY_VERBS" in *" $verb "*) exempt=$((exempt + 1)); continue ;; esac
    seen=$((seen + 1))
    if printf '%s' "$line" | grep -q -- '--kubeconfig'; then covered=$((covered + 1)); continue; fi
    if [ -n "$exp_line" ] && [ "$exp_line" -lt "$n" ]; then covered=$((covered + 1)); continue; fi
    fail=1
    printf 'check-kind-kubeconfig: %s:%s — a kind invocation with NO --kubeconfig and no preceding `export KUBECONFIG=`\n' "$f" "$n" >&2
    printf '    %s\n' "$(printf '%s' "$trimmed" | cut -c1-110)" >&2
    printf '    It writes the AMBIENT $KUBECONFIG, which on a lab box is a LAB slot (lib/os.sh:692).\n' >&2
  done < "$f"
done <<< "$files"

if [ "$seen" -eq 0 ]; then
  echo "check-kind-kubeconfig: ERROR — zero writing kind invocations found; the matcher is broken, not the tree." >&2
  exit 2
fi
[ "$fail" -eq 0 ] || exit 1
echo "check-kind-kubeconfig: clean ($covered of $seen writing kind invocation(s) covered; $exempt read-only exempt)"
