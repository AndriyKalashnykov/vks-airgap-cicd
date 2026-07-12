#!/usr/bin/env bash
# 48-istio-preflight.sh — answer, against the LIVE cluster: "Istio is here (or isn't);
# what exactly do I need in order to route my UIs through it, and what must I ask the
# mesh admin for?"
#
# Read-only. Installs nothing, applies nothing. Run it BEFORE `make install-ingress`
# on any cluster you do not own (a real VKS guest cluster, a shared lab).
#
# It exists because the two things an operator reaches for first do not exist:
#   * there is no Istio "credential" to fetch (no login, no token, no admin API —
#     mesh access is kubectl RBAC), and
#   * the gateway's selector label is NOT a constant: the istio/gateway helm chart
#     derives it from the helm RELEASE NAME, so it must be read off the live cluster.
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
: "${GITEA_HOST:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
: "${GITEA_NAMESPACE:?}"; : "${TEKTON_NAMESPACE:?}"
# Every app has its own namespace + host — both come from the registry.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

rc=0

echo "===================== Istio preflight =====================" >&2
log_info "cluster: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"

# --- 1. Is Istio installed at all? --------------------------------------------
if ! kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1 \
   && ! kubectl get deploy -A -l app=istiod -o name 2>/dev/null | grep -q .; then
  log_warn "NO Istio detected on this cluster."
  log_warn "  -> Use INGRESS_CONTROLLER=istio (the default) and 'make install-ingress' to INSTALL it,"
  log_warn "     or INGRESS_CONTROLLER=traefik for the lighter option."
  echo "==========================================================" >&2
  exit 0
fi

# --- 1b. Which route API will we use? -----------------------------------------
# Gateway API is preferred when Istio is an accepted GatewayClass — it is what Broadcom's VKS
# walkthrough uses, and it needs NOTHING from the mesh admin (Istio provisions the data plane
# and the LoadBalancer for the Gateway we create in our own namespace). Report that plainly:
# it is usually the difference between "I must file a ticket" and "I can just deploy".
istio_detect_route_api

if [ "$ISTIO_ROUTE_API" = "gateway-api" ]; then
  log_info "MODE: Kubernetes GATEWAY API (GatewayClass '${ISTIO_GATEWAY_CLASS:-istio}' is Accepted)."
  log_info "  -> INGRESS_CONTROLLER=istio-existing installs nothing and needs NOTHING from the mesh admin:"
  log_info "     we create a Gateway in '${ISTIO_GWAPI_NAMESPACE:-vks-ingress}' and HTTPRoutes in our own"
  log_info "     namespaces; Istio auto-provisions the proxy + its LoadBalancer (image inherited from"
  log_info "     istiod's hub, so it pulls from Harbor on an air-gapped cluster)."
  log_info "  RBAC you need (own namespaces only):"
  for ns in "${ISTIO_GWAPI_NAMESPACE:-vks-ingress}" "$GITEA_NAMESPACE" "$TEKTON_NAMESPACE" $(app_names | tr '\n' ' '); do
    printf '    %-46s gateways=%s httproutes=%s\n' "$ns" \
      "$(kubectl auth can-i create gateways.gateway.networking.k8s.io -n "$ns" 2>/dev/null || echo no)" \
      "$(kubectl auth can-i create httproutes.gateway.networking.k8s.io -n "$ns" 2>/dev/null || echo no)" >&2
  done
  echo >&2
  log_info "PREFLIGHT OK — 'make install-ingress INGRESS_CONTROLLER=istio-existing' will use the Gateway API."
  log_info "(Set ISTIO_ROUTE_API=classic to force the legacy Gateway/VirtualService path instead.)"
  echo "==========================================================" >&2
  exit 0
fi

# --- classic path: we must FIND the platform's gateway workload ----------------
if ! istio_discover; then
  log_error "Istio is present but discovery failed (most likely: no RBAC to read it)."
  log_error "  -> ASK THE MESH ADMIN for these three values and set them in .env:"
  log_error "       ISTIO_GATEWAY_NAMESPACE=<ns of the ingress-gateway Service>"
  log_error "       ISTIO_GATEWAY_SERVICE=<its Service name>"
  log_error "       ISTIO_GATEWAY_LABEL=<the value of its spec.selector.istio label>"
  log_error "     With those set, 'make install-ingress INGRESS_CONTROLLER=istio-existing' needs no read access."
  echo "==========================================================" >&2
  exit 1
fi

istio_report

# --- 2. Ownership: did WE install this mesh, or someone else? ------------------
if [ "${ISTIO_GATEWAY_LABEL}" = "ingressgateway" ] && helm status istiod -n "${ISTIOD_NAMESPACE}" >/dev/null 2>&1; then
  log_info "MODE: this mesh looks like OURS ('make install-istio' installed it)."
  log_info "  -> INGRESS_CONTROLLER=istio"
