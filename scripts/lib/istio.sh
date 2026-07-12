#!/usr/bin/env bash
# scripts/lib/istio.sh — shared Istio discovery + route application.
#
# Used by BOTH ingress modes so they cannot drift:
#   INGRESS_CONTROLLER=istio           -> 46-install-istio.sh  (we INSTALL the mesh)
#   INGRESS_CONTROLLER=istio-existing  -> 47-attach-istio.sh   (the platform team installed it;
#                                                               we install NOTHING and only attach routes)
#
# Why discovery exists at all (KinD-proven, Istio 1.30.2 — see docs/decisions/istio-on-vks.md):
# the istio/gateway helm chart derives the gateway workload's `istio:` label from the HELM
# RELEASE NAME (release `platform-gw` -> pods labelled `istio: platform-gw`). Our own install
# only gets `istio: ingressgateway` because 46-install-istio.sh forces
# `--set labels.istio=ingressgateway`. So a Gateway with a hardcoded
# `selector: {istio: ingressgateway}` binds NOTHING on a mesh someone else installed —
# and the API server accepts that Gateway without any error, so the failure is silent.
#
# shellcheck shell=bash

[ -n "${__VKS_ISTIO_SH_LOADED:-}" ] && return 0
__VKS_ISTIO_SH_LOADED=1

