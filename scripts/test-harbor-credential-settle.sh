#!/usr/bin/env bash
# test-harbor-credential-settle.sh — RED-proof for harbor_credential_settle (lib/harbor.sh).
#
# WHAT THIS GUARDS. Harbor is the only component this repo installs that never RECONCILES its admin
# password: goharbor src/core/main.go:99 applies HARBOR_ADMIN_PASSWORD only when the admin row has
# no salt, i.e. at ITS OWN first bootstrap. On every later run helm accepts the value, the Secret
# updates, the pods go Ready, /api/v2.0/health (UNAUTHENTICATED) returns 200 -- and Harbor ignores
# it. MEASURED: 06-install-harbor.sh had ZERO harbor_auth* calls, so the 401 surfaced ~20 minutes
# downstream in 21-mirror-push.sh, reading as a mirror bug.
#
# HONESTY. This exercises the REAL harbor_credential_settle, stubbing only the two probe primitives
# (_harbor_auth_code, _harbor_ca_args) so no network is touched. It does NOT prove the KinD DB
# reconcile works -- that mechanism is UNVERIFIED on the pinned chart and --may-reconcile is
# deliberately a no-op until it is measured on a throwaway Harbor.
set -uo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok    $1";
       else fail=$((fail+1)); echo "  FAIL  $1 (want '$3', got '$2')"; fi; }

# Run settle in a SUBSHELL: it calls die() on a real rejection, which exits.
# <code> <mode> <user> [url] -> prints "rc=<rc>|<first matching signal>"
run_settle() {
  local code="$1" mode="$2" user="$3" url="${4-172.18.0.3}"
  local out rc
  out=$(
    set +e
    . scripts/lib/os.sh    >/dev/null 2>&1
    . scripts/lib/harbor.sh >/dev/null 2>&1
    _harbor_ca_args()  { printf -- '--cacert\n/tmp/nonexistent-ca.crt'; return 0; }
    _harbor_auth_code() { printf '%s' "$code"; }
    HARBOR_URL="$url" HARBOR_USERNAME="$user" HARBOR_PASSWORD='S0me-Real-Pw!' \
      harbor_credential_settle "$mode" 2>&1
  ); rc=$?
  local sig=none
  case "$out" in
    *"is a ROBOT account"*)              sig=robot ;;
    *"REJECTED"*)                        sig=rejected ;;
    *"could not verify"*)                sig=unchecked ;;
    *"the one in effect"*)               sig=accepted ;;
  esac
  printf 'rc=%s|%s' "$rc" "$sig"
}

echo "harbor_credential_settle:"
# --- the credential is good ---------------------------------------------------
ck "200 -> accepted, rc=0"                  "$(run_settle 200 --verify-only admin)"      "rc=0|accepted"
ck "403 -> accepted (authenticated, just not authorized)" \
                                            "$(run_settle 403 --verify-only admin)"      "rc=0|accepted"

# --- the credential is REJECTED: this is the whole point ----------------------
ck "401 -> DIES (verify-only)"              "$(run_settle 401 --verify-only admin)"      "rc=1|rejected"
ck "401 -> DIES (may-reconcile too)"        "$(run_settle 401 --may-reconcile admin)"    "rc=1|rejected"

# --- the probe could not run: NEVER a password verdict ------------------------
# MEASURED 2026-08-12 (scenario-1 walk, row 4): a probe that never ran was reported as an auth
# failure about a password that had not been sent anywhere. An error naming the wrong cause is
# worse than a crash -- it sends the operator to fix a thing that is not broken.
ck "000 -> unchecked, passes, NOT a verdict" "$(run_settle 000 --verify-only admin)"     "rc=0|unchecked"
ck "no HARBOR_URL -> unchecked, passes"      "$(run_settle 200 --verify-only admin '')"  "rc=0|unchecked"

# --- a robot on an INSTALL path is wrong before any probe runs -----------------
# Today this surfaces as a bare 401 that reads as a password problem.
ck "robot\$ user -> DIES naming the robot"   "$(run_settle 200 --verify-only 'robot$ci')" "rc=1|robot"
ck "robot\$ beats even a 401"                "$(run_settle 401 --verify-only 'robot$ci')" "rc=1|robot"

# --- WIRING: asserted against the shipped scripts, not a copy ------------------
ck "06 calls settle AFTER publishing HARBOR_URL" \
   "$(awk '/state_set HARBOR_URL/{p=NR} /harbor_credential_settle/{s=NR} END{print (p&&s&&s>p)?"yes":"no"}' scripts/06-install-harbor.sh)" "yes"
ck "06 exports HARBOR_URL for the probe (state_set does NOT export)" \
   "$(grep -c '^export HARBOR_URL=' scripts/06-install-harbor.sh)" "1"
ck "05 guards the mint on an existing harbor namespace" \
   "$(grep -c 'kubectl get namespace "${HARBOR_NAMESPACE:-harbor}"' scripts/05-kind-up.sh)" "1"
ck "05 reads the query's rc, not its empty output" \
   "$(grep -c '_hns_rc=\$?' scripts/05-kind-up.sh)" "1"

echo "  ---- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