else
  log_info "MODE: this mesh was installed by SOMEONE ELSE (selector istio=${ISTIO_GATEWAY_LABEL})."
  log_info "  -> INGRESS_CONTROLLER=istio-existing   (installs nothing; attaches routes only)"
  log_info "  NOTE: a Gateway hardcoded to 'istio: ingressgateway' would bind NOTHING here."
fi

# --- 3. What may we actually DO? (the real tenant boundary) -------------------
echo >&2
log_info "RBAC — what this kubeconfig may do (the mesh has no credentials; this IS the access model):"
check() { # <what> <kubectl auth can-i args...>
  local what="$1"; shift
  local ans; ans="$(kubectl auth can-i "$@" 2>/dev/null || echo no)"
  printf '  %-58s %s\n' "$what" "$ans" >&2
  [ "$ans" = "yes" ]
}
CAN_MAKE_GW=0
check "read the gateway Service (${ISTIO_GATEWAY_NAMESPACE})"  get svc     -n "$ISTIO_GATEWAY_NAMESPACE" || \
  log_warn "  (discovery still worked above — but a kubeconfig that cannot read it must be HANDED ISTIO_GATEWAY_* values)"
check "create a Gateway in ${ISTIO_GATEWAY_NAMESPACE}"         create gateways.networking.istio.io -n "$ISTIO_GATEWAY_NAMESPACE" && CAN_MAKE_GW=1
check "create VirtualServices in ${GITEA_NAMESPACE}"           create virtualservices.networking.istio.io -n "$GITEA_NAMESPACE" || rc=1
while read -r _a; do [ -n "$_a" ] || continue
  check "create VirtualServices in ${_a}" create virtualservices.networking.istio.io -n "$_a" || rc=1
done <<EOF
$(app_names)
EOF
check "create VirtualServices in ${TEKTON_NAMESPACE}"          create virtualservices.networking.istio.io -n "$TEKTON_NAMESPACE" || rc=1

echo >&2
if [ "$CAN_MAKE_GW" -eq 1 ]; then
  log_info "PLAN: you may create your own Gateway -> leave ISTIO_SHARED_GATEWAY unset."
else
  log_warn "PLAN: you may NOT create a Gateway in ${ISTIO_GATEWAY_NAMESPACE}."
  log_warn "  -> ASK THE MESH ADMIN to expose your hosts on a shared Gateway, then set:"
  log_warn "       ISTIO_SHARED_GATEWAY=${ISTIO_GATEWAY_NAMESPACE}/<their-gateway-name>"
  log_warn "     Its servers[].hosts must admit (exactly, or via a *.vks.local wildcard):"
  log_warn "       ${GITEA_HOST}  ${TEKTON_DASHBOARD_HOST}  $(app_names | while read -r a; do [ -n "$a" ] && printf '%s  ' "$(app_host "$a")"; done)"
  log_warn "     We then create ONLY VirtualServices, in our own namespaces. That is enough:"
  log_warn "     a VS in the app's namespace referencing <gw-ns>/<gw-name> routes correctly."
fi

# If a shared gateway is already configured, prove it admits our hosts NOW,
# rather than discovering at curl time that our VirtualServices can never match.
if [ -n "${ISTIO_SHARED_GATEWAY:-}" ]; then
  echo >&2
  log_info "checking the configured shared Gateway ${ISTIO_SHARED_GATEWAY} admits our hosts..."
  istio_assert_shared_gateway_hosts || rc=1
fi

# --- 4. External address ------------------------------------------------------
echo >&2
GW_TYPE="$(kubectl -n "$ISTIO_GATEWAY_NAMESPACE" get svc "$ISTIO_GATEWAY_SERVICE" -o jsonpath='{.spec.type}' 2>/dev/null || echo '<unreadable>')"
GW_IP="$(kubectl -n "$ISTIO_GATEWAY_NAMESPACE" get svc "$ISTIO_GATEWAY_SERVICE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
log_info "gateway Service type=${GW_TYPE} externalAddress=${GW_IP:-<none>}"
if [ "$GW_TYPE" != "LoadBalancer" ] && [ -z "${INGRESS_LB_IP:-}" ]; then
  log_warn "  the gateway is not a LoadBalancer and INGRESS_LB_IP is unset — the *.vks.local UIs"
  log_warn "  will not be reachable. Ask the mesh admin for the address that fronts it, then set INGRESS_LB_IP."
  rc=1
fi

echo >&2
if [ "$rc" -eq 0 ]; then
  log_info "PREFLIGHT OK — 'make install-ingress INGRESS_CONTROLLER=istio-existing' should succeed."
else
  log_error "PREFLIGHT INCOMPLETE — resolve the items above (most need the mesh admin, not you)."
fi
echo "==========================================================" >&2
exit "$rc"
