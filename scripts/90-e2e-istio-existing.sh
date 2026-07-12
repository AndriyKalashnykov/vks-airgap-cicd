#!/usr/bin/env bash
# 90-e2e-istio-existing.sh — TEST FIXTURE for the istio-existing (attach) mode.
#
# NOT part of any install flow. It plays "the platform team": it installs Istio into the
# running KinD cluster using naming this repo does NOT control, so that the attach path is
# exercised honestly. Installing Istio the way WE do it and then "attaching" to it would
# prove nothing — our own install forces `labels.istio=ingressgateway`, which is exactly
# the assumption under test.
#
# Foreign-on-purpose naming (mirrors what a real platform team's install looks like):
#   namespace    : platform-ingress            (we assume istio-ingress)
#   helm release : platform-gw                 (we assume istio-ingressgateway)
#   istio label  : platform-gw  (chart-derived from the release name — NOT ingressgateway)
#
# It also demonstrates the REDs, because a gate is only worth its proven failure:
#   RED 1 — attaching when NO mesh exists must FAIL loudly, never silently no-op.
#   RED 2 — attaching with the OLD hardcoded selector (istio: ingressgateway) must produce
#           a dead route (Envoy gets no listener -> connection refused), proving the
#           discovery is what makes the attach work.
#
# Images come from Harbor (same mirror as the normal install) so this stays air-gap-honest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/istio.sh
. "${SCRIPT_DIR}/lib/istio.sh"
load_env

require_cmd kubectl
require_cmd helm
require_cmd jq
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${ISTIO_VERSION:?}"
: "${WEBUI_HOST:?}"; : "${APP_NAME:?}"; : "${ARGOCD_DEST_NAMESPACE:?}"

PLATFORM_NS="${PLATFORM_ISTIO_NAMESPACE:-platform-ingress}"
PLATFORM_RELEASE="${PLATFORM_ISTIO_RELEASE:-platform-gw}"
PLATFORM_ISTIOD_NS="${PLATFORM_ISTIOD_NAMESPACE:-istio-system}"
HUB="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/istio"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

# ---------------------------------------------------------------------------
# RED 1 — no mesh yet: the attach path MUST fail, not quietly succeed.
# ---------------------------------------------------------------------------
if kubectl get deploy -A -l app=istiod -o name 2>/dev/null | grep -q .; then
  log_warn "an Istio control plane is ALREADY present — skipping RED 1 (it only means something on a mesh-free cluster)"
else
  log_info "RED 1: 'attach' with no Istio installed must FAIL"
  if "${SCRIPT_DIR}/47-attach-istio.sh" >/dev/null 2>&1; then
    die "RED 1 FAILED: 47-attach-istio.sh exited 0 on a cluster with NO Istio — it must refuse, not no-op"
  fi
  log_info "RED 1 OK — attach refused to run against a mesh-free cluster"
fi

# ---------------------------------------------------------------------------
# Play the platform team: install Istio with naming we do not control.
# ---------------------------------------------------------------------------
log_info "PLATFORM: installing Istio ${ISTIO_VERSION} as a foreign mesh (ns=${PLATFORM_NS}, release=${PLATFORM_RELEASE}, hub=${HUB})"
run helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
run helm repo update istio
run helm upgrade --install istio-base istio/base \
  --namespace "$PLATFORM_ISTIOD_NS" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s"
run helm upgrade --install istiod istio/istiod \
  --namespace "$PLATFORM_ISTIOD_NS" \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set global.hub="$HUB" --set global.tag="$ISTIO_VERSION" \
  --set global.proxy.autoInject=disabled --set pilot.autoscaleEnabled=false
# NOTE: deliberately NO `--set labels.istio=...` — the chart derives the label from the
# release name, which is precisely the condition our old hardcoded selector could not handle.
run helm upgrade --install "$PLATFORM_RELEASE" istio/gateway \
  --namespace "$PLATFORM_NS" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set service.type=LoadBalancer \
  --set global.hub="$HUB" --set global.tag="$ISTIO_VERSION"

# ---------------------------------------------------------------------------
# Assert the foreign mesh really is foreign, and that discovery reads it correctly.
# ---------------------------------------------------------------------------
ACTUAL_LABEL="$(kubectl -n "$PLATFORM_NS" get svc "$PLATFORM_RELEASE" -o jsonpath='{.spec.selector.istio}')"
log_info "PLATFORM: gateway selector is istio=${ACTUAL_LABEL}"
[ "$ACTUAL_LABEL" != "ingressgateway" ] || \
  die "fixture is not foreign: the gateway ended up labelled 'ingressgateway', so it cannot test discovery"

