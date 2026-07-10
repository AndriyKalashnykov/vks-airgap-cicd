#!/usr/bin/env bash
# 46-install-istio.sh — install Istio as the ingress controller: control plane
# (istiod) + one ingress-gateway LoadBalancer, fronting the browser UIs at
# *.vks.local. Default INGRESS_CONTROLLER; the lighter Traefik is the option.
#
# Air-gap: the istio images (pilot/proxyv2) are pulled from Harbor via the helm
# `global.hub` override (mirrored per images/images.txt). No sidecar injection is
# enabled — the gateway routes to each backend Service's ClusterIP directly, so
# the app/Gitea/ArgoCD pods stay sidecar-free. Idempotent (helm upgrade --install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd helm
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
: "${ISTIO_VERSION:?}"; : "${ISTIO_NAMESPACE:?}"; : "${ISTIO_GATEWAY_NAMESPACE:?}"
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
: "${ARGOCD_NAMESPACE:?}"
: "${ARGOCD_DEST_NAMESPACE:?}"; : "${WEBUI_HOST:?}"; : "${APP_NAME:?}"
: "${TEKTON_NAMESPACE:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

CHART_REPO_NAME="istio"
CHART_REPO_URL="https://istio-release.storage.googleapis.com/charts"
HUB="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/istio"
K8S_DIR="${REPO_ROOT}/k8s/istio"

# --- 1. Helm repo (fetched on the internet side; images come from Harbor) ------
log_info "adding/updating helm repo '${CHART_REPO_NAME}' (${CHART_REPO_URL})"
run helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" --force-update
run helm repo update "$CHART_REPO_NAME"

# --- 2. CRDs (istio/base) -----------------------------------------------------
log_info "installing istio-base (CRDs) v${ISTIO_VERSION} into ${ISTIO_NAMESPACE}"
run helm upgrade --install istio-base "${CHART_REPO_NAME}/base" \
  --namespace "$ISTIO_NAMESPACE" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s"

# --- 3. Control plane (istiod), images from Harbor ----------------------------
log_info "installing istiod v${ISTIO_VERSION} (hub=${HUB})"
run helm upgrade --install istiod "${CHART_REPO_NAME}/istiod" \
  --namespace "$ISTIO_NAMESPACE" \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set global.hub="$HUB" \
  --set global.tag="$ISTIO_VERSION" \
  --set global.proxy.autoInject=disabled \
  --set meshConfig.enableTracing=false \
  --set pilot.autoscaleEnabled=false

# --- 4. Ingress gateway (LoadBalancer), images from Harbor --------------------
log_info "installing istio ingress gateway (LoadBalancer) into ${ISTIO_GATEWAY_NAMESPACE}"
run helm upgrade --install istio-ingressgateway "${CHART_REPO_NAME}/gateway" \
  --namespace "$ISTIO_GATEWAY_NAMESPACE" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set service.type=LoadBalancer \
  --set labels.istio=ingressgateway \
  --set global.hub="$HUB" \
  --set global.tag="$ISTIO_VERSION"

# --- 5. Backend namespaces + Gateway/VirtualService routing -------------------
for ns in "$GITEA_NAMESPACE" "$ARGOCD_NAMESPACE" "$ARGOCD_DEST_NAMESPACE"; do
  run bash -c "kubectl create namespace \"$ns\" --dry-run=client -o yaml | kubectl apply -f -"
done
log_info "applying Gateway + VirtualServices (gitea/argocd/app/tekton -> *.vks.local)"
# shellcheck disable=SC2016
ALLOWLIST='${ISTIO_GATEWAY_NAMESPACE} ${GITEA_HOST} ${GITEA_NAMESPACE} ${WEBUI_HOST} ${APP_NAME} ${ARGOCD_DEST_NAMESPACE} ${TEKTON_DASHBOARD_HOST} ${TEKTON_NAMESPACE}'
# shellcheck disable=SC2016
envsubst "$ALLOWLIST" < "${K8S_DIR}/gateway.yaml" | run kubectl apply -f -

# --- 6. Discover the ingress-gateway LoadBalancer IP --------------------------
log_info "waiting for istio ingress-gateway LoadBalancer IP (timeout ${READY_TIMEOUT_SECONDS}s)"
LB_IP=""
elapsed=0
while :; do
  LB_IP="$(kubectl -n "$ISTIO_GATEWAY_NAMESPACE" get svc istio-ingressgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$LB_IP" ] && break
  elapsed=$(( elapsed + POLL_INTERVAL_SECONDS ))
  [ "$elapsed" -ge "$READY_TIMEOUT_SECONDS" ] && die "istio ingress-gateway LoadBalancer IP not assigned within ${READY_TIMEOUT_SECONDS}s"
  log_info "LB IP not assigned yet — retrying in ${POLL_INTERVAL_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done
log_info "istio ingress-gateway LoadBalancer IP: ${LB_IP}"

# --- 7. Publish the IP + emit the /etc/hosts guidance -------------------------
set_env_var INGRESS_LB_IP "$LB_IP"
log_info "published INGRESS_LB_IP=${LB_IP} to ${REPO_ROOT}/.env.kind"
log_info "Istio installed. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${WEBUI_HOST} ${TEKTON_DASHBOARD_HOST}"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${WEBUI_HOST}  http://${TEKTON_DASHBOARD_HOST}"
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
log_info "(no port-forward for the UIs; Harbor keeps its own LB IP)"
