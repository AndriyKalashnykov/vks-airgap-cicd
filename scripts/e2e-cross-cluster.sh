#!/usr/bin/env bash
# e2e-cross-cluster.sh — faithful validation of the cross-cluster ArgoCD registration mechanic
# (the real-lab topology: ArgoCD runs in a HUB cluster = the Supervisor; workloads deploy into a
# separate GUEST cluster). Stands up TWO kind clusters:
#   HUB   (cc-hub)   — runs a minimal upstream ArgoCD (the "Supervisor ArgoCD" stand-in)
#   GUEST (cc-guest) — the workload cluster webui should land in
# then: register GUEST with HUB via `make argocd-register-guest`, prove the stored credential
# actually reaches GUEST, and prove ArgoCD in HUB SYNCS an Application whose destination is GUEST
# (the resource appears in GUEST, not HUB). PSA/RBAC/token/secret/cross-cluster-sync are validated
# identically to a real lab; only provider-specifics (guest API routability from a real Supervisor,
# real guest API TLS/CA, hub-side ValidatingAdmissionPolicy) stay real-lab-only. See the
# argocd-cross-cluster-registration memory + the deep-research verdict.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

require_cmd kind    "install kind (make deps)"
require_cmd kubectl "install kubectl (make deps)"
require_cmd docker  "the kind cross-cluster e2e needs Docker (shared kind network)"

HUB="${CC_HUB_CLUSTER:-cc-hub}"
GUEST="${CC_GUEST_CLUSTER:-cc-guest}"
ARGOCD_NS="${ARGOCD_NAMESPACE:-argocd}"
# renovate: datasource=github-releases depName=argoproj/argo-cd
ARGOCD_MANIFEST_VERSION="${ARGOCD_VERSION:-v3.4.5}"
WORK="$(mktemp -d)"
HUB_KC="${WORK}/hub.kubeconfig"
GUEST_KC="${WORK}/guest.kubeconfig"

cleanup() {
  kind delete cluster --name "$HUB"   >/dev/null 2>&1 || true
  kind delete cluster --name "$GUEST" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

log_info "creating two kind clusters: HUB=$HUB (ArgoCD) + GUEST=$GUEST (workload)"
kind create cluster --name "$HUB"   >/dev/null
kind create cluster --name "$GUEST" >/dev/null
kind get kubeconfig --name "$HUB"   > "$HUB_KC"
kind get kubeconfig --name "$GUEST" > "$GUEST_KC"
# INTERNAL server URL of the guest API — reachable from HUB pods on the shared kind docker network
# (the stand-in for a real guest control-plane VIP routable from the Supervisor).
GUEST_INTERNAL_SERVER="$(kind get kubeconfig --name "$GUEST" --internal | \
  kubectl --kubeconfig /dev/stdin config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
log_info "guest internal API (routable from hub pods): $GUEST_INTERNAL_SERVER"

hub()   { kubectl --kubeconfig "$HUB_KC" "$@"; }
guest() { kubectl --kubeconfig "$GUEST_KC" "$@"; }

log_info "installing upstream ArgoCD $ARGOCD_MANIFEST_VERSION into HUB ns/$ARGOCD_NS"
hub create namespace "$ARGOCD_NS" >/dev/null
hub -n "$ARGOCD_NS" apply -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_MANIFEST_VERSION}/manifests/install.yaml" >/dev/null
log_info "waiting for the ArgoCD application-controller + repo-server + redis to be Ready"
hub -n "$ARGOCD_NS" rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null
hub -n "$ARGOCD_NS" rollout status deploy/argocd-repo-server --timeout=180s >/dev/null

# ---------------------------------------------------------------------------
# 1. Register GUEST with HUB's ArgoCD via the real target under test.
# ---------------------------------------------------------------------------
log_info "== registering GUEST with HUB via make argocd-register-guest =="
KUBECONFIG="$GUEST_KC" GUEST_KUBECONFIG="$GUEST_KC" ARGOCD_KUBECONFIG="$HUB_KC" \
  ARGOCD_NAMESPACE="$ARGOCD_NS" ARGOCD_DEST_CLUSTER_NAME="$GUEST" \
  GUEST_API_SERVER="$GUEST_INTERNAL_SERVER" \
  "${SCRIPT_DIR}/71-argocd-register-guest.sh"

