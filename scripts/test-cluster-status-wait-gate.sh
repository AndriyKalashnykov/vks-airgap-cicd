#!/usr/bin/env bash
# ci-tier: slow — a never-Ready cluster must run the wait loop to its timeout (~16s)
# test-cluster-status-wait-gate.sh — the demonstrated RED for B92's wait-branch endpoint gate.
#
# WHY IT DRIVES THE REAL SCRIPT. The first version of this test asserted a hand-typed COPY of the
# guard's `case` pattern. An implementation-round adversary deleted the ENTIRE 541-byte guard from
# `26-vks-cluster-status.sh` and the test still reported "24 passed, 0 failed", rc=0 — it was green
# over a deleted feature, and it was wired into `test-scripts`, so `static-check` certified nothing.
# `test-endpoint-report.sh`'s own header forbids exactly that: "never a copy — a copy would drift
# from the thing that ships and would prove nothing about it."
#
# So this runs `scripts/26-vks-cluster-status.sh` itself, with a stub kubectl and a stub kubeconfig.
#
# ASSERT ELAPSED, NOT ONLY rc. The wait branch ALREADY exits 1 when it times out, so rc alone cannot
# tell "refused up front" from "burned the whole budget" — which is the entire point of B92. The
# discriminator is TIME: refused in under a second, or still running when the budget expires.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; mkdir -p "$TMP/bin" "$TMP/secrets"
# 26-vks-cluster-status.sh:43 writes ${REPO_ROOT}/secrets/${VKS_CLUSTER_NAME}.kubeconfig, and this
# test drives it with VKS_CLUSTER_NAME=testcluster -- so a plain run LEFT a 0-byte
# secrets/testcluster.kubeconfig in the real repo. Measured: it was sitting there after
# `make static-check`. Stale kubeconfigs in secrets/ are B467's hazard, since no target takes a
# cluster argument and an operator exporting the wrong one acts on the wrong cluster.
#
# Remove ONLY what THIS RUN created. If an operator genuinely has a cluster named `testcluster`,
# their file predates us and must survive.
#
# ⚠️ RESIDUAL, measured and NOT fixed here: if that file pre-exists, the script under test
# TRUNCATES it to 0 bytes before this trap ever runs, so its CONTENT is already gone. The clean fix
# is to stop the child writing into the real repo at all, but pointing it at a throwaway
# REPO_ROOT was tried and broke 4 of the 13 cases -- the script needs the real root for more than
# this path. Filed as B470.
STRAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets/testcluster.kubeconfig"
STRAY_PREEXISTED=0
[ -e "$STRAY" ] && STRAY_PREEXISTED=1
trap 'rm -rf "$TMP"; if [ "$STRAY_PREEXISTED" -eq 0 ]; then rm -f "$STRAY"; fi' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

NS=testns
CL=testcluster
PORT=6443

# A kubectl that models the REAL argv shapes 26 sends. STUB_ADV / STUB_LB drive the verdict.
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *controlPlaneEndpoint.port*) printf '%s' "${STUB_PORT:-6443}" ;;
  *controlPlaneEndpoint.host*) printf '%s' "${STUB_ADV:-}" ;;
  *"get svc -o json"*)
    printf '{"items":[{"metadata":{"name":"%s","ownerReferences":[{"kind":"VirtualMachineService","name":"%s"}]},"spec":{"type":"LoadBalancer","ports":[{"port":%s}]},"status":{"loadBalancer":{"ingress":[{"ip":"%s"}]}}}]}' \
      "${STUB_CL:-testcluster}" "${STUB_CL:-testcluster}" "${STUB_PORT:-6443}" "${STUB_LB:-}" ;;
  *"get cluster"*-o*json*)
    # B110: a transport failure here used to print "NOT FOUND", a claim about the cluster derived
    # from a connection that never happened.
    if [ "${STUB_CLUSTER_FAIL:-}" = x509 ]; then
      echo 'Unable to connect to the server: tls: failed to verify certificate: x509: certificate signed by unknown authority' >&2
      exit 1
    fi
    printf '{}' ;;
  *"get nodes"*)   printf '' ;;      # never Ready -> the wait loop must run to its timeout
  version)         echo "Client Version: v1.34.0" ;;
  *api-resources*) echo 'virtualmachineclasses  vmclass  vmoperator.vmware.com/v1alpha5  false  VirtualMachineClass' ;;  # a REAL SUPERVISOR: these modes inject a failure into the READ, not into what the cluster IS. GLOB, because this stub switches on "$*", not on a parsed subcommand.

  *)               printf '' ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"