# ---------------------------------------------------------------------------
# istio_discover — populate the mesh facts from the LIVE cluster.
#
# Every value is overridable: if the operator set it (in .env / the environment),
# we keep it and do NOT probe. That matters for a locked-down tenant who cannot
# read the gateway namespace at all and must be HANDED the values by the mesh admin.
#
# Sets (and exports):
#   ISTIOD_NAMESPACE          ns running istiod
#   ISTIO_DISCOVERED_VERSION  the istiod image tag — ground truth, never a doc
#   ISTIO_GATEWAY_NAMESPACE   ns of the ingress-gateway Service
#   ISTIO_GATEWAY_SERVICE     name of the ingress-gateway Service
#   ISTIO_GATEWAY_LABEL       value of its `istio:` selector label  <- the load-bearing one
#   ISTIO_GATEWAY_API         classic | gateway-api  (which route API the cluster serves)
# ---------------------------------------------------------------------------
istio_discover() {
  require_cmd kubectl
  require_cmd jq

  # --- control plane -------------------------------------------------------
  if [ -z "${ISTIOD_NAMESPACE:-}" ]; then
    ISTIOD_NAMESPACE="$(kubectl get deploy -A -l app=istiod \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
  fi
  if [ -n "${ISTIOD_NAMESPACE:-}" ]; then
    ISTIO_DISCOVERED_VERSION="$(kubectl -n "$ISTIOD_NAMESPACE" get deploy istiod \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi

  # --- ingress gateway -----------------------------------------------------
  # Signature: a Service exposing the proxy status-port 15021 AND carrying an
  # `istio` selector key. istiod does NOT expose 15021 (it serves 15010/15012/443/15014),
  # so this excludes the control plane. A naive `app.kubernetes.io/part-of=istio` label
  # match picks istiod instead and every route then silently fails to bind.
  if [ -z "${ISTIO_GATEWAY_NAMESPACE:-}" ] || [ -z "${ISTIO_GATEWAY_SERVICE:-}" ] || [ -z "${ISTIO_GATEWAY_LABEL:-}" ]; then
    local candidates count
    candidates="$(kubectl get svc -A -o json 2>/dev/null | jq -c '
      [ .items[]
        | select(any(.spec.ports[]?; .port == 15021))
        | select(.spec.selector.istio != null)
        | { ns: .metadata.namespace,
            name: .metadata.name,
            type: .spec.type,
            label: .spec.selector.istio,
            lbIP: ((.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname) // "") } ]' || echo '[]')"
    count="$(printf '%s' "$candidates" | jq 'length')"

    if [ "$count" -eq 0 ]; then
      log_error "no Istio ingress-gateway Service found (looked for: a Service with port 15021 + an 'istio' selector key)."
      log_error "  If Istio IS installed but you lack RBAC to read it, ask the mesh admin for these values"
      log_error "  and set them in .env — discovery is then skipped entirely:"
      log_error "    ISTIO_GATEWAY_NAMESPACE, ISTIO_GATEWAY_SERVICE, ISTIO_GATEWAY_LABEL"
      return 1
    fi
    if [ "$count" -gt 1 ] && { [ -z "${ISTIO_GATEWAY_NAMESPACE:-}" ] || [ -z "${ISTIO_GATEWAY_SERVICE:-}" ]; }; then
      log_error "found ${count} Istio ingress gateways — ambiguous. Pick one explicitly in .env:"
      printf '%s' "$candidates" | jq -r '.[] | "    ISTIO_GATEWAY_NAMESPACE=\(.ns)  ISTIO_GATEWAY_SERVICE=\(.name)  (istio label: \(.label), type: \(.type))"' >&2
      return 1
    fi

    # Narrow by whatever the operator DID pin, then take the single remaining match.
    local sel='.[0]'
    if [ -n "${ISTIO_GATEWAY_NAMESPACE:-}" ] && [ -n "${ISTIO_GATEWAY_SERVICE:-}" ]; then
      sel="map(select(.ns == \"${ISTIO_GATEWAY_NAMESPACE}\" and .name == \"${ISTIO_GATEWAY_SERVICE}\"))[0]"
    elif [ -n "${ISTIO_GATEWAY_NAMESPACE:-}" ]; then
      sel="map(select(.ns == \"${ISTIO_GATEWAY_NAMESPACE}\"))[0]"
    fi
    local picked
    picked="$(printf '%s' "$candidates" | jq -c "$sel")"
    [ "$picked" = "null" ] && { log_error "no gateway matched ISTIO_GATEWAY_NAMESPACE/${ISTIO_GATEWAY_SERVICE:-*}"; return 1; }

    ISTIO_GATEWAY_NAMESPACE="${ISTIO_GATEWAY_NAMESPACE:-$(printf '%s' "$picked" | jq -r '.ns')}"
    ISTIO_GATEWAY_SERVICE="${ISTIO_GATEWAY_SERVICE:-$(printf '%s' "$picked" | jq -r '.name')}"
    ISTIO_GATEWAY_LABEL="${ISTIO_GATEWAY_LABEL:-$(printf '%s' "$picked" | jq -r '.label')}"
  fi

  # --- which route API does this cluster actually serve? --------------------
  if kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
    ISTIO_GATEWAY_API="classic"
  elif kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
    ISTIO_GATEWAY_API="gateway-api"
  else
    ISTIO_GATEWAY_API="none"
  fi

  export ISTIOD_NAMESPACE ISTIO_DISCOVERED_VERSION \
         ISTIO_GATEWAY_NAMESPACE ISTIO_GATEWAY_SERVICE ISTIO_GATEWAY_LABEL ISTIO_GATEWAY_API
  return 0
}

# ---------------------------------------------------------------------------
# istio_gateway_ref — the value a VirtualService must put in `gateways:`.
#
# ALWAYS namespace-qualified (`<ns>/<name>`). A BARE gateway name in a
# VirtualService resolves NAMESPACE-LOCALLY (to <vs-ns>/<name>), so a VS that
# lives in the app's namespace and names the gateway bare silently matches
# nothing — Envoy listens but returns 404. (KinD-proven.)
# ---------------------------------------------------------------------------
istio_gateway_ref() {
  if [ -n "${ISTIO_SHARED_GATEWAY:-}" ]; then
    # Operator is reusing a platform-owned Gateway: "<ns>/<name>".
    case "$ISTIO_SHARED_GATEWAY" in
      */*) printf '%s' "$ISTIO_SHARED_GATEWAY" ;;
      *)   die "ISTIO_SHARED_GATEWAY must be '<namespace>/<gateway-name>' (got '${ISTIO_SHARED_GATEWAY}')" ;;
    esac
  else
    printf '%s/%s' "${ISTIO_GATEWAY_NAMESPACE}" "${ISTIO_GATEWAY_NAME:-vks-uis}"
  fi
}

# ---------------------------------------------------------------------------
# istio_assert_shared_gateway_hosts — when REUSING a platform Gateway, prove it
# actually admits our hostnames before we apply routes that can never match.
#
# A Gateway server's `hosts` may be exact (gitea.vks.local) or wildcard
# (*.vks.local / *). If none of them covers one of our hosts, our VirtualService
# is accepted but never routes — another silent failure. Fail loudly instead,
# telling the operator exactly what to ask the mesh admin for.
# ---------------------------------------------------------------------------
istio_assert_shared_gateway_hosts() {
  [ -z "${ISTIO_SHARED_GATEWAY:-}" ] && return 0
  local gw_ns="${ISTIO_SHARED_GATEWAY%%/*}" gw_name="${ISTIO_SHARED_GATEWAY##*/}" hosts host ok rc=0
  hosts="$(kubectl -n "$gw_ns" get gateway "$gw_name" -o jsonpath='{range .spec.servers[*]}{range .hosts[*]}{@}{"\n"}{end}{end}' 2>/dev/null || true)"
  if [ -z "$hosts" ]; then
    log_error "cannot read the shared Gateway ${ISTIO_SHARED_GATEWAY} (missing, or no RBAC to get it)."
    log_error "  Ask the mesh admin to confirm it exists and admits: ${GITEA_HOST} ${WEBUI_HOST} ${TEKTON_DASHBOARD_HOST}"
    return 1
  fi
  for host in "$GITEA_HOST" "$WEBUI_HOST" "$TEKTON_DASHBOARD_HOST"; do
    ok=0
    while IFS= read -r h; do
      [ -z "$h" ] && continue
      h="${h##*/}"                                  # strip an optional "<ns>/" host prefix
      case "$h" in
        "$host") ok=1 ;;
        '*')     ok=1 ;;
        '*.'*)   case "$host" in *"${h#\*}") ok=1 ;; esac ;;   # *.vks.local covers x.vks.local
      esac
      [ "$ok" -eq 1 ] && break
    done <<EOF
