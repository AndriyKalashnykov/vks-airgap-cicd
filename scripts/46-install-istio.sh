#!/usr/bin/env bash
# 46-install-istio.sh — SCENARIO 1: we INSTALL Istio and use it as the ingress.
# Control plane (istiod) + one ingress-gateway LoadBalancer fronting the browser UIs
# at *.vks.local. This is INGRESS_CONTROLLER=istio (the default).
#
# If the platform team already runs Istio on the cluster, do NOT use this script —
# use INGRESS_CONTROLLER=istio-existing (scripts/47-attach-istio.sh), which installs
# nothing and only attaches routes. Running this against a mesh you do not own would
# helm-install a SECOND control plane over theirs.
#
# Air-gap: the istio images (pilot/proxyv2) come from Harbor via the helm `global.hub`
# override (mirrored per images/images.txt). Sidecar injection is disabled — the gateway
# routes to each backend Service's ClusterIP directly, so app/Gitea/Tekton pods stay
# sidecar-free. Idempotent (helm upgrade --install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/istio.sh
. "${SCRIPT_DIR}/lib/istio.sh"
load_env

require_cmd kubectl
require_cmd helm
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
: "${ISTIO_VERSION:?}"; : "${ISTIO_NAMESPACE:?}"
# The gateway namespace is OUR install's default and lives here, not in .env.example:
# an uncommented global would be sourced into the environment in istio-existing mode too,
# constraining discovery to our own naming and hiding the platform team's real gateway.
ISTIO_GATEWAY_NAMESPACE="${ISTIO_GATEWAY_NAMESPACE:-istio-ingress}"
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
: "${ARGOCD_DEST_NAMESPACE:?}"; : "${WEBUI_HOST:?}"; : "${APP_NAME:?}"
: "${TEKTON_NAMESPACE:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

CHART_REPO_NAME="istio"
CHART_REPO_URL="https://istio-release.storage.googleapis.com/charts"
HUB="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/istio"

# We own this mesh, so we PIN the gateway's identity rather than discovering it. The
# helm release name IS the Service name, and `labels.istio` is what a Gateway selector
# must match — the gateway chart would otherwise derive that label from the release name.
GW_RELEASE="istio-ingressgateway"
ISTIO_GATEWAY_SERVICE="$GW_RELEASE"
ISTIO_GATEWAY_LABEL="ingressgateway"
export ISTIO_GATEWAY_SERVICE ISTIO_GATEWAY_LABEL

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
run helm upgrade --install "$GW_RELEASE" "${CHART_REPO_NAME}/gateway" \
  --namespace "$ISTIO_GATEWAY_NAMESPACE" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set service.type=LoadBalancer \
  --set labels.istio="$ISTIO_GATEWAY_LABEL" \
  --set global.hub="$HUB" \
  --set global.tag="$ISTIO_VERSION"

# --- 4b. PSA labels for the namespaces helm just created ----------------------
# VKS enforces `restricted` by default (VKr v1.26+) and istiod/the gateway proxy set no
# seccompProfile, so both namespaces need `baseline` or their pods are REJECTED on a real
# guest cluster. Measured with `make psa-check`, not guessed.
psa_label_namespace "$ISTIO_NAMESPACE"         "${PSA_LEVEL_ISTIO_SYSTEM:-baseline}"
psa_label_namespace "$ISTIO_GATEWAY_NAMESPACE" "${PSA_LEVEL_INGRESS:-baseline}"

# --- 5. Gateway + VirtualServices (shared with the attach path) ---------------
istio_apply_routes

# --- 6. LoadBalancer address --------------------------------------------------
LB_IP="$(istio_wait_lb_ip)" || die "istio ingress-gateway has no LoadBalancer address"
log_info "istio ingress-gateway LoadBalancer address: ${LB_IP}"

# --- 7. Publish + emit the /etc/hosts guidance --------------------------------
set_env_var INGRESS_LB_IP "$LB_IP"
log_info "published INGRESS_LB_IP=${LB_IP} to ${REPO_ROOT}/.env.kind"
log_info "Istio installed. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${WEBUI_HOST} ${TEKTON_DASHBOARD_HOST}"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${WEBUI_HOST}  http://${TEKTON_DASHBOARD_HOST}"
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
log_info "(no port-forward for the UIs; Harbor keeps its own LB IP)"
