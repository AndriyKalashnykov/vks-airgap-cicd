#!/usr/bin/env bash
# 71-argocd-register-guest.sh — register the GUEST/workload cluster as a destination with an
# ArgoCD instance that runs in a DIFFERENT cluster (the real-lab case: ArgoCD is a Supervisor
# Service on the Supervisor; javawebapp must deploy into the guest cluster).
#
# It does NOT install a second ArgoCD in the guest — it only:
#   1. GUEST cluster: creates an `argocd-manager` ServiceAccount + a cluster-admin binding
#      + a NON-EXPIRING (legacy) token Secret. The durable token sidesteps the x509
#      client-cert #13175 trap (an x509-auth guest kubeconfig would otherwise make ArgoCD
#      store an EXPIRING cert → cluster goes Unknown). See the argocd-cross-cluster memory.
#   2. ArgoCD cluster: creates the ArgoCD `Cluster` Secret (label secret-type=cluster) in
#      ARGOCD_NAMESPACE, carrying the guest API URL + CA + the durable bearer token.
#   3. Publishes ARGOCD_DEST_SERVER (the guest API URL) so `make gitops` targets the guest.
#
# Registering a cluster is an ArgoCD-ADMIN operation (research-confirmed: `clusters` is a global
# ArgoCD RBAC resource, and minting the cluster-admin argocd-manager RBAC needs cluster-admin on
# the guest). A pure VKS tenant cannot self-service this — they request it from the platform team.
#
# Secrets never touch argv: the token/CA are embedded in manifests applied over STDIN.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl "install kubectl (make deps)"

# --- inputs ------------------------------------------------------------------
# GUEST_KUBECONFIG : the workload cluster where javawebapp deploys (default: the flow's $KUBECONFIG).
# ARGOCD_KUBECONFIG: the cluster the ArgoCD instance runs in (the Supervisor / the e2e ArgoCD box).
GUEST_KUBECONFIG="${GUEST_KUBECONFIG:-${KUBECONFIG:?KUBECONFIG (guest cluster) must be set}}"
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}"
: "${ARGOCD_NAMESPACE:?ARGOCD_NAMESPACE must be set (namespace the ArgoCD instance watches)}"

# ---- IS REGISTRATION EVEN NEEDED? DERIVE IT; DO NOT REMEMBER IT ----------------------------------
# `make gitops` used to force-run this whenever ARGOCD_KUBECONFIG was merely SET — which meant it
# minted a cluster-admin ClusterRoleBinding on the guest even when both kubeconfigs pointed at the
# SAME cluster (nothing to register), and it made the tenant path impossible: the README told tenants
# not to set ARGOCD_KUBECONFIG (registration is admin-only), but 70 NEEDS it to write the Application.
#
# ARGOCD_REGISTER=auto|never|force
#   auto  (default) — register only if ArgoCD is OFF-CLUSTER and the guest is not registered yet.
#   never           — a TENANT: registration is someone else's job. Skip, quietly.
#   force           — register even if it looks unnecessary.
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"
ARGOCD_REGISTER="${ARGOCD_REGISTER:-auto}"

if [ "$ARGOCD_REGISTER" = never ]; then
  log_info "ARGOCD_REGISTER=never — skipping guest-cluster registration (a tenant REQUESTS it from the platform team)."
  exit 0
fi
if [ "$ARGOCD_REGISTER" != force ]; then
  if ! argocd_is_off_cluster "$ARGOCD_KUBECONFIG" "$GUEST_KUBECONFIG" 2>/dev/null; then
    log_info "ArgoCD runs in the SAME cluster as the workload — nothing to register."
    exit 0
  fi
  guest_api="$(argocd_api_server "$GUEST_KUBECONFIG")"
  already="$(kubectl --kubeconfig "$ARGOCD_KUBECONFIG" -n "$ARGOCD_NAMESPACE" \
      get secret -l argocd.argoproj.io/secret-type=cluster \
      -o go-template="$ARGOCD_CLUSTER_LIST_TEMPLATE" 2>/dev/null \
    | argocd_pick_dest_server "$guest_api" "${ARGOCD_DEST_CLUSTER_NAME:-}" || true)"
  if [ -n "$already" ]; then
    log_info "the guest cluster is ALREADY registered with this ArgoCD ($already) — nothing to do."
    exit 0
  fi
  # Registration mints a cluster-admin ClusterRoleBinding on the guest AND writes a Secret into the
  # ArgoCD namespace. A tenant can do neither. Say so plainly instead of failing with a stack of
  # Forbidden errors.
  if [ "$(kubectl --kubeconfig "$ARGOCD_KUBECONFIG" auth can-i create secrets -n "$ARGOCD_NAMESPACE" 2>/dev/null || echo no)" != yes ]; then
    log_warn "you may not create Secrets in ns/${ARGOCD_NAMESPACE} on the ArgoCD cluster — registration is ADMIN-only."
    log_warn "  REQUEST from your platform team: register guest cluster '$(kubectl --kubeconfig "$GUEST_KUBECONFIG" config current-context 2>/dev/null || echo guest)' ($guest_api) as an ArgoCD destination."
    log_warn "  Then set ARGOCD_DEST_CLUSTER_NAME (the name they registered it under) and re-run 'make gitops'."
    log_warn "  Skipping registration (set ARGOCD_REGISTER=never to silence this)."
    exit 0
  fi