$hosts
EOF
    if [ "$ok" -ne 1 ]; then
      log_error "the shared Gateway ${ISTIO_SHARED_GATEWAY} does NOT admit host '${host}'"
      rc=1
    fi
  done
  if [ "$rc" -ne 0 ]; then
    log_error "  Gateway currently admits: $(printf '%s' "$hosts" | tr '\n' ' ')"
    log_error "  ASK THE MESH ADMIN to add the missing host(s) to that Gateway's servers[].hosts,"
    log_error "  or to let you create your own Gateway in ${gw_ns} (then unset ISTIO_SHARED_GATEWAY)."
    return 1
  fi
  log_info "shared Gateway ${ISTIO_SHARED_GATEWAY} admits all three UI hosts"
  return 0
}

# ---------------------------------------------------------------------------
# istio_wait_lb_ip — resolve the gateway Service's external address.
#
# On a real VKS guest cluster this is the NSX-ALB/cloud-provider address; on KinD
# it is cloud-provider-kind's. A gateway the platform team exposed as ClusterIP or
# NodePort has NO external IP — that is a legitimate topology, so say so plainly
# instead of timing out with a mystery.
# ---------------------------------------------------------------------------
istio_wait_lb_ip() {
  local timeout="${READY_TIMEOUT_SECONDS:-300}" interval="${POLL_INTERVAL_SECONDS:-5}" elapsed=0 svc_type ip
  svc_type="$(kubectl -n "$ISTIO_GATEWAY_NAMESPACE" get svc "$ISTIO_GATEWAY_SERVICE" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  if [ "$svc_type" != "LoadBalancer" ]; then
    log_error "gateway Service ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE} is type '${svc_type}', not LoadBalancer —"
    log_error "  it has no external address, so the *.vks.local UIs cannot be reached from the jump box."
    log_error "  Ask the mesh admin to expose it as a LoadBalancer, or set INGRESS_LB_IP yourself"
    log_error "  (e.g. to a NodePort address or an upstream LB that fronts it)."
    return 1
  fi
  log_info "waiting for the ingress-gateway LoadBalancer address (timeout ${timeout}s)"
  while :; do
    ip="$(kubectl -n "$ISTIO_GATEWAY_NAMESPACE" get svc "$ISTIO_GATEWAY_SERVICE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -z "$ip" ] && ip="$(kubectl -n "$ISTIO_GATEWAY_NAMESPACE" get svc "$ISTIO_GATEWAY_SERVICE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
    elapsed=$(( elapsed + interval ))
    [ "$elapsed" -ge "$timeout" ] && { log_error "no LoadBalancer address on ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE} within ${timeout}s"; return 1; }
    sleep "$interval"
  done
}

