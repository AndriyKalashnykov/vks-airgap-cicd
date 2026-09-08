#!/usr/bin/env bash
# ci-tier: fast
#
# Pins that OUR OWN timeout expiring is never reported as a fact about the lab (B544).
#
# THE DEFECT. Nine `creds.sh` probes set the OUTER `timeout` budget EQUAL to kubectl's
# `--request-timeout`, so the process is killed before kubectl can print the summary line the
# UNREACHABLE arm matches. Measured, unreachable server, `--request-timeout=3s`, varying ONLY the
# outer budget: 5s -> 1 line, no summary, UNKNOWN | 10s -> 3 lines, no summary, UNKNOWN |
# 25s -> 6 lines, summary present, UNREACHABLE. So the classifier was answering a question it had
# no evidence for, and the reachability banner asserted "not reachable" on the strength of us not
# waiting.
#
# ⚠️ THE FIX IS THE EXIT CODE, NOT A BIGGER BUDGET. A round measured that no budget is derivable:
# against an unreachable endpoint kubectl wrote 6 stderr lines by 25s; against a blackhole
# (10.255.255.1:443) it wrote ZERO BYTES at 60s. `--request-timeout` bounds nothing on that fault
# shape, and two points disagreeing by >2x is not a model. `timeout` exits 124 (137 with -s KILL)
# deterministically, needs no retry knowledge, and does not vary with the fault.
#
# 🔴 AND IT IS THE SSO GUARANTEE. rc=124 must NEVER reach the UNAUTHORIZED arm, whose remedy names a
# vSphere SSO bind — and vCenter locks out PERMANENTLY after THREE failures. Keying on the exit code
# guarantees that whatever the fault happens to write to stderr; no string-matching model can.
#
# The timeout here is REAL: the kubectl stub sleeps past the budget. Nothing simulates an rc.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source lib/os.sh"; exit 1; }

_pass=0; _fail=0
ok()  { _pass=$((_pass+1)); printf '  ok    %s\n' "$1"; }
bad() { _fail=$((_fail+1)); printf '  FAIL  %s\n' "$1"; }
_R="$PWD"

# <sleep-seconds> -> the rendered report, with a kubectl that outlives the budget
_render() {
  local nap="$1" t; t="$(mktemp -d)"; mkdir -p "$t/bin"
  cp .env.example "$t/.env.example"
  printf "HARBOR_URL=10.0.0.1\nHARBOR_USERNAME='robot\$p'\nHARBOR_PASSWORD=x\n" > "$t/.env"
  printf 'apiVersion: v1\nkind: Config\n' > "$t/kc"
  # A SUPERVISOR kubeconfig, so the Harbor admin-password cell actually reaches `_kube_classify`.
  # Without it that block short-circuits on the tenant arm and the SSO-critical 124 path is never
  # executed -- measured: disabling that arm entirely left this suite GREEN.
  printf 'apiVersion: v1\nkind: Config\n' > "$t/sup"
  { printf '#!/bin/sh\ncase "$*" in\n'
    printf '  *current-context*) echo ctx; exit 0 ;;\n'
    printf '  *) sleep %s; exit 0 ;;\n' "$nap"
    printf 'esac\n'; } > "$t/bin/kubectl"
  printf '#!/bin/sh\nexit 1\n' > "$t/bin/curl"; cp "$t/bin/curl" "$t/bin/getent"
  chmod +x "$t/bin/kubectl" "$t/bin/curl" "$t/bin/getent"
  ( cd "$t" && PATH="$t/bin:$PATH" REPO_ROOT="$t" VKS_STATE_FILE="$t/.env.state" \
      KUBECONFIG="$t/kc" VKS_SUPERVISOR_KUBECONFIG="$t/sup" \
      CREDS_KUBE_TIMEOUT_SECONDS=1 CREDS_K8S_TIMEOUT=1 CREDS_TOKEN=1 \
      "${_R}/scripts/creds.sh" 2>&1 )
  rm -rf "$t"
}

_out="$(_render 4)"     # kubectl outlives the 1s budget -> a REAL rc=124

# 1. The banner must not claim the cluster is unreachable when we simply did not wait.
#    ⚠️ MATCH THE CLUSTER LINE'S OWN WORDING, not a bare `UNDETERMINED`: the FLOW line says
#    "undetermined — a state overlay exists but was REFUSED" (B517), so a loose case-insensitive
#    match reports success from a line about something else entirely. Measured: the positive
#    control below FAILED for exactly that reason before this was tightened.
if grep -q 'budget expired before it answered' <<< "$_out"; then
  ok "an expired budget is reported as UNDETERMINED, not as a fact about the cluster"