fi
ARGOCD_MANAGER_SA="${ARGOCD_MANAGER_SA:-argocd-manager}"
ARGOCD_MANAGER_NS="${ARGOCD_MANAGER_NS:-kube-system}"
[ -f "$GUEST_KUBECONFIG" ]  || die "GUEST_KUBECONFIG not found: $GUEST_KUBECONFIG"
[ -f "$ARGOCD_KUBECONFIG" ] || die "ARGOCD_KUBECONFIG not found: $ARGOCD_KUBECONFIG"

kg() { kubectl --kubeconfig "$GUEST_KUBECONFIG" "$@"; }   # guest cluster
ka() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" "$@"; }  # ArgoCD cluster

# A stable name for the registered destination (the guest cluster's context name).
DEST_NAME="${ARGOCD_DEST_CLUSTER_NAME:-$(kg config current-context 2>/dev/null || echo guest)}"

log_info "registering guest '$DEST_NAME' with the ArgoCD instance in ns/$ARGOCD_NAMESPACE (ArgoCD cluster: $(ka config current-context 2>/dev/null || echo '?'))"
ka get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
  || die "ArgoCD namespace '$ARGOCD_NAMESPACE' not found on the ArgoCD cluster — is ArgoCD installed there?"

# --- 1. GUEST: argocd-manager SA + cluster-admin binding + durable token ------
log_info "guest: creating '$ARGOCD_MANAGER_SA' ServiceAccount + cluster-admin binding + durable token"
kg apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${ARGOCD_MANAGER_SA}
  namespace: ${ARGOCD_MANAGER_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${ARGOCD_MANAGER_SA}-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: ${ARGOCD_MANAGER_SA}
    namespace: ${ARGOCD_MANAGER_NS}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${ARGOCD_MANAGER_SA}-token
  namespace: ${ARGOCD_MANAGER_NS}
  annotations:
    kubernetes.io/service-account.name: ${ARGOCD_MANAGER_SA}
type: kubernetes.io/service-account-token
EOF

# Wait for the token controller to populate the Secret (non-expiring legacy token).
for _ in $(seq 1 30); do
  TOKEN="$(kg -n "$ARGOCD_MANAGER_NS" get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$TOKEN" ] && break
  sleep 1
done
[ -n "${TOKEN:-}" ] || die "guest: the argocd-manager token Secret did not populate — check the SA token controller"

CA_DATA="$(kg -n "$ARGOCD_MANAGER_NS" get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"

# --- 2. resolve the guest API URL ArgoCD will dial ---------------------------
# GUEST_API_SERVER overrides (must be ROUTABLE from the ArgoCD cluster — on a real lab the guest
# control-plane VIP; in the two-KinD e2e the guest's --internal API on the shared kind network).
if [ -n "${GUEST_API_SERVER:-}" ]; then
  SERVER="$GUEST_API_SERVER"
else
  SERVER="$(kg config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
fi
[ -n "$SERVER" ] || die "could not resolve the guest API server URL — set GUEST_API_SERVER"
log_info "guest API server ArgoCD will dial: $SERVER"

# --- 3. ArgoCD cluster: create the destination Cluster Secret ----------------
# tlsClientConfig.caData present ⇒ verify TLS; absent ⇒ insecure (self-signed without a CA handy).
if [ "${ARGOCD_REGISTER_INSECURE:-0}" = "1" ]; then
  # Opt-in: skip TLS verify of the guest API (the two-KinD stand-in reaches the guest by raw IP,
  # which may not be in the API cert SAN — the guest-API TLS/CA specifics are a real-lab-only concern).
  TLS_CFG="\"tlsClientConfig\":{\"insecure\":true}"
elif [ -n "$CA_DATA" ]; then
  TLS_CFG="\"tlsClientConfig\":{\"caData\":\"${CA_DATA}\"}"
else
  log_warn "no CA in the SA token secret — registering with insecure TLS"
  TLS_CFG="\"tlsClientConfig\":{\"insecure\":true}"
fi
CONFIG_JSON="{\"bearerToken\":\"${TOKEN}\",${TLS_CFG}}"
SECRET_NAME="cluster-$(printf '%s' "$DEST_NAME" | tr -c 'a-z0-9-' '-' | cut -c1-40)"

log_info "argocd: creating Cluster Secret '$SECRET_NAME' (secret-type=cluster) in ns/$ARGOCD_NAMESPACE"
# Manifest (with the token) goes over STDIN — never argv.
ka apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: "${DEST_NAME}"
  server: "${SERVER}"
  config: '${CONFIG_JSON}'
EOF

# --- 4. publish ARGOCD_DEST_SERVER so `make gitops` targets the guest --------
set_env_var ARGOCD_DEST_SERVER "$SERVER"
log_info "registered. ARGOCD_DEST_SERVER=$SERVER written to .env.kind — 'make gitops' will now deploy to the guest cluster."
log_info "verify: kubectl --kubeconfig \$ARGOCD_KUBECONFIG -n $ARGOCD_NAMESPACE get secret -l argocd.argoproj.io/secret-type=cluster"
