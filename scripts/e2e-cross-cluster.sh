#!/usr/bin/env bash
# e2e-cross-cluster.sh — faithful validation of the cross-cluster ArgoCD registration mechanic
# (the real-lab topology: ArgoCD runs in a HUB cluster = the Supervisor; workloads deploy into a
# separate GUEST cluster). Stands up TWO kind clusters:
#   HUB   (cc-hub)   — runs a minimal upstream ArgoCD (the "Supervisor ArgoCD" stand-in)
#   GUEST (cc-guest) — the workload cluster javawebapp should land in
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
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

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
# Guest API endpoint reachable from HUB pods on the shared kind docker network — the guest
# control-plane container's IP (NOT `kind ... --internal`'s container HOSTNAME, which pod CoreDNS
# can't resolve). Stand-in for a real guest control-plane VIP routable from the Supervisor.
guest_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${GUEST}-control-plane" 2>/dev/null | tr -d '[:space:]')"
[ -n "$guest_ip" ] || die "could not resolve the guest control-plane container IP"
GUEST_INTERNAL_SERVER="https://${guest_ip}:6443"
log_info "guest API (routable from hub pods, by IP): $GUEST_INTERNAL_SERVER"

hub()   { kubectl --kubeconfig "$HUB_KC" "$@"; }
guest() { kubectl --kubeconfig "$GUEST_KC" "$@"; }

log_info "installing upstream ArgoCD $ARGOCD_MANIFEST_VERSION into HUB ns/$ARGOCD_NS"
hub create namespace "$ARGOCD_NS" >/dev/null
# --server-side: the ArgoCD install bundles a large CRD (applicationsets) that overflows the
# client-side-apply last-applied-configuration annotation (256KB limit).
hub -n "$ARGOCD_NS" apply --server-side --force-conflicts -f \
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
  GUEST_API_SERVER="$GUEST_INTERNAL_SERVER" ARGOCD_REGISTER_INSECURE=1 \
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
# The token goes into a umask-077 kubeconfig FILE, never onto argv: `kubectl --token=<secret>` is
# visible to any local user via `ps -ef` / /proc/<pid>/cmdline for the life of the process. Same rule
# as the rest of this repo (common/security.md) — a throwaway kind cluster is not an excuse.
tok_kc="${WORK}/argocd-manager.kubeconfig"
( umask 077; cat > "$tok_kc" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: g
    cluster: { server: ${guest_host_server}, insecure-skip-tls-verify: true }
contexts:
  - name: g
    context: { cluster: g, user: argocd-manager }
current-context: g
users:
  - name: argocd-manager
    user: { token: ${tok} }
EOF
)
if kubectl --kubeconfig "$tok_kc" get nodes >/dev/null 2>&1; then
  log_info "PASS B: the registered argocd-manager token authenticates to GUEST (credential is valid + durable)"
else
  die "FAIL: the registered token does NOT authenticate to GUEST — registration credential is broken"
fi

# ---------------------------------------------------------------------------
# 2. THE REGRESSION TEST — run the REAL `make gitops` (70-configure-argocd.sh) across the two
#    clusters, with a REAL Gitea in the GUEST.
#
#    It used to HAND-WRITE its Application here and sync from a public GitHub repo. That is why it
#    could not see either of the two CRITICALs it should have caught:
#      * 70 applied the Application to $KUBECONFIG — the GUEST — while ArgoCD lives in the HUB;
#      * the repoURL was the guest's cluster-local Gitea DNS name, which a HUB repo-server cannot
#        resolve.
#    Calling the real script is what makes this a regression test rather than a demonstration.
# ---------------------------------------------------------------------------

# The argoproj CRDs must exist in GUEST too — otherwise "no Application landed in GUEST" is true BY
# CONSTRUCTION (the kind has no CRD) and the assertion below can never fail. A gate that cannot fail
# is not a gate.
log_info "installing the argoproj CRDs into GUEST (so 'no Application in GUEST' is a REAL assertion)"
guest apply --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_MANIFEST_VERSION}/manifests/crds/application-crd.yaml" >/dev/null
guest apply --server-side --force-conflicts -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_MANIFEST_VERSION}/manifests/crds/appproject-crd.yaml" >/dev/null

# --- a REAL Gitea in the GUEST, reachable FROM THE HUB ---------------------------------------
# NodePort on the guest's container IP: the same shared-kind-network mechanism this script already
# uses for the guest API server. cloud-provider-kind is NOT running here, so a LoadBalancer would
# never get an address.
log_info "installing Gitea into GUEST (NodePort — the HUB's repo-server must be able to clone it)"
export KUBECONFIG="$GUEST_KC"
export GITEA_SERVICE_TYPE=NodePort
export GITEA_IMAGE="gitea/gitea:1.26.4-rootless"      # no Harbor in this e2e (topology test, not air-gap)
export GITEA_HOST="gitea.cc.local"
export GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-CrossCluster12345}"
export GITEA_CI_PASSWORD="${GITEA_CI_PASSWORD:-CrossCluster12345}"
"${SCRIPT_DIR}/40-install-gitea.sh"

