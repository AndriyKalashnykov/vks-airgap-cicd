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

# The routes are per-app: one VirtualService/HTTPRoute per app, and every app's host must be on the
# Gateway. All of that comes from apps/registry.tsv — nothing here names an app.
# shellcheck source=scripts/lib/apps.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/apps.sh"

# PSA levels for the namespaces we create (VKS enforces `restricted` by default from VKr 1.26).
# shellcheck source=scripts/lib/psa.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/psa.sh"

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

  export ISTIOD_NAMESPACE ISTIO_DISCOVERED_VERSION \
         ISTIO_GATEWAY_NAMESPACE ISTIO_GATEWAY_SERVICE ISTIO_GATEWAY_LABEL
  return 0
}

# ---------------------------------------------------------------------------
# istio_ensure_gwapi_crds — install the Kubernetes Gateway API CRDs if they are absent.
#
# WHY THIS EXISTS. Nothing in this repo used to install them, and Istio does not ship them
# either ("The Gateway APIs do not come installed by default on most Kubernetes clusters" —
# istio.io). On KinD they appeared anyway, because **cloud-provider-kind force-installs its
# own bundle at startup**. So `make e2e-kind-istio-existing`'s gateway-api leg was green
# because of a KinD-only shim, and the tenant path we ADVERTISE as verified could simply not
# exist on a real VKS cluster — where the shared gateway is ALSO off by default, leaving the
# classic fallback with nothing to bind to. The e2e proved nothing about the lab.
#
# --server-side is REQUIRED, not a preference: the CRD bundle exceeds the 256 KiB
# last-applied-configuration annotation limit that client-side apply writes.
#
# We only do this when we OWN the cluster (the install path). A tenant attaching to someone else's
# mesh cannot install cluster-scoped CRDs — istio_detect_route_api (below) tells them so in those
# words instead of silently degrading to a path that cannot work.
#
# (That sentence used to name `istio_require_gwapi_crds`, a function THAT DOES NOT EXIST — a comment
# asserting a control that was never written. Same class as the phantom noun #208 removed from the
# docs, one level down: in the code, where it is even easier to believe.)
istio_ensure_gwapi_crds() {
  local ver="${GATEWAY_API_VERSION:?GATEWAY_API_VERSION must be set (.env.example)}"
  if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
    log_info "Gateway API CRDs already present"
    return 0
  fi
  # MANIFEST_DIR is a LOCAL in 10-mirror-pull.sh and 41-install-tekton.sh — it is NOT an .env var and
  # nothing sets it on this path. So `${MANIFEST_DIR:-}` was EMPTY here, `[ -f "/gateway-api-X.yaml" ]`
  # was always false, and the "air-gap" branch was DEAD CODE: `make install-ingress` reached for
  # github.com every single time, on an air-gapped jump box included — where it dies BEFORE the helm
  # fetch the runbook warns about, so the operator hits a failure the docs never mention. Meanwhile
  # 10-mirror-pull.sh has been faithfully downloading this exact file into the bundle, and nothing
  # ever read it. Derive the dir the same way lib/mirror.sh already does.
  local mdir="${MANIFEST_DIR:-${BUNDLE_DIR:-}/manifests}"
  local src="${mdir}/gateway-api-${ver}.yaml"
  if [ -f "$src" ]; then
    log_info "installing Gateway API CRDs ${ver} from the carried bundle (air-gap): $src"
  elif [ -d "$mdir" ]; then
    # The bundle EXISTS but does not carry the CRDs — that means an air-gapped box with a bundle cut
    # before this file was added. Reaching for the internet here is the wrong default: it will hang or
    # fail with a network error that says nothing useful. Say what is actually wrong.
    die "the bundle at '$mdir' has no gateway-api-${ver}.yaml.
  Your bundle predates the Gateway API CRDs (or was cut for a different GATEWAY_API_VERSION).
  Re-cut it on the internet side:  make mirror-pull && make bundle
  (Refusing to silently fetch from github.com: on an air-gapped box that cannot work, and on a
   dual-homed box it would hide the fact that your bundle is incomplete.)"
  else
    src="https://github.com/kubernetes-sigs/gateway-api/releases/download/${ver}/standard-install.yaml"
    log_info "installing Gateway API CRDs ${ver} from upstream (needs internet; no bundle at $mdir)"
  fi
  # --server-side is REQUIRED, not a preference (the bundle is ~17.5k lines — far over the 256 KiB
  # last-applied-configuration annotation limit that CLIENT-side apply writes).
  # --force-conflicts: idempotent re-runs, and it takes ownership from any bundle a component
  # (e.g. cloud-provider-kind) force-installed first.
  run kubectl apply --server-side --force-conflicts -f "$src"
  kubectl wait --for=condition=Established --timeout=60s \
    crd/httproutes.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io >/dev/null

  # POST-CONDITION: prove WE installed them — "the CRDs are present" is NOT the claim, and it was
  # already TRUE before this code ever ran (cloud-provider-kind put them there). That is exactly how
  # #209 shipped "verified" without ever executing. The forgery-proof signature is the FIELD MANAGER:
  # CPK creates CRDs with a plain dynamic Create() -> managedFields operation `Update`. A server-side
  # apply produces operation `Apply`. So an `Apply` manager proves both that our code path ran AND
  # that --server-side was genuinely used. The bundle-version annotation proves it is OUR pinned
  # version and not somebody else's.
  local got_ver got_apply
  got_ver="$(kubectl get crd httproutes.gateway.networking.k8s.io \
               -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || true)"
  got_apply="$(kubectl get crd httproutes.gateway.networking.k8s.io \
                 -o jsonpath='{range .metadata.managedFields[?(@.operation=="Apply")]}{.manager}{"\n"}{end}' 2>/dev/null || true)"
  [ "$got_ver" = "$ver" ] || die "Gateway API CRDs report bundle-version '${got_ver:-<none>}', expected '${ver}' — something else owns these CRDs"
  [ -n "$got_apply" ]     || die "Gateway API CRDs have NO server-side-apply field manager — they were created by something else (cloud-provider-kind?), not by us. 'Present' is not 'installed by us'."
  log_info "Gateway API CRDs ${ver} established (bundle-version=${got_ver}, SSA field manager: $(printf '%s' "$got_apply" | tr '\n' ' '))"
}

