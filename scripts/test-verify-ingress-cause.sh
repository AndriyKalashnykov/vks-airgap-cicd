#!/usr/bin/env bash
# test-verify-ingress-cause.sh — when there is no ingress address, the abort must name EVERY cause
# that can produce that state, not just the one that is usually true.
#
# WHY. The old message was `INGRESS_LB_IP not set — run 'make install-ingress' first`. That is right
# when the operator simply has not installed one, and MISLEADING in the two other reachable states:
#
#   * a scenario walk SKIPPED both install branches because `make istio-preflight` was inconclusive.
#     The harness DECLINED to pick a branch on purpose ("a walk must not guess"); telling the
#     operator to run the command it declined sends them to do the one thing the preflight could not
#     justify, against a mesh they may not own.
#   * `state_check` REFUSED the overlay (stamped for a different cluster). The value exists on disk
#     and is not in scope. The loader prints its OWN error block immediately above this one, and
#     without naming that case here the two messages read as unrelated -- which is exactly how a
#     session spent time diagnosing the wrong thing.
#
# This repo treats a diagnostic naming the wrong cause as worse than a crash: it sends someone to fix
# a thing that is not broken.
#
# HONESTY: this asserts the ABORT PATH only. It runs the script with no ingress address, so it never
# reaches a cluster and proves nothing about the route checks themselves -- those need `make
# verify-ingress` against a live install.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT

# ⚠️ SANDBOXING THE STATE OVERLAY IS THE WHOLE FIXTURE, and a first version got it wrong in the way
# this repo keeps getting it wrong: it set `INGRESS_LB_IP=''` in the environment and assumed that was
# the state under test. `load_env` sources the overlay with `set -a` AFTER the environment is
# established, so the KinD overlay's `INGRESS_LB_IP=172.18.0.6` silently REPLACED it -- and the test
# then ran the REAL route check against whatever cluster happened to be up on the author's box and
# reported SUCCESS. Measured: `SUCCESS — all 8 UI(s) reachable ... at 172.18.0.6`, rc=0, from a test
# whose entire subject is the abort path. A test that passes because of the developer's machine is
# not a passing test.
#
# `VKS_STATE_FILE` points at a path that does not exist, so there is no overlay to source;
# SKIP_DOTENV keeps the operator's own .env out; KUBECONFIG is a nonexistent path so nothing dials.
out="$T/out.txt"
( cd "$T" && SKIP_DOTENV=1 \
             VKS_STATE_FILE="$T/no-such.state" \
             KUBECONFIG="$T/no-such.kubeconfig" \
             INGRESS_LB_IP='' \
             timeout 60 bash "$SCRIPT_DIR/98-verify-ingress.sh" ) > "$out" 2>&1
rc=$?
# The sandbox is a POSITIVE CONTROL, not an assumption: if the overlay leaked in, the script reaches
# the route checks and this suite would be asserting nothing.
if grep -q 'reachable through the' "$out"; then
  bad "the state overlay LEAKED into the fixture — this run verified a real cluster instead of the abort path, so every assertion below is vacuous"
fi

# `if`, not `A && B || C`: that form runs C when B fails too, and this repo bans it outright.
if [ "$rc" -ne 0 ]; then ok "it ABORTS when there is no ingress address"
else bad "it exited 0 with no ingress address — nothing was verified and it said so quietly"; fi

# The three causes, asserted by the DISTINGUISHING phrase of each rather than by a line number, so a
# reworded message still passes and a DELETED cause does not.
if grep -q 'make install-ingress'        "$out"; then ok "names cause 1: no ingress installed yet"
else bad "cause 1 (not installed) is gone — the common case has no remedy"; fi
if grep -q 'istio-preflight'             "$out"; then ok "names cause 2: the walk skipped the install (inconclusive preflight)"
else bad "cause 2 is gone — a walk that DECLINED to guess is told to guess"; fi
if grep -qi 'refused'                    "$out"; then ok "names cause 3: the state overlay was refused"
else bad "cause 3 is gone — the loader's own ERROR above this one reads as unrelated"; fi
# ...and it must not tell the operator to do the thing the preflight could not justify.
if grep -q 'do NOT just pick a branch'   "$out"; then ok "and it warns against picking a branch the preflight did not name"
else bad "the branch warning is gone"; fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