# ASSERT A — the ArgoCD Cluster secret exists in HUB with the guest server.
sec="$(hub -n "$ARGOCD_NS" get secret -l argocd.argoproj.io/secret-type=cluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$sec" ] || die "FAIL: no ArgoCD Cluster secret created in HUB ns/$ARGOCD_NS"
reg_server="$(hub -n "$ARGOCD_NS" get secret "$sec" -o jsonpath='{.data.server}' | base64 -d)"
[ "$reg_server" = "$GUEST_INTERNAL_SERVER" ] || die "FAIL: registered server '$reg_server' != guest '$GUEST_INTERNAL_SERVER'"
log_info "PASS A: HUB has Cluster secret '$sec' → server $reg_server"

# ASSERT B — the stored bearer token actually authenticates to GUEST (the credential works).
tok="$(hub -n "$ARGOCD_NS" get secret "$sec" -o jsonpath='{.data.config}' | base64 -d | sed -n 's/.*"bearerToken":"\([^"]*\)".*/\1/p')"
[ -n "$tok" ] || die "FAIL: no bearerToken in the Cluster secret config"
guest_host_server="$(guest config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if kubectl --server "$guest_host_server" --token "$tok" --insecure-skip-tls-verify get nodes >/dev/null 2>&1; then
  log_info "PASS B: the registered argocd-manager token authenticates to GUEST (credential is valid + durable)"
else
  die "FAIL: the registered token does NOT authenticate to GUEST — registration credential is broken"
fi

# ---------------------------------------------------------------------------
# 2. Prove ArgoCD in HUB SYNCS an Application whose destination is GUEST.
#    Source: a trivial in-tree manifest served from THIS public repo (validates cross-cluster
#    reconciliation, not air-gap — the air-gap path is covered by the single-cluster e2e-kind).
# ---------------------------------------------------------------------------
log_info "== creating an ArgoCD Application in HUB with destination=GUEST =="
hub -n "$ARGOCD_NS" apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cc-probe
  namespace: ${ARGOCD_NS}
spec:
  project: default
    # CC_PROBE_REVISION lets a pre-merge run point ArgoCD at the branch under test (the probe
    # manifest must exist at that ref on the PUSHED remote); defaults to main once merged.
  source:
    repoURL: ${CC_PROBE_REPO:-https://github.com/AndriyKalashnykov/vks-airgap-cicd.git}
    targetRevision: ${CC_PROBE_REVISION:-main}
    path: test/cross-cluster-probe
  destination:
    server: ${GUEST_INTERNAL_SERVER}
    namespace: cc-probe
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ "CreateNamespace=true" ]
EOF

log_info "waiting for the Application to become Synced+Healthy and the ConfigMap to land in GUEST"
ok=0
for _ in $(seq 1 60); do
  if guest -n cc-probe get configmap cc-probe-marker >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
# ASSERT C — the resource is in GUEST and NOT in HUB (proves the cross-cluster destination).
if [ "$ok" = 1 ] && ! hub -n cc-probe get configmap cc-probe-marker >/dev/null 2>&1; then
  log_info "PASS C: ArgoCD in HUB deployed the ConfigMap into GUEST (and NOT into HUB) — cross-cluster destination works"
else
  hub -n "$ARGOCD_NS" get application cc-probe -o jsonpath='{.status.sync.status} {.status.health.status} {.status.conditions}' 2>/dev/null || true
  die "FAIL: the cross-cluster Application did not land the ConfigMap in GUEST (or it leaked into HUB)"
fi

log_info "e2e-cross-cluster: OK — registration credential valid + ArgoCD in HUB synced cross-cluster into GUEST"