elif grep -qi 'not reachable' <<< "$_out"; then
  bad "the banner says 'not reachable' after OUR OWN timeout expired. The server said nothing at
      all -- that is a claim about the world made on the strength of us not waiting."
else
  bad "neither UNDETERMINED nor 'not reachable' appeared -- this case reached neither arm and is
      VACUOUS. Suspect the kubectl stub or CREDS_KUBE_TIMEOUT_SECONDS, not the code."
fi

# 2. THE SSO GUARANTEE. Under a pure budget expiry nothing may prescribe the vCenter bind.
if grep -q 'make vks-login' <<< "$_out"; then
  bad "an expired budget produced a report naming make vks-login. That remedy performs a vSphere
      SSO bind and vCenter locks out PERMANENTLY after THREE failures -- it must never be
      prescribed for a state we could not even ask about."
else
  ok "an expired budget names no SSO command"
fi

# 3. THE POSITIVE CONTROL. Without it, cases 1-2 pass identically on a report that never ran a
#    probe at all -- and two of the three assertions above are 'absence' assertions.
_fast="$(_render 0)"
if grep -q 'budget expired before it answered' <<< "$_fast"; then
  bad "a kubectl that answers INSTANTLY still reported UNDETERMINED -- the 124 arm is being taken
      unconditionally, so cases 1-2 prove nothing about a timeout."
elif grep -qE "reachable — context|reachable - context" <<< "$_fast"; then
  ok "control: a kubectl that answers in time is reported reachable (the arms discriminate)"
else
  bad "control: an instant kubectl produced neither verdict -- the fixture never reaches the probe,
      so the discrimination in cases 1-2 is unproven."
fi

# 4. The discriminator must be the EXIT CODE, not a string. A budget message that keys on stderr
#    text would be defeated by the blackhole shape, which writes ZERO BYTES.
if grep -qE '^[[:space:]]*124\|137\)' <<< "$(sed '/^[[:space:]]*#/d' scripts/creds.sh)"; then
  ok "the discriminator is a numeric exit-code arm (124|137), not a string match"
else
  bad "no 124|137 exit-code arm found in creds.sh. If this became a stderr string match it is
      defeated by the fault shape that writes NOTHING (measured: 0 bytes at 60s on a blackhole)."
fi

# 5. THE SSO-CRITICAL ARM, BEHAVIOURALLY. `_kube_classify` is the one mapping from a kube failure
#    class to a sentence, and its UNAUTHORIZED arm names the vCenter bind. Case 4 above proves the
#    exit-code arm EXISTS; this proves it is REACHED. Measured: with only case 4, disabling that arm
#    left this suite green, because the fixture never drove a classifier path at all.
#    ⚠️ KEY ON THE TOKEN, not on prose. `_kube_classify` emits exactly one `<...>` token per arm, so
#    the token says WHICH arm ran and the message can name the right cause. A first version matched
#    a prose subset and, when the 124 arm was disabled, reported "never reached _kube_classify" —
#    while it HAD been reached and had fallen through to UNKNOWN. A wrong-cause message on a test
#    for wrong-cause messages.
_tok="$(grep -oE '<(could not ask|auth failed|forbidden|unreachable|stale CA|bad kubeconfig|kubectl failed|no target|plaintext)>' <<< "$_out" | head -1)"
case "$_tok" in
  '<could not ask>')
    ok "_kube_classify reports an expired budget as ours, not as a class the server told us" ;;
  '<auth failed>')
    bad "an expired budget was mapped to AUTH FAILED. The server said nothing at all, and that arm's
      remedy is a vSphere SSO bind — vCenter counts it toward a PERMANENT 3-strike lockout. This is
      the exact outcome the exit-code discriminator exists to make impossible." ;;
  '')
    bad "no _kube_classify token appeared at all -- this case never reached it, so the SSO-critical
      path is UNMEASURED. Check VKS_SUPERVISOR_KUBECONFIG and that HARBOR_USERNAME is a robot." ;;
  *)
    bad "an expired budget was mapped to ${_tok} -- a SERVER-SIDE class, on a request the server
      never answered. Only <could not ask> is truthful here." ;;
esac

printf '\n  %s passed, %s failed\n' "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || { echo "kube-budget-discriminator FAILED"; exit 1; }
echo "SUCCESS — our own expired budget is never reported as a fact about the lab, and never as auth"
