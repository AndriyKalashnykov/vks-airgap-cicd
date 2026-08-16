#!/usr/bin/env bash
# scripts/test-endpoint-report.sh — offline proof for 26-vks-cluster-status.sh's endpoint_report.
#
# WHY THIS EXISTS. endpoint_report diagnoses a control-plane endpoint that advertises a DIFFERENT
# address than its load balancer holds — a state MEASURED four times on a real VCF 9.1 lab and one
# that neither KinD nor any CI runner can reproduce on demand. The fixtures below are the shape of
# that evidence, so the DIVERGENT branch has a demonstrated RED that does not need a lab.
#
# It drives the REAL function (extracted from the script at run time), never a copy — a copy would
# drift from the thing that ships and would prove nothing about it.
#
# The whole point of the function is that it PRINTS and never gates, so every case asserts rc=0 AND
# asserts on the text. A case that only checked rc would pass no matter what it said.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/26-vks-cluster-status.sh"
[ -f "$TARGET" ] || { echo "FAIL: $TARGET missing"; exit 1; }

# Pull the function out of the shipping script. If the extraction ever yields nothing the tests must
# FAIL LOUDLY rather than silently prove nothing about an empty function.
FN="$(sed -n '/^endpoint_report()/,/^}/p' "$TARGET")"
case "$FN" in
  *"endpoint_report()"*) : ;;
  *) echo "FAIL: could not extract endpoint_report from $TARGET (did it get renamed?)"; exit 1 ;;
esac

# ---------------------------------------------------------------------------------------------
# FIXTURE VALUES — every name, namespace, IP and port used below is defined ONCE here and is
# overridable from the environment. They are deliberately SYNTHETIC: RFC 5737 documentation
# addresses (192.0.2.0/24, reserved for exactly this) and generic names, so nothing in this file
# names a real cluster, a real namespace or a real lab subnet. A test that embedded the operator's
# actual cluster name would silently couple a unit test to one person's .env.
FX_CLUSTER="${FX_CLUSTER:-testcluster}"          # the cluster under test
FX_CLUSTER_B="${FX_CLUSTER_B:-testcluster-b}"    # a second candidate, for the ambiguity case
FX_FOREIGN="${FX_FOREIGN:-othercluster-a1b2c3}"  # another tenant's projected workload LB
FX_NS="${FX_NS:-testns}"                         # the vSphere Namespace
FX_ADV="${FX_ADV:-192.0.2.137}"                  # the STALE advertised endpoint
FX_LB="${FX_LB:-192.0.2.138}"                    # what the control-plane LB actually holds
FX_LB_B="${FX_LB_B:-192.0.2.139}"                # the second candidate's LB
FX_FOREIGN_IP="${FX_FOREIGN_IP:-192.0.2.133}"    # the foreign tenant's VIP — must never be named as ours
FX_CP_PORT="${FX_CP_PORT:-6443}"                 # the control-plane port the fixture Service exposes
FX_FOREIGN_PORT="${FX_FOREIGN_PORT:-80}"         # the foreign workload port (NOT a control plane)
FX_HOSTNAME_EP="${FX_HOSTNAME_EP:-cp.example.local}"  # a name-shaped endpoint (RFC 2606 .example)
FX_LB_HOSTNAME="${FX_LB_HOSTNAME:-lb.example.net}"    # an LB that reports a hostname, not an IP

pass=0; fail=0
check() { # check <name> <expect-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        wanted substring: $2"; echo "        got: $3"; fail=$((fail + 1))
  fi
}

# A control-plane LB, per the discriminator MEASURED on this lab: type LoadBalancer + port 6443 +
# ownerRef kind VirtualMachineService named after the cluster.
cp_svc() { # cp_svc <name> <owner-name> <ingress-json>
  printf '{"metadata":{"name":"%s","ownerReferences":[{"kind":"VirtualMachineService","name":"%s"}]},"spec":{"type":"LoadBalancer","ports":[{"port":%s}]},"status":{"loadBalancer":{"ingress":[%s]}}}' \
    "$1" "$2" "$FX_CP_PORT" "$3"
}

run_case() { # run_case <cluster> <advertised> <services-json-array>
  # T_ prefixes are LOAD-BEARING, not style. endpoint_report declares `local adv`, and bash is
  # DYNAMICALLY scoped — so a stub referencing a plain `$adv` resolves to the function-under-test's
  # own empty local and dies `unbound variable` under `set -u`. That happened, and it turned every
  # case into a CANNOT-READ while five negative assertions ("must not print DIVERGENT") passed
  # vacuously, because nothing was printed at all.
  local T_CL="$1" T_ADV="$2" T_SVCS="$3"
  (
    set +e
    VKS_CLUSTER_NAME="$T_CL" VKS_NAMESPACE="${FX_NS}"
    export VKS_CLUSTER_NAME VKS_NAMESPACE
    # Stub `k`. It must model the REAL argv shapes the function sends, or the test proves nothing
    # about the real call sites — the documented test-double trap.
    # shellcheck disable=SC2329  # invoked INDIRECTLY, by the eval'd endpoint_report below
    k() {
      case "$*" in
        # The host and the port are TWO separate reads of the same object. The stub must tell them
        # apart, or the port branch returns an IP, int() throws, the code falls back to "accept any
        # port", and the port fixture proves nothing about the port at all.
        *controlPlaneEndpoint.port*) printf '%s' "$FX_CP_PORT" ;;
        *controlPlaneEndpoint.host*) [ -n "$T_ADV" ] && printf '%s' "$T_ADV" || printf '' ;;
        *"get svc -o json"*)         printf '{"items":[%s]}' "$T_SVCS" ;;
        *) return 1 ;;
      esac
    }
    eval "$FN"
    endpoint_report
    echo "RC=$?"
  ) 2>&1
}

