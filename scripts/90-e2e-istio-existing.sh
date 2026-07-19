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
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
load_env

require_cmd kubectl
require_cmd helm
require_cmd jq
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${ISTIO_VERSION:?}"
# The RED tests probe ONE app's host (any app proves the selector/gateway mechanics); take the
# first from the registry rather than hardcoding an app name.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
PROBE_APP="$(app_names | head -1)"
# app_export sets APP_NAME/APP_NAMESPACE/... for the probe app. WITHOUT it this fixture used the
# GLOBALS the multi-app refactor DELETED (APP_NAME, ARGOCD_DEST_NAMESPACE) — under `set -u` that is
# an "unbound variable" abort, so this target (the ATTACH path, the one a real lab actually uses)
# was DEAD CODE after the rename. Found by the VKS adversarial review.
app_export "$PROBE_APP"
PROBE_HOST="$(app_host "$PROBE_APP")"; export PROBE_HOST

PLATFORM_NS="${PLATFORM_ISTIO_NAMESPACE:-platform-ingress}"
PLATFORM_RELEASE="${PLATFORM_ISTIO_RELEASE:-platform-gw}"
PLATFORM_ISTIOD_NS="${PLATFORM_ISTIOD_NAMESPACE:-istio-system}"
HUB="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/istio"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

# ---------------------------------------------------------------------------
# RED 1 — no mesh yet: the attach path MUST fail, not quietly succeed.
# ---------------------------------------------------------------------------
if kubectl get deploy -A -l app=istiod -o name 2>/dev/null | grep . >/dev/null; then
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

