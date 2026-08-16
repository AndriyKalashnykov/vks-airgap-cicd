#!/usr/bin/env bash
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
trap 'rm -rf "$TMP"' EXIT
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
  *"get nodes"*)   printf '' ;;      # never Ready -> the wait loop must run to its timeout
  version)         echo "Client Version: v1.34.0" ;;
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

echo
echo "cluster-status wait gate: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