# Ingress builders — keep JSON assembly out of the call sites so no fixture value is ever trapped
# in single quotes (it was, and every case silently received the literal text "${FX_LB}").
ing_ip()   { printf '{"ip":"%s"}' "$1"; }
ing_host() { printf '{"hostname":"%s"}' "$1"; }
ing_none() { printf '{}'; }

echo "endpoint_report — offline cases"

# --- the case this whole diagnostic exists for -------------------------------------------------
out="$(run_case "$FX_CLUSTER" "$FX_ADV" "$(cp_svc "$FX_CLUSTER" "$FX_CLUSTER" "$(ing_ip "$FX_LB")")")"
check "DIVERGENT is reported"                 "*** DIVERGENT ***" "$out"
check "DIVERGENT names BOTH addresses"        "advertises ${FX_ADV} but svc/${FX_CLUSTER} holds ${FX_LB}" "$out"
check "DIVERGENT does NOT say recreate same"  "DIFFERENT name" "$out"
check "DIVERGENT tells them to capture first" "CAPTURE THE EVIDENCE FIRST" "$out"
check "DIVERGENT still exits 0 (never gates)" "RC=0" "$out"

# --- the healthy shape (also confirmed against the live lab) ------------------------------------
out="$(run_case "$FX_CLUSTER" "$FX_LB" "$(cp_svc "$FX_CLUSTER" "$FX_CLUSTER" "$(ing_ip "$FX_LB")")")"
check "AGREE is reported"                     "AGREE (${FX_LB}" "$out"
check "AGREE still exits 0"                   "RC=0" "$out"
case "$out" in *DIVERGENT*) echo "  FAIL  AGREE must not print DIVERGENT"; fail=$((fail + 1)) ;;
               *) echo "  PASS  AGREE must not print DIVERGENT"; pass=$((pass + 1)) ;; esac

# --- vacuity: both values absent must NOT read as agreement -------------------------------------
out="$(run_case "$FX_CLUSTER" "" "")"
check "no endpoint + no LB => NOT YET, not a pass" "NOT YET KNOWABLE" "$out"

# --- an LB that has not been assigned yet -------------------------------------------------------
out="$(run_case "$FX_CLUSTER" "$FX_ADV" "$(cp_svc "$FX_CLUSTER" "$FX_CLUSTER" "$(ing_none)")")"
check "LB not assigned yet => NOT YET"        "NOT YET KNOWABLE" "$out"

# --- FALSE-ALARM GUARD: a hostname endpoint is legitimate elsewhere ------------------------------
out="$(run_case "$FX_CLUSTER" "$FX_HOSTNAME_EP" "$(cp_svc "$FX_CLUSTER" "$FX_CLUSTER" "$(ing_ip "$FX_LB")")")"
check "name-vs-IP is NOT comparable"          "not comparable" "$out"
case "$out" in *DIVERGENT*) echo "  FAIL  a hostname endpoint must not be reported DIVERGENT"; fail=$((fail + 1)) ;;
               *) echo "  PASS  a hostname endpoint must not be reported DIVERGENT"; pass=$((pass + 1)) ;; esac

# --- FALSE-ALARM GUARD: an LB reporting a HOSTNAME must not read as "no LB" ----------------------
out="$(run_case "$FX_CLUSTER" "$FX_ADV" "$(cp_svc "$FX_CLUSTER" "$FX_CLUSTER" "$(ing_host "$FX_LB_HOSTNAME")")")"
check "LB hostname is read, not ignored"      "$FX_LB_HOSTNAME" "$out"

# --- SHARED-NAMESPACE GUARD: another tenant LB must never be adopted ----------------------------
# MEASURED on the real lab: the FOREIGN workload LB carries run.tanzu.vmware.com/cluster.name while
# the real control-plane LB does NOT. Selecting on that label picks the wrong object entirely.
foreign="$(printf '{"metadata":{"name":"%s","labels":{"run.tanzu.vmware.com/cluster.name":"%s"}},"spec":{"type":"LoadBalancer","ports":[{"port":%s}]},"status":{"loadBalancer":{"ingress":[%s]}}}' \
  "$FX_FOREIGN" "$FX_CLUSTER" "$FX_FOREIGN_PORT" "$(ing_ip "$FX_FOREIGN_IP")")"
out="$(run_case "$FX_CLUSTER" "$FX_ADV" "$foreign")"
check "foreign tenant LB is NOT adopted"      "CANNOT IDENTIFY" "$out"
case "$out" in *"$FX_FOREIGN_IP"*) echo "  FAIL  must not name another tenant's VIP as ours"; fail=$((fail + 1)) ;;
               *) echo "  PASS  must not name another tenant's VIP as ours"; pass=$((pass + 1)) ;; esac

# --- AMBIGUITY: two candidates => decline, do not pick ------------------------------------------
two="$(cp_svc "$FX_CLUSTER" "$FX_CLUSTER" "$(ing_ip "$FX_LB")"),$(cp_svc "$FX_CLUSTER_B" "$FX_CLUSTER" "$(ing_ip "$FX_LB_B")")"
out="$(run_case "$FX_CLUSTER" "$FX_ADV" "$two")"
check "two candidates => declines to judge"   "declining to judge" "$out"
check "two candidates => lists them"          "$FX_CLUSTER_B" "$out"

# The wait-branch GATE that consumes this function's verdict is tested by
# test-cluster-status-wait-gate.sh, which runs 26-vks-cluster-status.sh itself. It is NOT tested
# here on purpose: a first attempt asserted a hand-typed COPY of the guard's pattern, and an
# adversary deleted the whole shipped guard while this file still reported 24/24. A copy of a
# predicate proves nothing about the predicate that ships.

echo
echo "endpoint_report: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