# THE CRDs ARE THE PLATFORM TEAM'S, NOT THE TENANT'S — and this is now load-bearing, not decoration.
#
# The Gateway API CRDs are CLUSTER-SCOPED, so a tenant cannot install them; 47-attach-istio.sh
# correctly never tries. Until now they appeared anyway, because cloud-provider-kind force-installed
# them at cluster start — which is exactly the KinD shim that made #209 unverifiable. Now that CPK's
# channel is disabled (05-kind-up.sh), SOMEONE has to install them, and in the world this fixture is
# imitating that someone is the mesh admin. So the fixture does it, in the platform-team section,
# where it belongs. Without this the attach e2e dies at lib/istio.sh's "GatewayClass 'istio' is not
# Accepted" — a self-inflicted RED that says nothing about the tenant path.
#
# It also hands us the honest ABSENT state for free: assert it BEFORE installing.
if istio_gwapi_crds_present; then
  die "the Gateway API CRDs are present BEFORE the platform team installed them.
  Something else is installing them (cloud-provider-kind's --gateway-channel?), which is precisely the
  shim that made the CRD install untestable. Re-check 05-kind-up.sh."
fi
log_info "PLATFORM: Gateway API CRDs are ABSENT (the honest tenant starting state) — installing them as the mesh admin"
istio_ensure_gwapi_crds

run helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
run helm repo update istio
run helm upgrade --install istio-base istio/base \
  --namespace "$PLATFORM_ISTIOD_NS" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s"
run helm upgrade --install istiod istio/istiod \
  --namespace "$PLATFORM_ISTIOD_NS" \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set global.hub="$HUB" --set global.tag="$ISTIO_VERSION" \
  --set sidecarInjectorWebhook.enableNamespacesByDefault=true --set pilot.autoscaleEnabled=false
# ^ THE SIMULATED PLATFORM MESH INJECTS BY DEFAULT. That is the whole point of this leg: B26's
# hazard is a mesh we do not own whose injector reaches into OUR namespaces. This fixture used to
# pass `global.proxy.autoInject=disabled` — i.e. it simulated the SAFE case and never once
# exercised the thing the leg exists to test.
#
# THERE ARE TWO INDEPENDENT GATES, and conflating them is easy — rendered from the pinned chart
# (bundle/charts/istiod-1.30.3.tgz), not recalled:
#
#     --set                                                  auto-rule   policy:
#     global.proxy.autoInject=disabled            (before)       0       disabled
#     sidecarInjectorWebhook.enableNamespacesByDefault=true (now) 1       enabled
#     BOTH                                                       1       disabled   <- fires, then DECLINES
#     neither                                                    0       enabled
#
#   1. the WEBHOOK — `enableNamespacesByDefault` adds a 5th rule (`auto.sidecar-injector.istio.io`,
#      failurePolicy: Fail) matching an UNLABELLED namespace's UNANNOTATED pod. Without it the
#      webhook is never called for such a pod.
#   2. the POLICY — `global.proxy.autoInject` sets `policy:` in the `istio-sidecar-injector`
#      ConfigMap, a SECOND gate evaluated INSIDE istiod's /inject handler, after the selector has
#      already matched.
# Injection needs BOTH. So this is a REPLACE, not a delete: setting both yields a webhook that
# fires and an istiod that declines — a leg that looks armed and injects nothing.
#
# ⚠️ Do NOT read "the webhook is byte-identical with or without autoInject" (true — rendered and
# diffed) as "autoInject is a no-op" (FALSE — it flips `policy`). That inference would also invite
# deleting `global.proxy.autoInject=disabled` from 46-install-istio.sh, where we set it on OUR OWN
# mesh: there it is a real second-layer defence, not noise.
# ---------------------------------------------------------------------------
# THE INJECTION MATRIX — 3 cells, and cell 1 is a POSITIVE CONTROL.
#
# WHY A CONTROL AND NOT JUST "our pods have 1 container": because that assertion is GREEN WHEN
# INJECTION SILENTLY FAILS. Measured — helm ACCEPTS a typo'd --set key without a word:
#     helm template ... --set sidecarInjectorWebhook.enableNamespacesByDefaults=true   (note the s)
#     -> exit 0, no warning, no error, and ZERO `auto` rules rendered.
# A typo, a chart bump renaming the value, or B35's revision-tag shape (which renders only 2 rules
# and ignores this knob entirely) all yield: nothing injects, every pod has 1 container, the leg
# reports success, and it tested NOTHING. Cell 1 is the only thing standing between us and that.
#
# WHAT PROVES B26 END-TO-END IS `verify`, NOT THIS MATRIX. `verify` runs after install-ingress and
# waits on `rollout status`, so ArgoCD syncs FRESH app pods and Tekton creates FRESH TaskRun pods —
# through the live webhook, in the real namespaces. Delete istio_no_inject_label and those pods get
# istio-init (NET_ADMIN), PSA `restricted` rejects them, and `verify` times out. THAT is the
# load-bearing coverage. This matrix isolates the mechanism and, via cell 1, proves the leg is armed
# at all. Do not read it as the B26 test; it is the anti-vacuity control for the B26 test.
log_info "injection matrix: proving the fixture INJECTS, and that our two labels each defeat it"
MATRIX_NS_BARE=inject-probe-bare
MATRIX_NS_NSLBL=inject-probe-nslabel
MATRIX_NS_PODLBL=inject-probe-podlabel
# A `die` below would otherwise leave an injected pod + a live Envoy behind, making the next
# `kubectl get pods -A` triage noisier for whoever debugs this.
trap 'kubectl delete ns "$MATRIX_NS_BARE" "$MATRIX_NS_NSLBL" "$MATRIX_NS_PODLBL" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

# containers <ns> — count containers + initContainers. istio-init is an INIT container and is the
# one PSA rejects (NET_ADMIN), so counting only .spec.containers would miss the thing that matters.
_matrix_containers() {
  kubectl -n "$1" get pod p -o jsonpath='{.spec.containers[*].name} {.spec.initContainers[*].name}' 2>/dev/null
}
_matrix_run() { # <ns> [extra kubectl run args...]
  local ns="$1"; shift
  kubectl -n "$ns" run p --image="${PROBE_IMAGE:-curlimages/curl:8.18.0}" --restart=Never \
    "$@" --command -- sleep 300 >/dev/null 2>&1
  kubectl -n "$ns" wait --for=jsonpath='{.metadata.name}'=p pod/p --timeout=60s >/dev/null 2>&1 || true
}

# CELL 1 — THE CONTROL. A bare ns + a bare pod must match `auto` on every selector:
#   nsSel  istio-injection DoesNotExist ✓ · istio.io/rev DoesNotExist ✓ · metadata.name NotIn[kube-*] ✓
#   objSel sidecar.istio.io/inject DoesNotExist ✓ · istio.io/rev DoesNotExist ✓
run kubectl create namespace "$MATRIX_NS_BARE" >/dev/null
_matrix_run "$MATRIX_NS_BARE"
ctl="$(_matrix_containers "$MATRIX_NS_BARE")"
case "$ctl" in
  *istio-proxy*|*istio-init*) log_info "  CONTROL ok — the platform mesh injects a bare namespace [$ctl]" ;;
  *) die "INJECTION MATRIX CONTROL FAILED: a bare pod in a bare namespace was NOT injected [got: '${ctl}'].
  The fixture is NOT injecting, so this leg proves NOTHING about B26 — every 'our pods are clean'
  assertion below would pass for the wrong reason. Check that --set
  sidecarInjectorWebhook.enableNamespacesByDefault=true is spelled correctly and still exists in
  istio ${ISTIO_VERSION} (helm accepts an unknown --set key SILENTLY), and that the injector
  ConfigMap says 'policy: enabled' (global.proxy.autoInject would flip it to disabled)." ;;
