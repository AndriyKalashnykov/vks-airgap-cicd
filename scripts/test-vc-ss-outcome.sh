#!/usr/bin/env bash
# ci-tier: fast — offline; vc_api is stubbed, no vCenter.
#
# test-vc-ss-outcome.sh — vc_ss_install returns 0 from THREE different arms, and only one of them
# means "OUR request created this service". 04-install-harbor-service.sh publishes the admin
# password it SENT only on that arm (B725): for a Harbor that already existed, the password this run
# sent authenticates against nothing, and publishing it is a fabricated credential.
#
# Each case drives the REAL vc_ss_install with a stubbed vc_api and asserts VC_SS_OUTCOME.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# run_case <script of responses, one "CODE|BODY" per POST> [present-after-500 0|1]
run_case() {
  local T; T="$(mktemp -d)"
  printf '%s\n' "$1" > "$T/responses"
  # shellcheck disable=SC2016  # the body is single-quoted ON PURPOSE: $1/$2 and the stub functions
  # must expand in the CHILD bash, not here.
  env -u REPO_ROOT bash -c '
    T="$1"; PRESENT="$2"
    . scripts/lib/os.sh >/dev/null 2>&1
    . scripts/lib/vcenter.sh >/dev/null 2>&1
    echo 0 > "$T/n"
    vc_api() {                     # pop the next canned response; rc 0 only for 2xx
      # The counter lives in a FILE: vc_ss_install calls this inside $( ), so a shell variable
      # would reset every call and replay response 1 forever (measured: both retry cases went empty).
      local n line; n=$(( $(cat "$T/n") + 1 )); echo "$n" > "$T/n"
      line="$(sed -n "${n}p" "$T/responses")"
      printf "%s" "${line%%|*}" > "$T/code"; printf "%s" "${line#*|}"
      case "${line%%|*}" in 2??) return 0 ;; *) return 1 ;; esac
    }
    vc_last_code() { cat "$T/code"; }
    vc_ss_state()  { [ "$PRESENT" = 1 ] && echo CONFIGURED; return 0; }
    sleep() { :; }
    VC_SS_INSTALL_INTERVAL=0
    vc_ss_install moid svc 1.0 >/dev/null 2>&1
    printf "%s" "${VC_SS_OUTCOME:-<unset>}"
  ' _ "$T" "${2:-0}"
  rm -rf "$T"
}

check() { # check <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1: got '$2', want '$3'"; fi
}

check "POST 200 on the first attempt (we created it)" \
      "$(run_case '200|{}')" installed
check "'already exists' on the FIRST attempt (it pre-dated us)" \
      "$(run_case '400|service already exists')" existed
check "'already exists' after a transient retry (an earlier attempt of OURS may have landed)" \
      "$(run_case '404|The service account is not ready. Please try again later.
400|service already exists')" ambiguous
check "HTTP 500 but the service IS present (measured: a 500 can still create it)" \
      "$(run_case '500|internal error' 1)" ambiguous
check "CONTROL: a retry that then succeeds is still OURS" \
      "$(run_case '404|not ready, try again later
200|{}')" installed

# 04 must key the publish on the outcome, not on the return code. Structural, because running 04
# needs a vCenter; if this line moves, the gate above no longer protects the password.
if grep -qE 'if \[ "\$\{VC_SS_OUTCOME:-\}" = installed \]; then' scripts/04-install-harbor-service.sh \
   && grep -q 'state_set HARBOR_PASSWORD' <<< "$(grep -A2 'VC_SS_OUTCOME:-}" = installed' scripts/04-install-harbor-service.sh)"; then
  ok "04 publishes HARBOR_PASSWORD only when VC_SS_OUTCOME=installed"
else
  bad "04 no longer gates the HARBOR_PASSWORD publish on VC_SS_OUTCOME=installed (B725)"
fi

if [ "$fail" -eq 0 ]; then echo "vc-ss-outcome: ALL PASS"; else echo "vc-ss-outcome: FAILED"; exit 1; fi