# istio_gwapi_crds_present — cheap, honest boolean.
istio_gwapi_crds_present() {
  kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1
}

# istio_detect_route_api — decide HOW to attach routes, and prefer the Gateway API.
#
# Broadcom's own VKS walkthrough routes with the Kubernetes Gateway API
# (`gatewayClassName: istio`), and the VKS Istio Standard Package ships its shared
# ingress gateway DISABLED by default — so on a real lab there is frequently NO
# shared gateway to attach to, and the classic path has nothing to bind. The Gateway
# API path also needs strictly LESS from the platform team:
#
#   classic     : needs a shared gateway to exist + its selector label + (usually) rights
#                 in the gateway namespace, or a platform-owned Gateway to reference.
#   gateway-api : needs NOTHING outside our own namespaces. We create a Gateway with
#                 gatewayClassName=istio and Istio AUTO-PROVISIONS the data plane and a
#                 LoadBalancer for us — and the provisioned proxy inherits istiod's image
#                 hub, so on an air-gapped cluster it pulls from Harbor with no extra config
#                 (verified: the auto-created pod ran <harbor>/cicd/istio/proxyv2).
#
# Sets ISTIO_ROUTE_API to: gateway-api | classic | none
# Honours an explicit ISTIO_ROUTE_API=gateway-api|classic to override the preference.
# ---------------------------------------------------------------------------
istio_detect_route_api() {
  local have_classic=0 have_gwapi=0 gwclass_ok=""

  kubectl get crd virtualservices.networking.istio.io >/dev/null 2>&1 && have_classic=1
  if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
    # The CRDs alone are not enough — Istio must actually be the controller for a
    # GatewayClass, otherwise our Gateway would be accepted and never programmed.
    gwclass_ok="$(kubectl get gatewayclass "${ISTIO_GATEWAY_CLASS:-istio}" \
      -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    [ "$gwclass_ok" = "True" ] && have_gwapi=1
  fi

  case "${ISTIO_ROUTE_API:-auto}" in
    gateway-api)
      [ "$have_gwapi" -eq 1 ] || die "ISTIO_ROUTE_API=gateway-api, but GatewayClass '${ISTIO_GATEWAY_CLASS:-istio}' is not Accepted on this cluster (Gateway API CRDs present: $([ "$have_gwapi" -eq 1 ] || kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1 && echo yes || echo no))"
      ISTIO_ROUTE_API=gateway-api ;;
    classic)
      [ "$have_classic" -eq 1 ] || die "ISTIO_ROUTE_API=classic, but the VirtualService CRD is absent"
      ISTIO_ROUTE_API=classic ;;
    auto|"")
      if   [ "$have_gwapi" -eq 1 ];   then ISTIO_ROUTE_API=gateway-api
      elif [ "$have_classic" -eq 1 ]; then
        # Do NOT degrade silently. If the CRDs are simply ABSENT, say so — that is a
        # different (and fixable) problem from "the CRDs are here but Istio is not the
        # GatewayClass controller", and on a real lab it is the likely one, because
        # nothing installs them and the VKS shared gateway is off by default.
        if ! istio_gwapi_crds_present; then
          log_warn "Gateway API CRDs are ABSENT — falling back to the CLASSIC route API."
          log_warn "  The classic path needs a SHARED INGRESS GATEWAY, which the VKS Istio package"
          log_warn "  ships DISABLED by default — so this may have nothing to bind to."
          log_warn "  If you OWN this cluster:  make install-ingress  (installs the CRDs for you)"
          log_warn "  If you are a TENANT:      ask the mesh admin to install the Gateway API CRDs,"
          log_warn "                            or to enable the shared ingress gateway."
        fi
        ISTIO_ROUTE_API=classic
      else                                 ISTIO_ROUTE_API=none
      fi ;;
    *) die "ISTIO_ROUTE_API must be auto|gateway-api|classic (got '${ISTIO_ROUTE_API}')" ;;
  esac
  export ISTIO_ROUTE_API
  log_info "route API: ${ISTIO_ROUTE_API} (GatewayClass '${ISTIO_GATEWAY_CLASS:-istio}' accepted=${gwclass_ok:-no}, VirtualService CRD=$([ "$have_classic" -eq 1 ] && echo yes || echo no))"
}