esac

# CELL 2 — the NAMESPACE label (lib/psa.sh's istio_no_inject_label) must defeat all five rules.
ensure_namespace "$MATRIX_NS_NSLBL"
_matrix_run "$MATRIX_NS_NSLBL"
ctl="$(_matrix_containers "$MATRIX_NS_NSLBL")"
case "$ctl" in
  *istio-proxy*|*istio-init*) die "INJECTION MATRIX: the NAMESPACE label istio-injection=disabled did NOT defeat injection [$ctl].
  ensure_namespace (lib/psa.sh) is the control B26 depends on for every namespace we own." ;;
  *) log_info "  ns-label ok — istio-injection=disabled defeats the injector [$ctl]" ;;
esac

# CELL 3 — the POD label (k8s/*, deploy/*) must defeat all five on the OBJECT alone, in a namespace
# with no label at all. This is the race-free half: ArgoCD's CreateNamespace=true can sync a pod
# before any installer labels its namespace.
run kubectl create namespace "$MATRIX_NS_PODLBL" >/dev/null
_matrix_run "$MATRIX_NS_PODLBL" --labels=sidecar.istio.io/inject=false
ctl="$(_matrix_containers "$MATRIX_NS_PODLBL")"
case "$ctl" in
  *istio-proxy*|*istio-init*) die "INJECTION MATRIX: the POD label sidecar.istio.io/inject=false did NOT defeat injection [$ctl].
  check-pod-inject-label.sh enforces this label on every workload we ship; if it no longer works,
  that gate is guarding nothing." ;;
  *) log_info "  pod-label ok — sidecar.istio.io/inject=false defeats the injector [$ctl]" ;;
