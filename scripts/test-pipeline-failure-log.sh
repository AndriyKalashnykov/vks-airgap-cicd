#!/usr/bin/env bash
# ci-tier: fast
#
# Pins `pipeline_failure_log` and `pipeline_rerender_hint` (lib/os.sh), and that the three pipeline
# failure arms actually CALL them.
#
# THE DEFECT (B532): nothing in this repo printed the failing step's stdout. Both failure arms showed
# object STATUS — `describe`, `get -o wide`, `get taskruns` — while the cause sat in the container
# log: a stale image ref reaches kaniko as a `--build-arg`, so the failure reads `NOT_FOUND …`
# NAMING THE IMAGE. An operator who has just corrected `.env` sees the OLD tag, because the cluster's
# TriggerTemplate carries the value it was RENDERED with, and concludes the fix did not work.
#
# `kubectl` here is a STUB. Everything below is offline.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source lib/os.sh"; exit 1; }

_pass=0; _fail=0
ok()  { _pass=$((_pass+1)); printf '  ok    %s\n' "$1"; }
bad() { _fail=$((_fail+1)); printf '  FAIL  %s\n' "$1"; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; mkdir -p "$T/bin"

# <pod-list-lines> -> a kubectl that answers the pod query with them and logs a marker per pod
_stub() {
  { printf '#!/bin/sh\ncase "$*" in\n'
    printf '  *"get pods"*) printf %%s%%s "%s" "" ;;\n' "$1"
    # shellcheck disable=SC2016  # $3 is the GENERATED stub's positional -- it must not expand here
    printf '  *logs*) echo "STEP-STDOUT-MARKER for $3" ;;\n'
    printf '  *) : ;;\nesac\nexit 0\n'; } > "$T/bin/kubectl"
  chmod +x "$T/bin/kubectl"
}

# 1. THE WHOLE POINT: with pods present, the step's stdout is printed.
_stub 'pod-a
pod-b'
_out="$( PATH="$T/bin:$PATH" pipeline_failure_log ci my-run 2>&1 )"
if grep -q 'STEP-STDOUT-MARKER' <<< "$_out"; then
  ok "the failing step's stdout IS printed"
else
  bad "no step log was printed — the arms are back to showing object status only, which is the
      defect: the cause (a stale image ref in a --build-arg) lives ONLY in the container log."
fi

# 2. THE SINGLE-POD CASE, and the structural fact that keeps it working. A command substitution
#    strips the trailing newline, so a bare `read` loop drops the LAST item -- with one pod, every
#    pod. The HEREDOC re-adds it; a `printf | while read` refactor would not, and would fail
#    SILENTLY (no output, rc=0). Asserting the behaviour alone was VACUOUS -- measured: removing the
#    old `|| [ -n "$p" ]` guard changed nothing, because the heredoc already covered it.
_stub 'only-pod'
_out="$( PATH="$T/bin:$PATH" pipeline_failure_log ci my-run 2>&1 )"
# shellcheck disable=SC2016  # the literal $pods is the POINT: these grep SOURCE text, not a value
if ! grep -q 'only-pod' <<< "$_out"; then
  bad "the only pod was dropped -- the single-pod case printed NOTHING while returning 0."
elif grep -qE 'pods"[[:space:]]*\|[[:space:]]*while|printf.*\$pods.*\|' \
       <<< "$(sed -n '/^pipeline_failure_log() {/,/^}/p' scripts/lib/os.sh | sed '/^[[:space:]]*#/d')"; then
  bad "the pod list is now PIPED into the read loop. A pipe does not supply the trailing newline the
      heredoc does, so the LAST pod is dropped -- and with one pod that prints nothing at all."
else
  ok "a SINGLE pod is printed, and the loop is still fed by a heredoc (not a pipe)"
fi

# 3. No pods is a legitimate state (garbage-collected, or failed before any pod existed).
_stub ''
_out="$( PATH="$T/bin:$PATH" pipeline_failure_log ci my-run 2>&1 )"; _rc=$?
if [ "$_rc" -eq 0 ] && grep -qi 'not an error' <<< "$_out"; then
  ok "no pods -> says so, and does not fail the caller"
else
  bad "no-pods was reported as an error (rc=$_rc). This helper must NEVER gate: it runs on a path
      that is ALREADY failing, and a second failure there hides the first."
fi

# 4/5. THE REMEDY IS GUARDED. `ensure_secret_token` MINTS a new token when the file is absent, so a
#      blind 'make configure-tekton' on a fresh clone rotates the HMAC and desyncs the Gitea webhook
#      -- turning a legible NOT_FOUND into an illegible "no PipelineRun appeared".
mkdir -p "$T/secrets"; printf 'tok\n' > "$T/secrets/webhook-token"
_out="$( REPO_ROOT="$T" pipeline_rerender_hint 2>&1 )"
if grep -q 'make configure-tekton' <<< "$_out"; then
  ok "with secrets/webhook-token present, the remedy names the re-render command"
else
  bad "the remedy no longer names 'make configure-tekton' even when re-running it is SAFE -- the
      operator is told the cause and not the fix."
fi
rm -f "$T/secrets/webhook-token"
_out="$( REPO_ROOT="$T" pipeline_rerender_hint 2>&1 )"
if grep -q 'MISSING' <<< "$_out" && ! grep -qE '^\s*Re-render it:' <<< "$_out"; then
  ok "with the token file ABSENT, it warns instead of prescribing a token-rotating re-run"
else
  bad "it prescribed a bare re-render with secrets/webhook-token missing. That MINTS a new HMAC
      token and desyncs the Gitea webhook -- a remedy that is a NEW fault in the state that
      produced the failure."
fi

# 6. The arms must actually CALL it. Grep the CALL FORM, not the bare name: the name appears in
#    every comment above, and a symbol-name grep would pass on documentation alone.
#    ⚠️ AND THE EXACT COUNT, not `>= 1`. 75-build-apps.sh has TWO failure arms (the reason-matched
#    one and the timeout one); with `>= 1`, deleting either still passed -- measured.
for _spec in 'scripts/75-build-apps.sh:2' 'scripts/99-verify.sh:1'; do
  _f="${_spec%:*}"; _want="${_spec##*:}"
  # shellcheck disable=SC2016  # the literal $CI_NAMESPACE is the POINT: this greps SOURCE text
  _n="$(grep -cE '^[[:space:]]*pipeline_failure_log[[:space:]]+"\$CI_NAMESPACE"' \
          <<< "$(sed '/^[[:space:]]*#/d' "$_f")" || true)"
  if [ "${_n:-0}" -eq "$_want" ]; then
    ok "$(basename "$_f") calls pipeline_failure_log on all ${_n} of its failure arm(s)"
  else
    bad "$(basename "$_f") calls pipeline_failure_log on ${_n} arm(s), expected ${_want} -- a
      failure path is back to printing object status with no log, which is exactly B532."
  fi
done

printf '\n  %s passed, %s failed\n' "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || { echo "pipeline-failure-log FAILED"; exit 1; }
echo "SUCCESS — a failing pipeline prints the step's own stdout, and its remedy cannot rotate a token"
