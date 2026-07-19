#!/usr/bin/env bash
# test-run-sentinel.sh — offline RED-proof for assert_run_sentinel (lib/os.sh).
#
# WHY THIS EXISTS. assert_run_sentinel guards the jump-box harness, whose real RED costs a KinD
# cluster, a mirrored Harbor and an 8-40 minute container run. A gate whose RED takes forty minutes
# is a gate that gets proven once, if ever — and this repo's rule is that a gate's value IS its
# demonstrated RED. So the assertion is a pure function over (log, expected), and its REDs are
# proven here against fixture logs, offline, in milliseconds, inside static-check.
#
# The contaminant cases are the substantive ones. The harness bind-mounts the repo at /src, so the
# sentinel's own SOURCE line is reachable inside the container; an xtrace-enabled debug run would
# echo the token; and a gate that greps for the token prints file:line:<the echo>. If any of those
# satisfied the assertion it would be self-satisfying — green because the string exists somewhere,
# not because the run reached its end.
#
# shellcheck shell=bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"

fail=0; ran=0
ok()  { printf 'ok    %s\n' "$1"; ran=$((ran + 1)); }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

expect_pass() {
  if assert_run_sentinel "$2" JUMPBOX_OK >/dev/null 2>&1; then ok "$1"
  else bad "$1 — assert_run_sentinel REJECTED a log it must accept"; fi
}
expect_fail() {
  if assert_run_sentinel "$2" JUMPBOX_OK >/dev/null 2>&1; then
    bad "$1 — assert_run_sentinel ACCEPTED a log it must reject"
  else ok "$1"; fi
}

# --- the genuine article ---------------------------------------------------------------------
printf '### 4/4 done ###\nJUMPBOX_OK\n' > "$T/genuine"
expect_pass "a genuine end-of-work sentinel is accepted" "$T/genuine"

printf 'lots\nof\noutput\nJUMPBOX_OK\ntrailing chatter\n' > "$T/midlog"
expect_pass "the sentinel is accepted anywhere in the log, not only last" "$T/midlog"

# --- the early-exit case this control EXISTS for ----------------------------------------------
printf '### 1/4 make deps ###\nok\n### 2/4 ###\nok\n' > "$T/earlyexit"
expect_fail "a run that exited 0 WITHOUT reaching its end is rejected" "$T/earlyexit"

# --- contaminants: the string is present, the run did NOT reach its end ------------------------
printf '+ echo JUMPBOX_OK\n' > "$T/xtrace"
expect_fail "an xtrace echo of the sentinel does NOT satisfy it" "$T/xtrace"

printf 'scripts/jumpbox-run.sh:286:echo "JUMPBOX_OK"\n' > "$T/grephit"
expect_fail "a grep hit naming the sentinel's own source line does NOT satisfy it" "$T/grephit"

printf '  echo "JUMPBOX_OK"\n' > "$T/srcline"
expect_fail "the sentinel's indented SOURCE line does NOT satisfy it" "$T/srcline"

printf '### JUMPBOX_OK reached ###\n' > "$T/banner"
expect_fail "a banner mentioning the sentinel does NOT satisfy it" "$T/banner"

printf 'JUMPBOX_OK_BUT_NOT_REALLY\n' > "$T/prefix"
expect_fail "a longer token with the sentinel as a PREFIX does NOT satisfy it" "$T/prefix"

printf 'NOT_JUMPBOX_OK\n' > "$T/suffix"
expect_fail "a longer token with the sentinel as a SUFFIX does NOT satisfy it" "$T/suffix"

# --- degenerate inputs -------------------------------------------------------------------------
: > "$T/empty"
expect_fail "an EMPTY log is rejected (a run that produced nothing did not finish)" "$T/empty"
expect_fail "a MISSING log is rejected, not treated as absence of evidence" "$T/does-not-exist"

# --- the OTHER sentinel: the two modes must not be interchangeable ------------------------------
printf 'JUMPBOX_SNEAKERNET_OK\n' > "$T/othermode"
expect_fail "the sneakernet sentinel does NOT satisfy a full-flow run" "$T/othermode"
if assert_run_sentinel "$T/othermode" JUMPBOX_SNEAKERNET_OK >/dev/null 2>&1; then
  ok "the sneakernet sentinel IS accepted when it is the one expected"
else
  bad "the sneakernet sentinel was rejected for its own mode"
fi

# Fail-check FIRST: `ran` counts only PASSING cases, so an all-fail run has ran==0 AND fail==1, and
# checking a "nothing ran" skip first would exit 0 over a run that printed nothing but FAIL.
if [ "$fail" -ne 0 ]; then echo "test-run-sentinel: FAILED" >&2; exit 1; fi
[ "$ran" -gt 0 ] || { echo "test-run-sentinel: no case ran — the harness is broken, not the code" >&2; exit 1; }
echo "test-run-sentinel: OK (${ran} case(s))"