esac
log_info "injection matrix PASSED — the mesh injects, and BOTH of our labels defeat it independently"
kubectl delete ns "$MATRIX_NS_BARE" "$MATRIX_NS_NSLBL" "$MATRIX_NS_PODLBL" --ignore-not-found --wait=false >/dev/null 2>&1 || true
trap - EXIT

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
# ensure_namespace, NOT a bare create — MANDATORY now that the fixture injects, not hygiene.
# A bare namespace matches the `auto` rule, so the probe would get a sidecar; iptables REDIRECT then
# makes curl's TCP connect SUCCEED into Envoy, which finds no upstream listener and returns 503.
# RED 2 asserts EXACTLY `000` (deliberately — "the SPECIFIC failure, not merely 'not 200'"), so it
# would die on every run, with a message sending the operator to debug the SELECTOR.
#
# NO LEVEL ARGUMENT: psa_label_namespace returns early on an empty level, so the namespace gets
# `istio-injection=disabled` and NO PSA label — right for a bare `kubectl run`, which sets no
# seccompProfile and would be rejected by `restricted`. Same precedent as 07-install-argocd.sh.
# The ns label alone defeats all five rules; a pod label would be redundant here.
ensure_namespace "$PROBE_NS"
kubectl -n "$PROBE_NS" get pod probe >/dev/null 2>&1 || \
  kubectl -n "$PROBE_NS" run probe --image="$PROBE_IMAGE" --restart=Never --command -- sleep infinity >/dev/null
kubectl -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=180s

probe_code() { # -> HTTP code through the gateway, or 000 when there is no listener
  # curl already writes `000` via -w on a connection failure, so a `|| echo 000` fallback
  # would CONCATENATE and print "000000". Swallow curl's non-zero exit instead.
  kubectl -n "$PROBE_NS" exec probe -- sh -c "curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: ${PROBE_HOST}' --max-time 5 \
    'http://${ISTIO_GATEWAY_SERVICE}.${ISTIO_GATEWAY_NAMESPACE}.svc.cluster.local/' || true" 2>/dev/null
}

log_info "RED 2: applying a Gateway with the OLD hardcoded selector (istio: ingressgateway)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: red-hardcoded, namespace: ${ISTIO_GATEWAY_NAMESPACE}}
spec:
  selector: {istio: ingressgateway}
  servers: [{port: {number: 80, name: http, protocol: HTTP}, hosts: ["${PROBE_HOST}"]}]
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: red-hardcoded, namespace: ${APP_NAMESPACE}}
spec:
  hosts: ["${PROBE_HOST}"]
  gateways: ["${ISTIO_GATEWAY_NAMESPACE}/red-hardcoded"]
  http: [{route: [{destination: {host: ${APP_NAME}.${APP_NAMESPACE}.svc.cluster.local, port: {number: 80}}}]}]
YAML
sleep 10
RED2_CODE="$(probe_code)"
kubectl -n "$ISTIO_GATEWAY_NAMESPACE" delete gateway red-hardcoded --ignore-not-found >/dev/null
kubectl -n "$APP_NAMESPACE" delete virtualservice red-hardcoded --ignore-not-found >/dev/null
# Assert the SPECIFIC failure, not merely "not 200". A hardcoded selector binds NO listener, so the
# connection is REFUSED — curl reports 000. Accepting any non-200 let a BROKEN fixture pass for the
# wrong reason: with the (then-unbound) vars empty the VirtualService was malformed, which also is
# not-200. A gate that passes when the fixture is broken is a gate that cannot fail.
if [ "$RED2_CODE" != "000" ]; then
  die "RED 2 FAILED: expected HTTP 000 (no listener bound — connection refused) from the hardcoded 'istio: ingressgateway' selector on a mesh labelled istio=${ACTUAL_LABEL}, got '${RED2_CODE}'. 200 => the selector wrongly SERVED traffic; anything else => the fixture itself is broken and is not testing what it claims."
fi
log_info "RED 2 OK — hardcoded selector produced HTTP 000 (no listener bound), as it must"

log_info "PLATFORM MESH READY. Now run:  make install-ingress INGRESS_CONTROLLER=istio-existing"
log_info "  (it will DISCOVER ${ISTIO_GATEWAY_NAMESPACE}/${ISTIO_GATEWAY_SERVICE}, selector istio=${ISTIO_GATEWAY_LABEL},"
log_info "   install nothing, and attach only the Gateway + VirtualServices.)"