# Discovery must find THIS gateway (and not istiod).
unset ISTIO_GATEWAY_NAMESPACE ISTIO_GATEWAY_SERVICE ISTIO_GATEWAY_LABEL
istio_discover || die "istio_discover failed against the platform mesh"
[ "$ISTIO_GATEWAY_NAMESPACE" = "$PLATFORM_NS" ] || die "discovery found ns=${ISTIO_GATEWAY_NAMESPACE}, expected ${PLATFORM_NS}"
[ "$ISTIO_GATEWAY_SERVICE"   = "$PLATFORM_RELEASE" ] || die "discovery found svc=${ISTIO_GATEWAY_SERVICE}, expected ${PLATFORM_RELEASE}"
[ "$ISTIO_GATEWAY_LABEL"     = "$ACTUAL_LABEL" ] || die "discovery found label=${ISTIO_GATEWAY_LABEL}, expected ${ACTUAL_LABEL}"
log_info "DISCOVERY OK — ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE}, selector istio=${ISTIO_GATEWAY_LABEL}"

# ---------------------------------------------------------------------------
# RED 2 — the OLD hardcoded selector must produce a DEAD route against this mesh.
#
# Probed from INSIDE the cluster (a curl pod hitting the gateway's ClusterIP): that is
# the faithful data path, and unlike `kubectl port-forward` it does not die when Envoy
# has no listener — a port-forward probe reports a misleading 000 for every case once
# the last Gateway goes away, which would make this RED indistinguishable from a broken
# harness.
# ---------------------------------------------------------------------------
PROBE_NS=istio-probe
# Test-fixture only: this runs on the KinD stand-in (internet-side), so the probe image is
# pulled from upstream rather than mirrored into Harbor — it is never used by an air-gapped
# install path. PROBE_IMAGE is overridable if a mirror is preferred.
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.18.0}"
kubectl create namespace "$PROBE_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$PROBE_NS" get pod probe >/dev/null 2>&1 || \
  kubectl -n "$PROBE_NS" run probe --image="$PROBE_IMAGE" --restart=Never --command -- sleep infinity >/dev/null
kubectl -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=180s

probe_code() { # -> HTTP code through the gateway, or 000 when there is no listener
  kubectl -n "$PROBE_NS" exec probe -- curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: ${WEBUI_HOST}" --max-time 5 \
    "http://${ISTIO_GATEWAY_SERVICE}.${ISTIO_GATEWAY_NAMESPACE}.svc.cluster.local/" 2>/dev/null || echo 000
}

log_info "RED 2: applying a Gateway with the OLD hardcoded selector (istio: ingressgateway)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: red-hardcoded, namespace: ${ISTIO_GATEWAY_NAMESPACE}}
spec:
  selector: {istio: ingressgateway}
  servers: [{port: {number: 80, name: http, protocol: HTTP}, hosts: ["${WEBUI_HOST}"]}]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: red-hardcoded, namespace: ${ARGOCD_DEST_NAMESPACE}}
spec:
  hosts: ["${WEBUI_HOST}"]
  gateways: ["${ISTIO_GATEWAY_NAMESPACE}/red-hardcoded"]
  http: [{route: [{destination: {host: ${APP_NAME}.${ARGOCD_DEST_NAMESPACE}.svc.cluster.local, port: {number: 80}}}]}]
YAML
sleep 10
RED2_CODE="$(probe_code)"
kubectl -n "$ISTIO_GATEWAY_NAMESPACE" delete gateway red-hardcoded --ignore-not-found >/dev/null
kubectl -n "$ARGOCD_DEST_NAMESPACE" delete virtualservice red-hardcoded --ignore-not-found >/dev/null
if [ "$RED2_CODE" = "200" ]; then
  die "RED 2 FAILED: the hardcoded 'istio: ingressgateway' selector SERVED traffic (HTTP 200) on a mesh labelled istio=${ACTUAL_LABEL}. The fixture is not testing what it claims."
fi
log_info "RED 2 OK — hardcoded selector produced HTTP ${RED2_CODE} (no listener bound), as it must"

log_info "PLATFORM MESH READY. Now run:  make install-ingress INGRESS_CONTROLLER=istio-existing"
log_info "  (it will DISCOVER ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE}, selector istio=${ISTIO_GATEWAY_LABEL},"
log_info "   install nothing, and attach only the Gateway + VirtualServices.)"