# NON-EMPTY on purpose: `supervisor_kubeconfig` in lib/os.sh tests `[ -s "$c" ]`, so an empty
# file is (correctly) not accepted as a kubeconfig and the resolver falls through to the repo
# path, which does not exist -> the script dies before the branch under test. Measured.
printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$TMP/secrets/sup.kubeconfig"

# run_wait <advertised> <lb> -> prints "<rc> <elapsed_seconds>"; stdout of the run goes to $TMP/out
run_wait() {
  local t0 t1 rc
  t0=$SECONDS
  (
    PATH="$TMP/bin:$PATH" \
    STUB_ADV="$1" STUB_LB="$2" STUB_CL="$CL" STUB_PORT="$PORT" \
    SKIP_DOTENV=1 \
    VKS_SUPERVISOR_KUBECONFIG="$TMP/secrets/sup.kubeconfig" \
    VKS_CLUSTER_NAME="$CL" VKS_NAMESPACE="$NS" \
    VKS_CLUSTER_WAIT_SECONDS=8 VKS_CLUSTER_POLL_SECONDS=2 \
    bash "$SCRIPT_DIR/26-vks-cluster-status.sh"
  ) > "$TMP/out" 2>&1
  rc=$?
  t1=$SECONDS
  printf '%s %s' "$rc" "$((t1 - t0))"
}

echo "== B92: the wait branch must read the endpoint ONCE, before spending the budget =="

# --- DIVERGENT: advertised != the control-plane LB. Must refuse immediately. -------------------
read -r rc el <<<"$(run_wait 192.0.2.137 192.0.2.138)"
if [ "$rc" -ne 0 ]; then ok "divergent: refuses (rc=$rc)"; else bad "divergent: refuses" "rc=0"; fi
if [ "$el" -lt 4 ]; then ok "divergent: refuses UP FRONT (${el}s < the 8s budget)"
else bad "divergent: refuses UP FRONT" "took ${el}s — it burned the wait budget, i.e. the guard did not fire"; fi
if grep -q 'DIVERGENT' "$TMP/out"; then ok "divergent: the remedy is printed"
else bad "divergent: the remedy is printed" "no DIVERGENT line in the output"; fi

# --- AGREE: must NOT be blocked. It falls through and waits out the budget. --------------------
read -r rc el <<<"$(run_wait 192.0.2.138 192.0.2.138)"
if [ "$el" -ge 8 ]; then ok "agree: falls through and WAITS (${el}s >= 8s)"
else bad "agree: falls through and WAITS" "returned after ${el}s — a healthy cluster was refused"; fi
if ! grep -q 'refusing to wait' "$TMP/out"; then ok "agree: not refused"
else bad "agree: not refused" "the guard fired on an AGREE verdict"; fi

# --- NOT YET KNOWABLE: an empty advertised endpoint must fall through, not refuse. -------------
read -r rc el <<<"$(run_wait "" 192.0.2.138)"
if [ "$el" -ge 8 ]; then ok "empty endpoint: falls through and WAITS (${el}s)"
else bad "empty endpoint: falls through and WAITS" "returned after ${el}s — a provisioning cluster was refused"; fi

