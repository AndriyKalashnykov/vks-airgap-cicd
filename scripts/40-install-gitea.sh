#!/usr/bin/env bash
# 40-install-gitea.sh — install Gitea on VKS from k8s/gitea/gitea.yaml (image from
# Harbor). SQLite backend, single replica, self-contained (no chart to mirror).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${GITEA_NAMESPACE:?}"; : "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
# GITEA_URL DERIVES from GITEA_HOST (the ingress hostname) so the hostname has ONE source of
# truth. It used to be a second literal in .env.example kept in sync with GITEA_HOST by a prose
# "keep aligned" comment — i.e. by nothing. Set GITEA_URL explicitly only when the scheme/port
# genuinely differ from the ingress route.
GITEA_URL="${GITEA_URL:-http://${GITEA_HOST:?set GITEA_HOST (or GITEA_URL) in .env}}"
: "${GITEA_STORAGE_SIZE:?}"
# Gitea's Service type. LoadBalancer by default: ArgoCD's repo-server may live in ANOTHER cluster
# (on a real lab it is a Supervisor Service) and must clone <app>-deploy over the network. The
# in-cluster DNS name does not resolve there, and the ingress cannot serve a machine (its routes
# match the hostname gitea.vks.local, which exists only in the operator's /etc/hosts) — see the
# comment on the Service in k8s/gitea/gitea.yaml. A LoadBalancer keeps its ClusterIP, so Tekton's
# in-cluster clone/write-back over GITEA_INTERNAL_URL is unaffected.
GITEA_SERVICE_TYPE="${GITEA_SERVICE_TYPE:-LoadBalancer}"
# The air-gap default: the image mirrored into Harbor. Overridable so a test WITHOUT a Harbor (the
# cross-cluster e2e, which exercises the ArgoCD topology rather than the air gap) can still run Gitea.
GITEA_IMAGE="${GITEA_IMAGE:-${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/gitea/gitea:1.27.0-rootless}"
export GITEA_NAMESPACE HARBOR_URL HARBOR_INFRA_PROJECT GITEA_URL GITEA_STORAGE_SIZE GITEA_SERVICE_TYPE GITEA_IMAGE
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
LB_TIMEOUT_SECONDS="${GITEA_LB_TIMEOUT_SECONDS:-180}"

# shellcheck disable=SC2016
ALLOWLIST='${GITEA_NAMESPACE} ${HARBOR_URL} ${HARBOR_INFRA_PROJECT} ${GITEA_URL} ${GITEA_STORAGE_SIZE} ${GITEA_SERVICE_TYPE} ${GITEA_IMAGE}'

log_info "installing Gitea into namespace '$GITEA_NAMESPACE' (Service type: ${GITEA_SERVICE_TYPE})"
# shellcheck disable=SC2016
envsubst "$ALLOWLIST" < "${REPO_ROOT}/k8s/gitea/gitea.yaml" | run kubectl apply -f -

log_info "waiting for Gitea to become ready (timeout ${READY_TIMEOUT_SECONDS}s)"
run kubectl -n "$GITEA_NAMESPACE" rollout status deploy/gitea --timeout="${READY_TIMEOUT_SECONDS}s"

# --- publish the address an OFF-CLUSTER ArgoCD can clone from -------------------------------------
# GITEA_ARGOCD_URL is what k8s/argocd/application.yaml's repoURL is rendered with. It MUST be
# routable from the cluster ArgoCD runs in. When ArgoCD is in THIS cluster (KinD, ArgoCD-in-guest)
# the in-cluster URL is correct and this is a no-op; when it is not, only the LB address works.
if [ "$GITEA_SERVICE_TYPE" = "LoadBalancer" ]; then
  log_info "waiting for the Gitea LoadBalancer to be assigned an address (timeout ${LB_TIMEOUT_SECONDS}s)"
  GITEA_LB_IP=""
  for _ in $(seq 1 "$LB_TIMEOUT_SECONDS"); do
    GITEA_LB_IP="$(kubectl -n "$GITEA_NAMESPACE" get svc gitea-http \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -n "$GITEA_LB_IP" ] && break
    sleep 1
  done
  if [ -n "$GITEA_LB_IP" ]; then
    # Publish the IP for humans (`make creds-show`) — but NOT a GITEA_ARGOCD_URL for a later step to
    # read back as an input. 70-configure-argocd.sh RESOLVES the address from the live Service at the
    # moment it needs it, so a rebuilt Gitea can never be cloned from a stale address. (Publishing it
    # as an input is the trap INGRESS_LB_IP_OVERRIDE exists to avoid.)
    state_set GITEA_LB_IP "$GITEA_LB_IP"
    log_info "Gitea LoadBalancer: ${GITEA_LB_IP}:3000 (published as GITEA_LB_IP)"
  else
    # NOT fatal here: a single-cluster deploy never needs it. It IS fatal in 70-configure-argocd.sh,
    # which refuses to build a repoURL an off-cluster ArgoCD cannot reach.
    log_warn "the Gitea LoadBalancer never got an address — no cluster-external Gitea URL."
    log_warn "  Fine when ArgoCD runs in THIS cluster. If it does NOT, 'make gitops' will refuse to"
    log_warn "  continue: set GITEA_ARGOCD_URL_OVERRIDE to an address the ArgoCD cluster can reach."
  fi
fi

log_info "Gitea installed. In-cluster (Tekton): ${GITEA_INTERNAL_URL:-http://gitea-http.${GITEA_NAMESPACE}.svc:3000}"
log_info "next: make seed-gitea"