# ---------------------------------------------------------------------------
# istio_apply_routes_gwapi — the Gateway-API attach: ONE Gateway (which Istio turns
# into a data plane + LoadBalancer for us) + one HTTPRoute per UI, each in ITS BACKEND'S
# namespace. Cross-namespace HTTPRoute->Gateway attachment is allowed by the listener's
# allowedRoutes (no ReferenceGrant needed: that is only for cross-namespace backendRefs,
# and every backendRef here is same-namespace as its route).
# ---------------------------------------------------------------------------
istio_apply_routes_gwapi() {
  require_cmd envsubst "install gettext (provides envsubst)"
  local k8s_dir="${REPO_ROOT}/k8s/istio" ns

  ISTIO_GATEWAY_NAME="${ISTIO_GATEWAY_NAME:-vks-uis}"
  ISTIO_GWAPI_NAMESPACE="${ISTIO_GWAPI_NAMESPACE:-vks-ingress}"
  ISTIO_GATEWAY_CLASS="${ISTIO_GATEWAY_CLASS:-istio}"
  export ISTIO_GATEWAY_NAME ISTIO_GWAPI_NAMESPACE ISTIO_GATEWAY_CLASS

  # The gateway namespace needs `baseline`: the proxy Istio AUTO-PROVISIONS here sets no
  # seccompProfile, so VKS's default `restricted` would REJECT it — and that pod is created by the
  # platform's istiod, not by us, so we cannot make it compliant. (Measured with `make psa-check`.)
  ensure_namespace "$ISTIO_GWAPI_NAMESPACE" "${PSA_LEVEL_INGRESS:-baseline}"
  ensure_namespace "$GITEA_NAMESPACE"       "${PSA_LEVEL_GITEA:-restricted}"
  ensure_namespace "$TEKTON_NAMESPACE"      "${PSA_LEVEL_TEKTON:-restricted}"
  # One namespace per app, from apps/registry.tsv.
  local a
  while read -r a; do
    [ -n "$a" ] || continue
    ensure_namespace "$a" "${PSA_LEVEL_APP:-restricted}"
  done <<EOF
$(app_names)
EOF

  # The listener's allowedRoutes must name EVERY app namespace, else that app's HTTPRoute attaches
  # to nothing and its host 404s — with no error at apply time. APPENDED with yq from the registry
  # (not a text block), so the manifest on disk stays valid YAML that yamllint/kubeconform can check.
  local ns_json; ns_json="$(app_namespaces_json)"
  log_info "applying Gateway(API) ${ISTIO_GWAPI_NAMESPACE}/${ISTIO_GATEWAY_NAME} (gatewayClassName=${ISTIO_GATEWAY_CLASS}) + shared-UI HTTPRoutes; app namespaces ${ns_json}"
  # shellcheck disable=SC2016
  envsubst '${ISTIO_GWAPI_NAMESPACE} ${ISTIO_GATEWAY_NAME} ${ISTIO_GATEWAY_CLASS} ${GITEA_HOST} ${GITEA_NAMESPACE} ${TEKTON_DASHBOARD_HOST} ${TEKTON_NAMESPACE}' \
    < "${k8s_dir}/gateway-api.yaml" \
    | NSS="$ns_json" yq '(select(.kind == "Gateway") | .spec.listeners[0].allowedRoutes.namespaces.selector.matchExpressions[0].values) += (strenv(NSS) | fromjson)' \
    | run kubectl apply -f -

  # ONE HTTPRoute per app, from the registry — adding an app routes it with no YAML edit.
  # shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
  _istio_apply_app_httproute() {
    istio_require_env ISTIO_GATEWAY_NAME ISTIO_GWAPI_NAMESPACE APP_NAME APP_NAMESPACE APP_HOST
    log_info "applying HTTPRoute for app '${APP_NAME}' (${APP_HOST} -> ${APP_NAME}.${APP_NAMESPACE})"
    # shellcheck disable=SC2016
    envsubst '${ISTIO_GATEWAY_NAME} ${ISTIO_GWAPI_NAMESPACE} ${APP_NAME} ${APP_NAMESPACE} ${APP_HOST}' \
      < "${k8s_dir}/httproute-app.yaml" | run kubectl apply -f -
  }
  for_each_app _istio_apply_app_httproute
}

