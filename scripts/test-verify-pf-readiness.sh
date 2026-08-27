#!/usr/bin/env bash
# test-verify-pf-readiness.sh — the READINESS wait must rebuild a dead tunnel, not blame the app.
#
# THE DEFECT THIS PINS (measured 2026-08-27, KinD e2e). B497 gave marker_visible() a tunnel-death
# classifier that rebuilds the port-forward. The `app HTTP up` READINESS wait, which runs BEFORE it,
# had none: a tunnel that died there was never detected, the wait burned its full 600s, and it died
#   FATAL [javawebapp] app not serving /healthz (tunnel to javawebapp-...-cxhjq, generation 1)
# `generation 1` proves no rebuild happened. At that moment the app served HTTP 200 through the
# ingress, both pods were 1/1 Running, and NO kubectl port-forward process existed.
#
# ⚠️ HONESTY — WHAT THIS GREEN DOES NOT PROVE. The cases below exercise a REIMPLEMENTATION of the
# classifier's contract, not scripts/99-verify.sh's actual _pf_classify: that function is nested
# inside verify_app() with locals and cannot be sourced standalone. A contract test of a stand-in is
# a test of the stand-in unless something ties it to the real code -- so the WIRING block at the end
# asserts, against the real file, that the readiness wait calls the predicate and that the predicate
# delegates to the ONE shared classifier. Contract + wiring together are the claim; neither alone is.
# What is still NOT covered: the live behaviour of a real dying port-forward. That is
# `make e2e-kind`, and it is where the defect was found in the first place.
set -uo pipefail
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok    $1"; else fail=$((fail+1)); echo "  FAIL  $1 (want '$3', got '$2')"; fi; }

# A faithful stand-in for the shared classifier's contract: same inputs, same state transitions.
mk() {  # mk <curl-rc> <kubectl-rc> <ready-string>
  RC="$1"; KRC="$2"; READY="$3"
  PF_DEATHS=0; PF_POLL_FAILS=0; PF_RESTARTS_BLOCKED=""; PF_UNKNOWN=""; PF_GEN=1; REBUILT=0
  _start_pf() { PF_GEN=$((PF_GEN+1)); REBUILT=$((REBUILT+1)); }
  # shellcheck disable=SC2329  # stand-ins for the real script's indirect callees
  _pf_ev() { :; }
  # shellcheck disable=SC2329
  _pick_pod() { echo "pod-x"; }
  # shellcheck disable=SC2329
  _curl_rc_label() { echo "rc=$1"; }
  VERIFY_PF_MAX_GENERATIONS=5; img=i; app=a; ns=n; pf_target=pod-x
  classify() {
    local rc="$1"
    if [ "$rc" -eq 22 ]; then PF_POLL_FAILS=$((PF_POLL_FAILS+1)); return 1; fi
    if [ "$KRC" -ne 0 ]; then
      PF_UNKNOWN="kubectl rc=$KRC"; PF_DEATHS=$((PF_DEATHS+1))
      [ "$PF_GEN" -lt "$VERIFY_PF_MAX_GENERATIONS" ] && _start_pf
      return 1
    fi
    if grep -q false <<< "$READY" || [ -z "$READY" ]; then
      PF_RESTARTS_BLOCKED="pods not Ready"; PF_POLL_FAILS=$((PF_POLL_FAILS+1)); return 1
    fi
    PF_DEATHS=$((PF_DEATHS+1))
    [ "$PF_GEN" -lt "$VERIFY_PF_MAX_GENERATIONS" ] && _start_pf
    return 1
  }
  classify "$RC"
}

echo "the readiness wait's tunnel classification"
mk 7 0 "true true "
ck "rc=7, pods Ready  -> counts a DEATH"        "$PF_DEATHS" 1
ck "rc=7, pods Ready  -> REBUILDS the tunnel"   "$REBUILT"   1
ck "rc=7, pods Ready  -> not blamed on the app" "$PF_RESTARTS_BLOCKED" ""

mk 56 0 "true true "
ck "rc=56 (accept-then-RST) is a death too"     "$PF_DEATHS" 1
mk 28 0 "true true "
ck "rc=28 (accept-then-hang) is a death too"    "$PF_DEATHS" 1

mk 22 0 "true true "
ck "rc=22 is a SUCCESSFUL round trip"           "$PF_DEATHS" 0
ck "rc=22 does NOT rebuild"                     "$REBUILT"   0

mk 7 0 "true false "
ck "pods NOT Ready -> the APP, no death"        "$PF_DEATHS" 0
ck "pods NOT Ready -> no rebuild"               "$REBUILT"   0

mk 7 1 ""
ck "kubectl unavailable -> death + rebuild"     "$PF_DEATHS" 1
ck "kubectl unavailable -> flagged UNKNOWN"     "${PF_UNKNOWN:+set}" set

mk 7 0 "true true "; PF_GEN=5; REBUILT=0; classify 7
ck "generation cap spent -> no further rebuild" "$REBUILT"   0

echo
echo "the WIRING, asserted against scripts/99-verify.sh itself"
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/99-verify.sh"
[ -f "$V" ] || { echo "  FAIL  99-verify.sh not found at $V"; exit 1; }
ck "readiness wait uses the predicate"        "$(grep -c 'wait_for "\[\${app}\] app HTTP up" _health_up' "$V")" 1
ck "_health_up delegates to the classifier"   "$(grep -c '_pf_classify "\$rc"' "$V")" 2
ck "exactly ONE classifier definition"        "$(grep -c '_pf_classify() {' "$V")" 1
ck "readiness failure can say HARNESS-TUNNEL" "$(grep -c 'HARNESS-TUNNEL \[\${app}\] \${health} was NEVER reached' "$V")" 1
ck "the old un-rebuilding wait is GONE"       "$(grep -c 'wait_for "\[\${app}\] app HTTP up" curl' "$V")" 0

echo
if [ "$fail" -eq 0 ]; then echo "test-verify-pf-readiness: ${pass} passed, 0 failed"; exit 0; fi
echo "test-verify-pf-readiness: ${pass} passed, ${fail} FAILED"; exit 1
