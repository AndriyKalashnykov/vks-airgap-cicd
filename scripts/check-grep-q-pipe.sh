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
# "$var" | grep -q` is bounded by the variable, and MEASURED that boundary is structural, not a
# hope: below the 64KB pipe buffer the producer's write COMPLETES and SIGPIPE cannot occur
# (4KB: 0/120), and data with NO NEWLINES is immune at ANY size (3MB single-line: 0/120) because
# grep buffers hunting a line terminator and thereby drains the producer. Risk needs >32KB AND
# multiline (82KB multiline: 120/120). ~70 such sites remain and NONE qualifies, so they are
# deliberately NOT converted -- see backlog B52, closed on that measurement.
#
# DO NOT "fix" them with a `<<<` herestring sweep: `printf '%s' "$v"` on an EMPTY value emits zero
# bytes (rc=1) while `<<< "$v"` emits ONE EMPTY LINE, so every nullable pattern ('' ^$ .* ^ $ x*)
# flips rc 1 -> 0. Several of those sites are `if`-conditions in TESTS, where that flip is a silent
# verdict change -- a false green in a test, the worst place for one.
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
# EXTERNAL producers whose output size we do NOT control: a cluster's object list, a box's container
# list. Added 2026-07-19 after an adversary showed the gate was aimed BACKWARDS -- it banned the
# file readers (all converted, all small) while waving through `kubectl get -A | grep -q` and
# `docker ps -a | grep -q`, the only sites in the repo that can plausibly cross the threshold.
# These need no path argument to be unbounded, so they are matched on the command alone.
_EXTERNAL='kubectl|docker|kind|helm|crane|curl|argocd|tkn|podman'

# The two matchers are named ONCE, here, so the positive control below and the scan loop provably
# use the SAME regex. A control that tested a COPY of the pattern would stay green while the real
# matcher rotted — the copy is the thing that drifts.
_RE_PIPE="\| *${_Q}"
_RE_FILE="(^|[^a-zA-Z0-9_-])(${_FILE_READERS})[^|]*(\"[^\"]*/[^\"]*\"|[A-Za-z0-9_./-]*/[A-Za-z0-9_.-]+)[^|]*\| *${_Q}"
_RE_EXT="(^|[^a-zA-Z0-9_-])(${_EXTERNAL})[[:space:]][^|]*\| *${_Q}"

# --- POSITIVE CONTROL -----------------------------------------------------------------------
# This gate's only other assertion is `hits == 0` — a NEGATIVE, which passes just as happily when
# the matcher is DEAD as when the tree is clean. MEASURED 2026-07-21 by an adversary: setting
# _FILE_READERS to a string matching nothing still returned rc=0, "OK — scanned 125 script(s)".
# The gate is also UNDECLARED in test-gate-vacuity, so nothing else covers it. So: assert the
# matcher FIRES on a known-bad line and STAYS SILENT on a line this gate deliberately allows,
# before any scan result is trusted. (testing.md: a negative assertion needs a positive control —
# otherwise "the defence worked" and "the threat never fired" are the same green.)
# The fixtures are built from ${_Q} rather than written literally, for the same reason the patterns
# are composed at runtime: this file must not contain the form it hunts, or it flags itself.
_ctl_file="  cat scripts/foo.sh | ${_Q} pattern"
_ctl_ext="  kubectl get pods -A | ${_Q} pattern"
_ctl_ok="  printf '%s' \"\$v\" | ${_Q} pattern"
if ! [[ $_ctl_file =~ $_RE_FILE ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the file-reader matcher did not fire on a known-bad line. The matcher is dead; every result below would be a vacuous green."
fi
if ! [[ $_ctl_ext =~ $_RE_EXT ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the external-producer matcher did not fire on a known-bad line. The matcher is dead; every result below would be a vacuous green."
fi
if [[ $_ctl_ok =~ $_RE_FILE ]] || [[ $_ctl_ok =~ $_RE_EXT ]]; then
  die "check-grep-q-pipe: POSITIVE CONTROL FAILED — the matcher fired on a bounded \$var producer, which this gate deliberately does NOT judge (see SCOPE). It would now flag safe code."
fi

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
    # Builtins, not `printf | sed | cut` + `printf | grep` — that forked FOUR processes per line.
    # The strip is correctness-critical here, not just speed: this file's own header contains the
    # literal bug form, so a broken strip makes the gate flag itself (loud, safe).
    _s=${line#"${line%%[![:space:]]*}"}
    case $_s in '#'*) continue ;; esac
    [[ $line =~ $_RE_PIPE ]] || continue
    # A file-reading producer with a PATH-shaped argument before the pipe. `"$x"`/`$x` alone is a
    # variable, which this gate deliberately does not judge (see SCOPE above).
    # The prefix is a NON-WORD boundary, not a command separator: the producer is routinely preceded
    # by `if `/`elif `/`! `/`while `, and requiring `[|;&(]` missed every one of them (RED-proven).
    # RHS UNQUOTED — a quoted RHS is a LITERAL comparison, which matches nothing and would make this
    # gate a vacuous green. The POSITIVE CONTROL above is what catches that; it did not exist before
    # 2026-07-21, and a dead matcher here returned rc=0 "OK — scanned 125 script(s)".
    if [[ $line =~ $_RE_FILE ]] || [[ $line =~ $_RE_EXT ]]; then
      log_error "  ${f}: an UNBOUNDED producer (a file reader, or kubectl/docker/kind/helm/crane/curl) pipes into ${_Q} — under pipefail this reports a FOUND pattern as ABSENT, at random, and reports a real violation as CLEAN."
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
log_info "check-grep-q-pipe: OK — no FILE-READING or EXTERNAL (kubectl/docker/kind/helm/crane/curl) producer pipes into ${_Q} (scanned ${scanned} script(s)). SCOPE: bounded \$var producers are NOT judged — measured structurally safe (<32KB or single-line); see the header before \"fixing\" them."