# app_hosts_json / app_namespaces_json — the registry as a JSON array, for yq to append into a
# rendered manifest. JSON (not a YAML text block) keeps the manifests on disk valid.
app_hosts_json() {
  local a first=1 out="["
  while read -r a; do
    [ -n "$a" ] || continue
    [ "$first" -eq 1 ] || out="${out},"
    out="${out}\"$(app_host "$a")\""; first=0
  done <<EOF
$(app_names)
EOF
  printf '%s]' "$out"
}

app_namespaces_json() {
  local a first=1 out="["
  while read -r a; do
    [ -n "$a" ] || continue
    [ "$first" -eq 1 ] || out="${out},"
    out="${out}\"${a}\""; first=0
  done <<EOF
$(app_names)
EOF
  printf '%s]' "$out"
}

# Space-separated variants, for the shell loops that iterate hosts/namespaces.
app_hosts_flat() {
  local a
  while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done <<EOF
$(app_names)
EOF
}

app_namespaces_flat() { app_names | tr '\n' ' '; }

# ---------------------------------------------------------------------------
# istio_wait_gwapi_address — wait for Istio to PROGRAM the Gateway and publish its address.
# `Programmed=True` is the real readiness signal; the address is what /etc/hosts must point at.
# ---------------------------------------------------------------------------
istio_wait_gwapi_address() {
  local timeout="${READY_TIMEOUT_SECONDS:-300}" interval="${POLL_INTERVAL_SECONDS:-5}" elapsed=0 prog addr
  log_info "waiting for Istio to program Gateway ${ISTIO_GWAPI_NAMESPACE}/${ISTIO_GATEWAY_NAME} (timeout ${timeout}s)"
  while :; do
    prog="$(kubectl -n "$ISTIO_GWAPI_NAMESPACE" get gateway "$ISTIO_GATEWAY_NAME" \
      -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
    addr="$(kubectl -n "$ISTIO_GWAPI_NAMESPACE" get gateway "$ISTIO_GATEWAY_NAME" \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
    [ "$prog" = "True" ] && [ -n "$addr" ] && { printf '%s' "$addr"; return 0; }
    elapsed=$(( elapsed + interval ))
    if [ "$elapsed" -ge "$timeout" ]; then
      log_error "Gateway not programmed within ${timeout}s (Programmed=${prog:-<none>}, address=${addr:-<none>})"
      log_error "  kubectl -n ${ISTIO_GWAPI_NAMESPACE} describe gateway ${ISTIO_GATEWAY_NAME}"
      log_error "  Istio provisions the data plane itself — check what it created:"
      kubectl -n "$ISTIO_GWAPI_NAMESPACE" get deploy,svc,pods -l "gateway.networking.k8s.io/gateway-name=${ISTIO_GATEWAY_NAME}" 2>&1 | sed 's/^/      /' >&2 || true
      if [ "$prog" = "True" ] || kubectl -n "$ISTIO_GWAPI_NAMESPACE" get svc "${ISTIO_GATEWAY_NAME}-istio" >/dev/null 2>&1; then
        # The proxy exists but has no address -> it is the LoadBalancer, not Istio, that is stuck.
        istio_diagnose_pending_lb "$ISTIO_GWAPI_NAMESPACE" "${ISTIO_GATEWAY_NAME}-istio"
      else
        log_error "  No proxy was provisioned at all — Istio did not accept the Gateway. Most likely causes:"
        log_error "    * Pod Security Admission rejected the proxy pod. VKS guest clusters enforce 'restricted'"
        log_error "      by DEFAULT (VKS v1.26+), so the namespace may need an explicit PSA label."
        log_error "      Check:  kubectl -n ${ISTIO_GWAPI_NAMESPACE} get events --sort-by=.lastTimestamp | tail"
        log_error "    * the GatewayClass '${ISTIO_GATEWAY_CLASS:-istio}' is not actually served by this mesh."
        kubectl -n "$ISTIO_GWAPI_NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -5 | sed 's/^/      /' >&2 || true
      fi
      return 1
    fi
    sleep "$interval"
  done
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
    log_error "  Ask the mesh admin to confirm it exists and admits: ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST} $(app_hosts_flat)"
    return 1
  fi
  # EVERY host we route must be admitted — including each app's. On a real lab the shared Gateway's
  # `hosts:` list belongs to the MESH ADMIN, so a SECOND app may need a REQUEST to have its host
  # added. This is where a tenant finds that out, instead of getting a silent 404.
  for host in "$GITEA_HOST" "$TEKTON_DASHBOARD_HOST" $(app_hosts_flat); do
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
    if [ "$elapsed" -ge "$timeout" ]; then
      log_error "no LoadBalancer address on ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE} within ${timeout}s"
      istio_diagnose_pending_lb "$ISTIO_GATEWAY_NAMESPACE" "$ISTIO_GATEWAY_SERVICE"
      return 1
    fi
    sleep "$interval"
  done
}

