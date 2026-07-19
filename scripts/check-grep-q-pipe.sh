#!/usr/bin/env bash
# check-grep-q-pipe.sh — no FILE-READING producer may pipe into `grep -q` under `set -o pipefail`.
#
# THE BUG, MEASURED. `grep -q` exits at its FIRST match. The producer still holding unissued writes
# then takes SIGPIPE and exits 141, and `set -o pipefail` promotes that to the pipeline's status —
# so a pattern that was FOUND is reported ABSENT. It is a RACE: the producer does not need to block,
# it only needs an outstanding write when grep leaves.
#
#   sed 's/#.*//' scripts/lib/istio.sh | grep -qE '^[[:space:]]*ensure_namespace…'
#     PIPESTATUS=(141 0)   <- grep MATCHED (0). sed died. Pipeline reports non-zero. The gate lies.
#
# WHY IT IS CI-ONLY AND LOOKS LIKE A GHOST. On an idle 24-core box: 0/200. Pinned to ONE cpu (the
# closest local analogue of a 2-vCPU runner): 11/400 = 2.75%. With ~9 rolls per CI job the cumulative
# failure rate is tens of percent — so it "passes locally, fails in CI, passes on rerun", which is
# exactly the shape that gets misfiled as flake. It cost this session SEVEN refuted hypotheses,
# including one where I "refuted" the correct diagnosis by measuring an idle machine.
#
# WHY IT HIT ONLY ONE ROW. Exposure is the bytes the producer still owes AFTER the match:
#   40-install-gitea 1390 · 41-install-tekton 932 · 60-configure-tekton 2730 · 45-install-traefik 2337
#   lib/istio.sh 13802   <- 5x the next, and the only row that ever failed. Not special. Just wider.
#
# IT PRODUCES FALSE GREENS, NOT ONLY FALSE REDS — and that is the reason this is a gate. When the
# match is the OFFENDER (a scan for a forbidden pattern), SIGPIPE silently un-records a real
# violation. Measured on the gate enforcing this repo's headline "docker is NEVER required"
# invariant: 7/300 runs reported CLEAN over a script that plainly required docker.
#
# WHY A GATE AND NOT A RULE. The rule already exists in the portfolio corpus AND is written out in
# THREE places in this repo (99-verify.sh, test-argocd-topology.sh, lib/istio.sh) — and it recurred
# anyway. Worse, one of those three "fixes" was itself wrong (`printf | grep -q`, which still
# SIGPIPEs on a large variable). Prose demonstrably did not hold.
#
# SCOPE, STATED HONESTLY — this covers the UNBOUNDED case only. A producer that READS A FILE can owe
# arbitrarily many bytes, so it is always a latent lie; that is what is banned here. A `printf '%s'
# "$var" | grep -q` is bounded by the variable and is usually tiny — but it is NOT safe in principle
# (bash forks the builtin into a subshell that takes the signal; a large page or log reproduces it),
# and 60 such sites remain unconverted (counted). They are a backlog row, not a silent exemption. Do not read
# this gate's green as "the repo is free of this class".
#
# THE FIX, both forms measured 400/400 clean under the same race:
#   grep -q PAT <<< "$(producer)"      # bash spools the herestring; nothing to SIGPIPE
#   producer | grep PAT >/dev/null     # no -q: grep DRAINS its input, so the producer never SIGPIPEs
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# Producers that read a FILE (unbounded output). Composed at runtime for the same reason the
# namespace chokepoint gate composes its patterns: a gate that is a script in the tree it scans must
# not contain the form it hunts, or it flags itself — and the reflex fix (excluding this file) would
# blind it to every future real finding here.
_Q="$(printf 'grep -%s' 'q')"
_FILE_READERS='sed|awk|cut|cat|head|tail|tr|sort|uniq|grep'

scanned=0; hits=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  n=0
  # FOLD BACKSLASH-CONTINUATIONS FIRST. The real CI failure was written across two lines —
  #     if sed 's/#.*//' "scripts/${script}" 2>/dev/null \
  #          | grep -qE "…"; then
  # so a line-at-a-time scan sees `| grep -q` with NO producer on that line and waves it through.
  # A first version of this gate did exactly that and passed BOTH RED-proofs; it was decorative.
  # `sed -e :a -e '/\\$/N; s/\\\n//; ta'` joins each continued logical line into one.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1)" in '#') continue ;; esac
    printf '%s' "$line" | grep -qE "\| *${_Q}" || continue
    # A file-reading producer with a PATH-shaped argument before the pipe. `"$x"`/`$x` alone is a
    # variable, which this gate deliberately does not judge (see SCOPE above).
    # The prefix is a NON-WORD boundary, not a command separator: the producer is routinely preceded
    # by `if `/`elif `/`! `/`while `, and requiring `[|;&(]` missed every one of them (RED-proven).
    if printf '%s' "$line" | grep -qE "(^|[^a-zA-Z0-9_-])(${_FILE_READERS})[^|]*(\"[^\"]*/[^\"]*\"|[A-Za-z0-9_./-]*/[A-Za-z0-9_.-]+)[^|]*\| *${_Q}"; then
      log_error "  ${f}: a FILE-READING producer pipes into ${_Q} — under pipefail this reports a FOUND pattern as ABSENT, at random, and reports a real violation as CLEAN."
      log_error "      ${line}"
      n=$((n + 1))
    fi
  done < <(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$f")
  hits=$((hits + n))
done <<EOF
$(git ls-files 'scripts/*.sh' 2>/dev/null)
EOF

# Denominator + zero-guard on the ITEM count, not the file count — the distinction B49 exists over.
[ "$scanned" -gt 0 ] || die "check-grep-q-pipe: scanned 0 files — the pathspec is broken and a green here would mean nothing."

# SELF-TEST: this file must contribute zero hits, or the runtime composition has been undone.
if [ "$hits" -gt 0 ]; then
  log_error "check-grep-q-pipe: FAILED — ${hits} site(s) across ${scanned} scanned file(s)."
  log_error "  Fix with EITHER form (both measured 400/400 clean under the race):"
  log_error "    grep -q PAT <<< \"\$(producer)\"       # bash spools it; nothing to SIGPIPE"
  log_error "    producer | grep PAT >/dev/null       # no -q: grep drains, producer never SIGPIPEs"
  exit 1
fi
log_info "check-grep-q-pipe: OK — no file-reading producer pipes into ${_Q} (scanned ${scanned} script(s)). SCOPE: bounded \$var producers are NOT judged here; 60 remain, none large (see the header)."
