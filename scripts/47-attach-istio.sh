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

# INGRESS_LB_IP is OUR OWN PUBLISHED STATE, never an input here.
#
# Every install/attach writes the address it resolved into .env.state (state_set INGRESS_LB_IP);
# load_env sources that back, and 44-install-ingress.sh (which load_envs and then exec's us)
# EXPORTS it into our environment. So after any previous run INGRESS_LB_IP is always set, and it
# is indistinguishable from a deliberate operator override. Consuming it produced a FALSE GREEN:
# a Gateway-API attach reported the PREVIOUS classic gateway's IP and the route check passed
# through the classic routes still left in the cluster — the new path was never exercised.
#
# So: this script always RESOLVES the address of the gateway it is actually attaching to.
# A genuine override lives in its own unambiguous variable, which nothing auto-publishes.
unset INGRESS_LB_IP
LB_OVERRIDE="${INGRESS_LB_IP_OVERRIDE:-}"

require_cmd kubectl
require_cmd jq
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
: "${TEKTON_NAMESPACE:?}"; : "${TEKTON_DASHBOARD_HOST:?}"

log_info "INGRESS_CONTROLLER=istio-existing — attaching to an Istio we did NOT install"

# --- 1. Is a mesh even here? ---------------------------------------------------
ISTIOD_NAMESPACE="${ISTIOD_NAMESPACE:-$(kubectl get deploy -A -l app=istiod -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)}"
[ -n "${ISTIOD_NAMESPACE:-}" ] || \
  die "no istiod found — nothing to attach to. Use INGRESS_CONTROLLER=istio to INSTALL Istio instead."
export ISTIOD_NAMESPACE
ISTIO_DISCOVERED_VERSION="$(kubectl -n "$ISTIOD_NAMESPACE" get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
export ISTIO_DISCOVERED_VERSION

# --- 2. WHICH route API? -------------------------------------------------------
# Gateway API is preferred when Istio is an accepted GatewayClass: it is what Broadcom's
# VKS walkthrough uses, it needs nothing outside our own namespaces, and it works even when
# the VKS Istio package's shared ingress gateway is off (its default).
istio_detect_route_api

case "$ISTIO_ROUTE_API" in
  gateway-api)
    log_info "attaching via the Kubernetes Gateway API — Istio will provision the data plane + LoadBalancer itself"
    istio_discover >/dev/null 2>&1 || true   # best-effort: only so we can clean up any classic routes we own
    istio_drop_other_api_routes gateway-api
    istio_apply_routes_gwapi
    if [ -n "$LB_OVERRIDE" ]; then
      log_info "using INGRESS_LB_IP_OVERRIDE=${LB_OVERRIDE}"
      LB_IP="$LB_OVERRIDE"
    else
      LB_IP="$(istio_wait_gwapi_address)" || die "Istio did not program the Gateway"
    fi
    ATTACHED_AT="Gateway ${ISTIO_GWAPI_NAMESPACE}/${ISTIO_GATEWAY_NAME} (gatewayClassName=${ISTIO_GATEWAY_CLASS})"
    ;;

  classic)
    log_info "attaching via the classic Istio API (no accepted 'istio' GatewayClass on this cluster)"
    # Only the classic path needs to FIND the platform's gateway workload.
    istio_discover || die "Istio discovery failed — see the guidance above."
    istio_report
    istio_drop_other_api_routes classic
    if helm status istiod -n "${ISTIOD_NAMESPACE}" >/dev/null 2>&1; then
      log_warn "istiod carries OUR helm release name — this mesh may have been installed by 'make install-istio'."
      log_warn "  That is fine (attach still works), but INGRESS_CONTROLLER=istio is the mode that OWNS it."
    fi
    istio_apply_routes
    if [ -n "$LB_OVERRIDE" ]; then
      log_info "using INGRESS_LB_IP_OVERRIDE=${LB_OVERRIDE}"
      LB_IP="$LB_OVERRIDE"
    else
      LB_IP="$(istio_wait_lb_ip)" || die "could not resolve the ingress gateway's external address (set INGRESS_LB_IP_OVERRIDE in .env if the gateway is fronted by something else)"
    fi
    ATTACHED_AT="${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE} (selector istio=${ISTIO_GATEWAY_LABEL})"
    ;;

  *)
    die "this cluster serves neither the classic Istio route API (VirtualService CRD) nor an accepted '${ISTIO_GATEWAY_CLASS:-istio}' GatewayClass — there is no way to attach routes."
    ;;
esac

state_set INGRESS_LB_IP "$LB_IP"
state_set INGRESS_CONTROLLER "istio-existing"
log_info "attached to the existing Istio via ${ISTIO_ROUTE_API}: ${ATTACHED_AT} -> ${LB_IP}"
log_info "Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${TEKTON_DASHBOARD_HOST}  $(app_names | while read -r a; do if [ -n "$a" ]; then printf 'http://%s  ' "$(app_host "$a")"; fi; done)"