# ---------------------------------------------------------------------------
# istio_diagnose_pending_lb — a LoadBalancer Service stuck on EXTERNAL-IP <pending> is the
# single most common "it works on KinD, not on the lab" failure, and a bare timeout tells the
# operator nothing. On a VKS guest cluster the address is handed out by whichever load balancer
# the platform configured — the NSX LB, the Foundation Load Balancer (FLB, the VDS default), or
# NSX ALB/Avi — and it stays <pending> forever when none is configured for that cluster, or when
# its IP pool is exhausted. Say so, and print the events that carry the real reason.
# ---------------------------------------------------------------------------
istio_diagnose_pending_lb() { # <ns> <svc>
  local ns="$1" svc="$2"
  log_error "  EXTERNAL-IP is <pending>: nothing has assigned an address to this Service."
  log_error "  On a VKS guest cluster the address comes from the load balancer the platform configured:"
  log_error "    NSX LB / Foundation Load Balancer (FLB — the VDS default) / NSX ALB (Avi)."
  log_error "  It stays <pending> when no LB provider is configured for the cluster, or its IP pool is exhausted."
  log_error "  Ask the platform team which LB backs this cluster and whether the pool has free VIPs. Then:"
  log_error "    - if a LoadBalancer genuinely is not available, expose the gateway another way and set"
  log_error "      INGRESS_LB_IP_OVERRIDE=<the address that reaches it> in .env."
  log_error "  Service + events (the real reason is usually here):"
  kubectl -n "$ns" get svc "$svc" -o wide 2>&1 | sed 's/^/      /' >&2 || true
  kubectl -n "$ns" describe svc "$svc" 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/      /' >&2 || true
  kubectl -n "$ns" get events --field-selector "involvedObject.name=${svc}" \
    --sort-by=.lastTimestamp 2>/dev/null | tail -5 | sed 's/^/      /' >&2 || true
}