nodeport="$(guest -n "${GITEA_NAMESPACE:-gitea}" get svc gitea-http -o jsonpath='{.spec.ports[0].nodePort}')"
[ -n "$nodeport" ] || die "Gitea got no NodePort"
GITEA_FROM_HUB="http://${guest_ip}:${nodeport}"
log_info "Gitea, as the HUB will see it: $GITEA_FROM_HUB"

# Seed the deploy repos through the SAME address the HUB will clone (the seeder pushes over HTTP).
export GITEA_URL="$GITEA_FROM_HUB"
export GITEA_INTERNAL_URL="http://gitea-http.${GITEA_NAMESPACE:-gitea}.svc:3000"   # the guest-local name (the BUG's value)
"${SCRIPT_DIR}/50-seed-gitea-repos.sh"

# --- RED 1: the OLD repoURL (guest cluster-local DNS) must be REFUSED -------------------------
# This is CRITICAL #2, reproduced. An off-cluster repo-server cannot resolve gitea-http.gitea.svc.
log_info "== RED 1: 70 must REFUSE a guest cluster-local repoURL when ArgoCD is off-cluster =="
if KUBECONFIG="$GUEST_KC" ARGOCD_KUBECONFIG="$HUB_KC" ARGOCD_NAMESPACE="$ARGOCD_NS" \
   GITEA_ARGOCD_URL="$GITEA_INTERNAL_URL" ARGOCD_DEST_CLUSTER_NAME="$GUEST" \
   "${SCRIPT_DIR}/70-configure-argocd.sh" >/dev/null 2>&1; then
  die "FAIL: 70 ACCEPTED a cluster-local repoURL for an OFF-CLUSTER ArgoCD — CRITICAL #2 would ship again."
fi
log_info "RED 1 OK — refused (the repo-server could never have cloned it)"

# --- the REAL run: ArgoCD in HUB, workload in GUEST, Gitea reachable ---------------------------
log_info "== running the REAL 70-configure-argocd.sh across the two clusters =="
KUBECONFIG="$GUEST_KC" ARGOCD_KUBECONFIG="$HUB_KC" ARGOCD_NAMESPACE="$ARGOCD_NS" \
  GITEA_ARGOCD_URL="$GITEA_FROM_HUB" ARGOCD_DEST_CLUSTER_NAME="$GUEST" \
  "${SCRIPT_DIR}/70-configure-argocd.sh"

# --- ASSERT C: the Applications are in the HUB, and NOT in the GUEST --------------------------
# This is CRITICAL #1. Before the fix, 70 applied them to $KUBECONFIG (the GUEST).
rc=0
while read -r app; do
  [ -n "$app" ] || continue
  if ! hub -n "$ARGOCD_NS" get application "$app" >/dev/null 2>&1; then
    log_error "  ${app}: NOT in the HUB — 70 wrote the Application to the wrong cluster (CRITICAL #1)"; rc=1; continue
  fi
  if guest -n "$ARGOCD_NS" get application "$app" >/dev/null 2>&1; then
    log_error "  ${app}: found in the GUEST — 70 wrote it to the workload cluster (CRITICAL #1)"; rc=1; continue
  fi
  dest="$(hub -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.spec.destination.server}{.spec.destination.name}')"
  repo="$(hub -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.spec.source.repoURL}')"
  rev="$(hub -n "$ARGOCD_NS" get application "$app" -o jsonpath='{.status.sync.revision}')"
  case "$repo" in *".svc"*) log_error "  ${app}: repoURL is cluster-local (${repo}) — CRITICAL #2"; rc=1 ;; esac
  [ -n "$rev" ] || { log_error "  ${app}: ArgoCD never fetched a revision from ${repo} — the HUB cannot reach Gitea"; rc=1; }
  log_info "  ${app}: in HUB · destination=${dest} · repo=${repo} · fetched revision=${rev:-<none>}"
done <<EOF
$(app_names)
EOF
[ "$rc" = 0 ] || die "FAIL: the cross-cluster GitOps wiring is wrong"

log_info "PASS C: every Application is in the HUB (not the GUEST), targets the GUEST, and ArgoCD"
log_info "  actually FETCHED a revision from a Gitea it can reach. Both CRITICALs are now covered."
log_info "e2e-cross-cluster: OK"