# --- B110 (4 of 4): report() must not call a transport failure "NOT FOUND" ---------------------
# The report-once path (WAIT_SECONDS=0) is where an operator reads this line, and it is advertised
# read-only, so it must still exit 0 — only the WORDING is at issue.
(
  PATH="$TMP/bin:$PATH" STUB_ADV=192.0.2.138 STUB_LB=192.0.2.138 STUB_CL="$CL" STUB_PORT="$PORT" \
  STUB_CLUSTER_FAIL=x509 SKIP_DOTENV=1 \
  VKS_SUPERVISOR_KUBECONFIG="$TMP/secrets/sup.kubeconfig" \
  VKS_CLUSTER_NAME="$CL" VKS_NAMESPACE="$NS" VKS_CLUSTER_WAIT_SECONDS=0 \
  bash "$SCRIPT_DIR/26-vks-cluster-status.sh"
) > "$TMP/rep" 2>&1 || true
if grep -q 'COULD NOT ASK' "$TMP/rep"; then ok "report: a transport failure says COULD NOT ASK"
else bad "report: a transport failure says COULD NOT ASK" "$(tail -2 "$TMP/rep")"; fi
if grep -q 'NOT FOUND' "$TMP/rep"; then bad "report: must NOT say NOT FOUND on a transport failure" "it did"
else ok "report: does NOT say NOT FOUND on a transport failure"; fi
if grep -q 'rebuilt CA' "$TMP/rep"; then ok "report: names the rebuilt-CA cause"
else bad "report: names the rebuilt-CA cause" "$(tail -2 "$TMP/rep")"; fi

echo
echo "== B117: a DEFINITIVE NotFound is an ANSWER — do not wait, and do not call it 'could not ask' =="

# THIS STUB IS DEFINED LAST, on purpose: it overwrites $TMP/bin/kubectl, so it must come AFTER every
# case above has run. (My first attempt spliced it in the middle and the B92 cases then ran against
# an always-NotFound kubectl and hung — the harness's own stub ordering is load-bearing.)
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"get cluster"*)
    echo 'Error from server (NotFound): clusters.cluster.x-k8s.io "'"${STUB_CL:-testcluster}"'" not found' >&2
    exit 1 ;;
  *controlPlaneEndpoint.port*) printf '%s' "${STUB_PORT:-6443}" ;;
  *controlPlaneEndpoint.host*) printf '%s' "${STUB_ADV:-}" ;;
  *"get svc -o json"*) printf '{"items":[]}' ;;
  version) echo "Client Version: v1.34.0" ;;
  *api-resources*) echo 'virtualmachineclasses  vmclass  vmoperator.vmware.com/v1alpha5  false  VirtualMachineClass' ;;  # a REAL SUPERVISOR: these modes inject a failure into the READ, not into what the cluster IS. GLOB, because this stub switches on "$*", not on a parsed subcommand.

  *) printf '' ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

read -r rc el <<<"$(run_wait 192.0.2.137 192.0.2.137)"
if [ "$rc" -ne 0 ]; then ok "notfound: refuses (rc=$rc)"; else bad "notfound: refuses" "rc=0"; fi
# THE assertion. rc alone cannot tell a refusal from a full budget burn, and the real defect was
# 1806 SECONDS spent waiting for a Cluster whose create had already been rejected.
if [ "$el" -lt 4 ]; then ok "notfound: refuses UP FRONT (${el}s < the 8s budget)"
else bad "notfound: refuses UP FRONT" "took ${el}s — it burned the budget on an object that does not exist"; fi
if grep -q 'DOES NOT EXIST' "$TMP/out"; then ok "notfound: says DOES NOT EXIST"
else bad "notfound: says DOES NOT EXIST" "$(grep -m1 'cluster ' "$TMP/out" || echo '<no verdict line>')"; fi
# The line that shipped and was FALSE here: every classifier arm ends with it.
if grep -q "this is NOT 'the cluster does not exist'" "$TMP/out"; then
  bad "notfound: must not print the 'NOT the cluster does not exist' line" "it did — that claim is false for a NotFound"
else
  ok "notfound: does not print the 'NOT the cluster does not exist' line"
fi

echo
echo "cluster-status wait gate: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