# ---------------------------------------------------------------------------
# istio_require_env — every variable we are about to envsubst MUST be non-empty AND exported.
#
# envsubst substitutes from the ENVIRONMENT, not from shell variables. A caller that sets
# `FOO=bar` without `export` renders `${FOO}` as the EMPTY STRING — silently. In a k8s manifest
# that is not a harmless blank: `namespace: ` makes kubectl fall back to `default`, so the object
# is created in the WRONG NAMESPACE and everything that references it by its intended namespace
# then fails to match. The symptom is a 404 from a listener that exists — never an error at apply
# time. (This shipped exactly once: the Gateway landed in `default` while the VirtualServices
# referenced `istio-ingress/vks-uis`.)
# ---------------------------------------------------------------------------
istio_require_env() {
  local v missing=""
  for v in "$@"; do
    # Non-empty in the shell AND visible in the environment (i.e. exported).
    #
    # `printenv "$v"`, NOT `env | grep -q "^$v="`. The pipe was a FALSE-NEGATIVE GENERATOR: `grep -q`
    # exits on the FIRST match, which SIGPIPEs `env` (exit 141), and under this script's
    # `set -o pipefail` the pipeline's status becomes that 141 — so the check reported NOT EXPORTED
    # for a variable that WAS exported. It only fires once the environment is big enough that `env`
    # is still writing when grep quits, which is exactly the case under `make` (the e2e), and never
    # in a small standalone shell. Measured: 20/20 false negatives with a large environment, 0/20
    # with a small one — a latent landmine that took down `make e2e-kind` at install-ingress.
    #
    # printenv reads the environment directly: no pipe, no SIGPIPE, and its exit status IS the
    # question we are asking ("is this name in the environment?").
    [ -n "${!v:-}" ] || { missing="${missing} ${v}(unset)"; continue; }
    printenv "$v" >/dev/null 2>&1 || missing="${missing} ${v}(NOT EXPORTED)"
  done
  [ -z "$missing" ] || die "cannot render manifests —${missing}. envsubst reads the ENVIRONMENT: a non-exported variable renders EMPTY and would silently create the object in the WRONG namespace."
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
  ensure_namespace "$GITEA_NAMESPACE"  "${PSA_LEVEL_GITEA:-restricted}"
  ensure_namespace "$TEKTON_NAMESPACE" "${PSA_LEVEL_TEKTON:-restricted}"
  # One namespace per app, from apps/registry.tsv.
  local a
  while read -r a; do
    [ -n "$a" ] || continue
    ensure_namespace "$a" "${PSA_LEVEL_APP:-restricted}"
  done <<EOF
$(app_names)
EOF

  if [ -n "${ISTIO_SHARED_GATEWAY:-}" ]; then
    log_info "reusing the platform-owned Gateway ${ISTIO_SHARED_GATEWAY} (creating NO Gateway of our own)"
    istio_assert_shared_gateway_hosts || return 1
  else
    # Export before envsubst — a caller may have set these as plain shell vars (46-install-istio.sh
    # pins them; istio_discover exports them). See istio_require_env for why an unexported var is
    # not a cosmetic problem.
    export ISTIO_GATEWAY_NAMESPACE ISTIO_GATEWAY_LABEL
    istio_require_env ISTIO_GATEWAY_NAMESPACE ISTIO_GATEWAY_NAME ISTIO_GATEWAY_LABEL \
                      GITEA_HOST TEKTON_DASHBOARD_HOST
    # One host per app is APPENDED from the registry with yq — never hardcoded in the manifest.
    local hosts_json; hosts_json="$(app_hosts_json)"
    log_info "applying Gateway ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_NAME} (selector istio=${ISTIO_GATEWAY_LABEL}) + app hosts ${hosts_json}"
    # shellcheck disable=SC2016
    envsubst '${ISTIO_GATEWAY_NAMESPACE} ${ISTIO_GATEWAY_NAME} ${ISTIO_GATEWAY_LABEL} ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST}' \
      < "${k8s_dir}/gateway.yaml" \
      | HOSTS="$hosts_json" yq '.spec.servers[0].hosts += (strenv(HOSTS) | fromjson)' \
      | run kubectl apply -f -
  fi

  # The shared UIs (gitea, tekton dashboard).
  istio_require_env ISTIO_GATEWAY_REF GITEA_HOST GITEA_NAMESPACE TEKTON_DASHBOARD_HOST TEKTON_NAMESPACE
  log_info "applying VirtualServices for the shared UIs -> ${ISTIO_GATEWAY_REF}"
  # shellcheck disable=SC2016
  envsubst '${ISTIO_GATEWAY_REF} ${GITEA_HOST} ${GITEA_NAMESPACE} ${TEKTON_DASHBOARD_HOST} ${TEKTON_NAMESPACE}' \
    < "${k8s_dir}/virtualservices.yaml" | run kubectl apply -f -

  # ONE VirtualService per app, from the registry — adding an app routes it with no YAML edit.
  # shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
  _istio_apply_app_vs() {
    istio_require_env ISTIO_GATEWAY_REF APP_NAME APP_NAMESPACE APP_HOST
    log_info "applying VirtualService for app '${APP_NAME}' (${APP_HOST} -> ${APP_NAME}.${APP_NAMESPACE})"
    # shellcheck disable=SC2016
    envsubst '${ISTIO_GATEWAY_REF} ${APP_NAME} ${APP_NAMESPACE} ${APP_HOST}' \
      < "${k8s_dir}/virtualservice-app.yaml" | run kubectl apply -f -
  }
  for_each_app _istio_apply_app_vs
}

