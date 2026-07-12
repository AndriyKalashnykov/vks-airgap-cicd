#!/usr/bin/env bash
# 47-attach-istio.sh — SCENARIO 2: Istio is ALREADY installed (by the platform team /
# as a cluster add-on) and we must NOT install it. We install NOTHING: we DISCOVER the
# existing mesh and attach only our own routes.
#
# This is INGRESS_CONTROLLER=istio-existing.
#
# What "configuring Istio we didn't install" actually means (all KinD-proven — see
# docs/decisions/istio-on-vks.md):
#
#   * There are NO Istio credentials. Istio has no login, no token, no admin API.
#     Access to the mesh is plain kubectl RBAC. The only credential-shaped object is a
#     TLS Secret named by Gateway.tls.credentialName, which must live in the GATEWAY's
#     namespace — so it is something you REQUEST from the mesh admin, never something
#     you "fetch". (Contrast Harbor/ArgoCD, which do have real admin passwords.)
#
#   * You must DISCOVER, not assume, the gateway's `istio:` selector label. The
#     istio/gateway helm chart derives it from the HELM RELEASE NAME, so a mesh you did
#     not install is very unlikely to use `istio: ingressgateway`. A Gateway whose
#     selector matches no workload is accepted by the API server WITHOUT error and binds
#     nothing: Envoy never gets a listener, and the symptom is connection-refused.
#
#   * Three attach shapes, in decreasing order of what you are allowed to do:
#       (a) you may create a Gateway in the gateway namespace  -> default here
#       (b) the platform owns a shared Gateway you may only reference
#           -> set ISTIO_SHARED_GATEWAY=<ns>/<name>; we create only VirtualServices
#       (c) you may not even READ the gateway namespace
#           -> ask the mesh admin for ISTIO_GATEWAY_NAMESPACE / _SERVICE / _LABEL and set
#              them in .env; discovery is then skipped entirely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/istio.sh
. "${SCRIPT_DIR}/lib/istio.sh"
load_env

require_cmd kubectl
require_cmd jq
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
: "${ARGOCD_DEST_NAMESPACE:?}"; : "${WEBUI_HOST:?}"; : "${APP_NAME:?}"
: "${TEKTON_NAMESPACE:?}"; : "${TEKTON_DASHBOARD_HOST:?}"

log_info "INGRESS_CONTROLLER=istio-existing — attaching to an Istio we did NOT install"

# --- 1. Discover the mesh -----------------------------------------------------
istio_discover || die "Istio discovery failed — see the guidance above. (Is Istio actually installed on this cluster? \`kubectl get pods -A -l app=istiod\`)"
istio_report

[ "${ISTIO_GATEWAY_API}" = "classic" ] || \
  die "this cluster does not serve the classic Istio route API (networking.istio.io VirtualService CRD missing; detected API: ${ISTIO_GATEWAY_API}). A Gateway-API-only mesh needs HTTPRoutes instead — not yet supported by this repo."

# Refuse to silently no-op if the mesh is not actually there.
[ -n "${ISTIOD_NAMESPACE:-}" ] || die "no istiod found — nothing to attach to. Use INGRESS_CONTROLLER=istio to INSTALL Istio instead."

# --- 2. Guard: never install anything in this mode -----------------------------
# If our own release names are present, the operator is in the wrong mode.
if helm status istiod -n "${ISTIOD_NAMESPACE}" >/dev/null 2>&1; then
  log_warn "istiod carries OUR helm release name — this mesh may have been installed by 'make install-istio'."
  log_warn "  That is fine (attach still works), but INGRESS_CONTROLLER=istio is the mode that OWNS it."
fi

# --- 3. Attach our routes ------------------------------------------------------
istio_apply_routes

# --- 4. External address -------------------------------------------------------
if [ -n "${INGRESS_LB_IP:-}" ]; then
  log_info "using operator-supplied INGRESS_LB_IP=${INGRESS_LB_IP}"
  LB_IP="$INGRESS_LB_IP"
else
  LB_IP="$(istio_wait_lb_ip)" || die "could not resolve the ingress gateway's external address (set INGRESS_LB_IP in .env if the gateway is fronted by something else)"
fi

set_env_var INGRESS_LB_IP "$LB_IP"
set_env_var INGRESS_CONTROLLER "istio-existing"
log_info "attached to the existing Istio at ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE} (${LB_IP})"
log_info "Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${WEBUI_HOST} ${TEKTON_DASHBOARD_HOST}"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${WEBUI_HOST}  http://${TEKTON_DASHBOARD_HOST}"
