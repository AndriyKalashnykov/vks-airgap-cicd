#!/usr/bin/env bash
# shellcheck disable=SC2016  # every grep pattern here is a LITERAL to match inside 99-verify.sh,
#   not an expansion. Double-quoting would expand ${app}/${health}/$rc and match nothing.
# shellcheck disable=SC2034  # img/app/ns/pf_target are consumed by the classifier stand-in under
#   the SAME names the real function uses; renaming them would weaken the fidelity this test needs.
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

# --- the REMOTE port must follow the TARGET ---------------------------------------
# 80 is the SERVICE port (targetPort `http` = 8080 in the container). Binding a NAMED POD on :80
# can never connect. MEASURED on a healthy Ready pod: pod:80 -> http 000, pod:8080 -> http 200,
# svc:80 -> http 200. It shipped as `"${app_local_port}:80"` for BOTH targets, so every run that
# successfully found a Ready pod was unreachable -- 114 refused connections across the generation
# cap, ~10 minutes after the pods were Ready in 6s. The svc/ fallback still worked, so the failure
# only appeared when the pod lookup SUCCEEDED.
pf_line=$(grep -c 'port-forward "$pf_target" "${app_local_port}:${pf_port}"' "$V")
ck "the port-forward binds \${pf_port}, not a literal :80" "$pf_line" "1"
ck "no literal :80 remains on the port-forward line" \
   "$(grep -c 'port-forward "$pf_target" "${app_local_port}:80"' "$V")" "0"
# ⚠️ THIS USED TO ASSERT THE JSONPATH APPEARS EXACTLY ONCE, and that made it a gate that was GREEN
# over a live defect and RED on its remedy -- the shape most likely to get a correct fix reverted to
# restore a green gate. The defect: pf_port was resolved ONCE, at the initial bind, while both
# tunnel-rebuild sites reassigned pf_target and inherited the stale port. Every Service exposes only
# 80 and every containerPort is 8080, so pod->svc/ bound svc/ on 8080 (no such service port) and
# svc/->pod bound a pod on 80 (nothing listening); either killed the tunnel for the rest of the run.
# Resolving the port in a helper called at all three sites is the fix, and it necessarily makes the
# jsonpath appear once while the CALL appears three times. Assert the invariant that matters: the
# port is re-derived wherever the target is chosen.
ck "pf_port is resolved from the pod's containerPort" \
   "$([ "$(grep -c 'jsonpath=.{.spec.containers\[0\].ports\[0\].containerPort}' "$V")" -ge 1 ] && echo ok)" "ok"
# EVERY site that assigns pf_target must be followed by a re-derivation. Counting the CALL, not the
# literal, is what makes this survive the helper refactor -- and what would catch a THIRD rebuild
# site being added later without one.
ck "pf_port is re-derived at every site that moves pf_target" \
   "$(grep -c '_resolve_pf_port' "$V")" "4"
# ⚠️ EXECUTABLE lines only: the phrase appears in the explanatory comment too, and counting both
# made this assert 2. Same trap as "a check that greps a symbol also matches its own docstring".
ck "a pod with no containerPort falls back to svc/" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c 'declares no containerPort')" "1"

# ⚠️ THE LINE ABOVE COUNTS A LOG MESSAGE, NOT A BEHAVIOUR, and was therefore VACUOUS with respect to
# what the fallback actually assigns: it passed both when the helper blanked pf_target and when it
# set svc/. That distinction is the whole bug -- MEASURED, `kubectl port-forward "" 18099:80` ->
# "error: resource name may not be empty", and the two REBUILD sites call _start_pf immediately with
# no empty-check, so a blanking fallback is a permanently dead tunnel there. Assert the assignment.
ck "the no-containerPort fallback assigns svc/, never an empty target" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -A1 'declares no containerPort' | grep -c 'pf_target="svc/\${app}"')" "1"
ck "no code path assigns an empty pf_target" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c 'pf_target=""')" "0"

if [ "$fail" -eq 0 ]; then echo "test-verify-pf-readiness: ${pass} passed, 0 failed"; exit 0; fi
echo "test-verify-pf-readiness: ${pass} passed, ${fail} FAILED"; exit 1