# ---------------------------------------------------------------------------
# istio_drop_other_api_routes — when attaching with one route API, remove the routes WE
# created with the OTHER one.
#
# Without this, switching APIs leaves the previous route objects live in the cluster, and they
# keep serving the same hostnames. That is not just untidy — it silently FAKES a successful
# switch: the new path can be broken while the verification passes through the old routes.
# (Observed exactly that: a Gateway-API attach "succeeded" while traffic still flowed through
# the leftover classic Gateway/VirtualServices.)
#
# Only objects WE own are removed — by the names this repo creates. The platform's own Gateway
# (ISTIO_SHARED_GATEWAY) and anything else in the mesh is never touched.
# ---------------------------------------------------------------------------
istio_drop_other_api_routes() { # <keep: gateway-api|classic>
  local keep="$1" ns
  case "$keep" in
    gateway-api)
      log_info "removing any CLASSIC routes we previously created (so they cannot serve stale traffic)"
      for ns in "$GITEA_NAMESPACE" "$TEKTON_NAMESPACE" $(app_namespaces_flat); do
        # shellcheck disable=SC2046  # word-splitting is intended: one name per app
        kubectl -n "$ns" delete virtualservice gitea tekton-dashboard $(app_names | tr '\n' ' ') --ignore-not-found >/dev/null 2>&1 || true
      done
      [ -n "${ISTIO_GATEWAY_NAMESPACE:-}" ] && \
        kubectl -n "$ISTIO_GATEWAY_NAMESPACE" delete gateway.networking.istio.io "${ISTIO_GATEWAY_NAME:-vks-uis}" --ignore-not-found >/dev/null 2>&1 || true
      ;;
    classic)
      log_info "removing any GATEWAY-API routes we previously created (so they cannot serve stale traffic)"
      for ns in "$GITEA_NAMESPACE" "$TEKTON_NAMESPACE" $(app_namespaces_flat); do
        # shellcheck disable=SC2046  # word-splitting is intended: one name per app
        kubectl -n "$ns" delete httproute gitea tekton-dashboard $(app_names | tr '\n' ' ') --ignore-not-found >/dev/null 2>&1 || true
      done
      kubectl -n "${ISTIO_GWAPI_NAMESPACE:-vks-ingress}" delete gateway.gateway.networking.k8s.io "${ISTIO_GATEWAY_NAME:-vks-uis}" --ignore-not-found >/dev/null 2>&1 || true
      ;;
  esac
  return 0
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
  route API in use   : ${ISTIO_ROUTE_API:-<not detected>}
  ingress gateway    : ${ISTIO_GATEWAY_NAMESPACE:-?}/${ISTIO_GATEWAY_SERVICE:-?}
  Gateway selector   : istio=${ISTIO_GATEWAY_LABEL:-?}   <- a CLASSIC Gateway MUST use exactly this
  gateway ref for VS : $( [ -n "${ISTIO_GATEWAY_NAMESPACE:-}" ] && istio_gateway_ref || echo '?' )

  Istio has NO login, token or admin credential: access to the mesh is kubectl RBAC.
  The only credential-shaped object is a TLS Secret named by Gateway.tls.credentialName,
  which must live in the gateway's namespace — request it from the mesh admin.

EOF
}