# ---------------------------------------------------------------------------
# istio_apply_routes — apply the Gateway (unless reusing a shared one) + the
# VirtualServices.
#
# The VirtualServices are applied into their BACKEND's namespace (not the gateway
# namespace) with a namespace-qualified gateway ref. That one layout works in BOTH
# modes and is the only layout a locked-down tenant can actually use: a VS-only
# tenant has no rights in the gateway namespace at all. (KinD-proven: a VS in the
# app namespace referencing <gw-ns>/<gw-name> routes correctly, including against a
# platform-owned wildcard Gateway.)
# ---------------------------------------------------------------------------
istio_apply_routes() {
  require_cmd envsubst "install gettext (provides envsubst)"
  local k8s_dir="${REPO_ROOT}/k8s/istio"

  ISTIO_GATEWAY_NAME="${ISTIO_GATEWAY_NAME:-vks-uis}"
  ISTIO_GATEWAY_REF="$(istio_gateway_ref)"
  export ISTIO_GATEWAY_NAME ISTIO_GATEWAY_REF

  # Backend namespaces must exist before a VirtualService can be created in them.
  local ns
  for ns in "$GITEA_NAMESPACE" "$ARGOCD_DEST_NAMESPACE" "$TEKTON_NAMESPACE"; do
    run bash -c "kubectl create namespace \"$ns\" --dry-run=client -o yaml | kubectl apply -f -"
  done

  if [ -n "${ISTIO_SHARED_GATEWAY:-}" ]; then
    log_info "reusing the platform-owned Gateway ${ISTIO_SHARED_GATEWAY} (creating NO Gateway of our own)"
    istio_assert_shared_gateway_hosts || return 1
  else
    log_info "applying Gateway ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_NAME} (selector istio=${ISTIO_GATEWAY_LABEL})"
    # shellcheck disable=SC2016
    envsubst '${ISTIO_GATEWAY_NAMESPACE} ${ISTIO_GATEWAY_NAME} ${ISTIO_GATEWAY_LABEL} ${GITEA_HOST} ${WEBUI_HOST} ${TEKTON_DASHBOARD_HOST}' \
      < "${k8s_dir}/gateway.yaml" | run kubectl apply -f -
  fi

  log_info "applying VirtualServices (gitea/webui/tekton -> ${ISTIO_GATEWAY_REF})"
  # shellcheck disable=SC2016
  envsubst '${ISTIO_GATEWAY_REF} ${GITEA_HOST} ${GITEA_NAMESPACE} ${WEBUI_HOST} ${APP_NAME} ${ARGOCD_DEST_NAMESPACE} ${TEKTON_DASHBOARD_HOST} ${TEKTON_NAMESPACE}' \
    < "${k8s_dir}/virtualservices.yaml" | run kubectl apply -f -
}

# ---------------------------------------------------------------------------
# istio_report — human-readable discovery summary (used by `make istio-preflight`).
# ---------------------------------------------------------------------------
istio_report() {
  cat >&2 <<EOF

  Istio (discovered from the LIVE cluster — not from docs)
  -------------------------------------------------------
  control plane ns   : ${ISTIOD_NAMESPACE:-<not found>}
  istiod image       : ${ISTIO_DISCOVERED_VERSION:-<unknown>}
  route API          : ${ISTIO_GATEWAY_API:-<unknown>}
  ingress gateway    : ${ISTIO_GATEWAY_NAMESPACE:-?}/${ISTIO_GATEWAY_SERVICE:-?}
  Gateway selector   : istio=${ISTIO_GATEWAY_LABEL:-?}   <- a Gateway MUST use exactly this
  gateway ref for VS : $( [ -n "${ISTIO_GATEWAY_NAMESPACE:-}" ] && istio_gateway_ref || echo '?' )

  Istio has NO login, token or admin credential: access to the mesh is kubectl RBAC.
  The only credential-shaped object is a TLS Secret named by Gateway.tls.credentialName,
  which must live in the gateway's namespace — request it from the mesh admin.

EOF
}
