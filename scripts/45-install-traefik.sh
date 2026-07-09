#!/usr/bin/env bash
# 45-install-traefik.sh — install ONE Traefik ingress controller (a single
# LoadBalancer) that fronts the browser UIs at *.vks.local, so operators reach
# Gitea / ArgoCD / the app by hostname instead of `kubectl port-forward`.
#
# Scope (decided with the owner): UIs only. Harbor keeps its OWN direct
# LoadBalancer — its LB IP is load-bearing for the containerd insecure-registry
# pull path (see 06-install-harbor.sh), so it is NOT routed through Traefik.
#
# Air-gap honest: hostnames resolve via /etc/hosts on the jump box/clients ->
# Traefik's single LB IP. No internet DNS, no sslip.io. The Traefik image is
# pulled from Harbor (mirrored), like every other workload. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
: "${TRAEFIK_NAMESPACE:?}"
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
: "${ARGOCD_NAMESPACE:?}"; : "${ARGOCD_HOST:?}"
: "${ARGOCD_DEST_NAMESPACE:?}"; : "${WEBUI_HOST:?}"; : "${APP_NAME:?}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

K8S_DIR="${REPO_ROOT}/k8s/traefik"

# envsubst allowlists — single-quoted so envsubst gets the literal ${VAR} NAMES
# (only these are substituted; anything else, e.g. a shell $ in a manifest, is
# left untouched).
# shellcheck disable=SC2016
CTRL_ALLOWLIST='${HARBOR_URL} ${HARBOR_INFRA_PROJECT} ${TRAEFIK_NAMESPACE}'
# shellcheck disable=SC2016
ING_ALLOWLIST='${GITEA_NAMESPACE} ${GITEA_HOST} ${ARGOCD_NAMESPACE} ${ARGOCD_HOST} ${ARGOCD_DEST_NAMESPACE} ${WEBUI_HOST} ${APP_NAME}'

# --- 1. Install the controller (namespace, RBAC, IngressClass, Deployment, LB) ---
log_info "installing Traefik controller into namespace '${TRAEFIK_NAMESPACE}'"
# shellcheck disable=SC2016
envsubst "$CTRL_ALLOWLIST" < "${K8S_DIR}/controller.yaml" | run kubectl apply -f -

log_info "waiting for Traefik to become ready (timeout ${READY_TIMEOUT_SECONDS}s)"
run kubectl -n "$TRAEFIK_NAMESPACE" rollout status deploy/traefik \
  --timeout="${READY_TIMEOUT_SECONDS}s"

# --- 2. Ingress objects live in each backend's namespace; ensure they exist ---
# gitea + argocd already exist; the app namespace is created by ArgoCD with
# CreateNamespace, but the app Ingress may be applied before the first sync, so
# pre-create it (ArgoCD adopts an existing namespace).
for ns in "$GITEA_NAMESPACE" "$ARGOCD_NAMESPACE" "$ARGOCD_DEST_NAMESPACE"; do
  run bash -c "kubectl create namespace \"$ns\" --dry-run=client -o yaml | kubectl apply -f -"
done

log_info "applying Ingress objects (gitea/argocd/app -> *.vks.local)"
# shellcheck disable=SC2016
envsubst "$ING_ALLOWLIST" < "${K8S_DIR}/ingress.yaml" | run kubectl apply -f -

# --- 3. Discover the Traefik LoadBalancer IP -----------------------------------
log_info "waiting for Traefik LoadBalancer IP (timeout ${READY_TIMEOUT_SECONDS}s, poll ${POLL_INTERVAL_SECONDS}s)"
LB_IP=""
elapsed=0
while :; do
  LB_IP="$(kubectl -n "$TRAEFIK_NAMESPACE" get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$LB_IP" ] && break
  elapsed=$(( elapsed + POLL_INTERVAL_SECONDS ))
  [ "$elapsed" -ge "$READY_TIMEOUT_SECONDS" ] && die "Traefik LoadBalancer IP not assigned within ${READY_TIMEOUT_SECONDS}s"
  log_info "LB IP not assigned yet — retrying in ${POLL_INTERVAL_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done
log_info "Traefik LoadBalancer IP: ${LB_IP}"

# --- 4. Publish the IP + emit the /etc/hosts guidance --------------------------
set_env_var INGRESS_LB_IP "$LB_IP"
log_info "published INGRESS_LB_IP=${LB_IP} to ${REPO_ROOT}/.env.kind"

log_info "Traefik installed. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${ARGOCD_HOST} ${WEBUI_HOST}"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${ARGOCD_HOST}  http://${WEBUI_HOST}"
log_info "(no more 'kubectl port-forward' for the UIs; Harbor keeps its own LB IP)"
