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
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example; produced by make vks-login or make kind-up)}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
: "${ISTIO_VERSION:?}"; : "${ISTIO_NAMESPACE:?}"
# The gateway namespace is OUR install's default and lives here, not in .env.example:
# an uncommented global would be sourced into the environment in istio-existing mode too,
# constraining discovery to our own naming and hiding the platform team's real gateway.
# EXPORT, not a bare assignment: istio_apply_routes renders the manifests with envsubst, which
# reads the ENVIRONMENT. An unexported var renders EMPTY -> `namespace:` blank -> the Gateway is
# silently created in `default` while the VirtualServices reference istio-ingress/<name> -> 404
# from a listener that exists. (This regressed exactly this way once the var stopped being
# exported implicitly by load_env's `set -a` when it was commented out of .env.example.)
export ISTIO_GATEWAY_NAMESPACE="${ISTIO_GATEWAY_NAMESPACE:-istio-ingress}"
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
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
# The Gateway API CRDs. Nothing else installs them (Istio does not ship them), and on KinD they
# only appeared because cloud-provider-kind force-installs its own — which made our gateway-api
# e2e leg green for a KinD-only reason. We own this cluster on this path, so install them.
istio_ensure_gwapi_crds

# AIR-GAP FIRST. A carried chart (bundle/charts/*.tgz, put there by 10-mirror-pull.sh) is used in
# preference to the network — because on an air-gapped box `helm repo add` cannot work at all, and this
# is the DEFAULT ingress. CHART_REF() resolves each chart to a local .tgz or the repo alias.
CHART_DIR="${BUNDLE_DIR:-./bundle}/charts"
CHART_LOCAL=0
if [ -d "$CHART_DIR" ] && [ -n "$(find "$CHART_DIR" -name 'base-*.tgz' -print -quit 2>/dev/null)" ]; then
  CHART_LOCAL=1
  log_info "installing istio from the CARRIED charts in ${CHART_DIR} (no network)"
elif [ -d "${BUNDLE_DIR:-./bundle}/images" ] && [ "${ALLOW_PUBLIC_CHARTS:-0}" != "1" ]; then
  # A BUNDLE EXISTS BUT CARRIES NO CHARTS -> DO NOT SILENTLY REACH FOR THE INTERNET.
  # On a dual-homed box that turns a BROKEN BUNDLE into a GREEN INSTALL that proves nothing about the air
  # gap — the same false-green class as the builder image silently falling back to the public base. The
  # air-gapped operator then discovers it on the box that cannot fix it.
  die "the bundle at ${BUNDLE_DIR:-./bundle} carries NO istio charts (${CHART_DIR} is empty or absent),
  and istio is the DEFAULT ingress. Your bundle predates the carried charts.
  Re-cut it on the internet side:  make mirror-pull && make bundle
  (Refusing to fetch from ${CHART_REPO_URL}: on an air-gapped box that cannot work at all, and on a
   dual-homed box it would HIDE the fact that your bundle is incomplete.)
  If you are deliberately installing from the internet, say so: ALLOW_PUBLIC_CHARTS=1"
else
  log_info "no carried charts in ${CHART_DIR} — fetching from ${CHART_REPO_URL} (this needs the internet)"
  run helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" --force-update
  # INSIDE the else. It used to sit below this if/else, unconditionally — so on the air-gapped box (where
  # the repo was never added, and could not be) `helm repo update istio-release` fails, breaking the exact
  # path the carried charts exist to make work. A network call on the no-network path.
  run helm repo update "$CHART_REPO_NAME"
fi
# chart_ref <base|istiod|gateway> -> the local .tgz at the PINNED version, or the repo alias.
#
# B36 — THE VERSION LIVES IN THE FILENAME, AND `--version` CANNOT SAVE YOU. This used to glob
# `${1}-*.tgz` version-agnostically while every call site passed `--version "$ISTIO_VERSION"` to
# helm. That looks like a pin and is not: for a LOCAL .tgz path helm IGNORES `--version` —
# measured, `helm template ./istiod-1.30.2.tgz --version 1.30.3` renders `helm.sh/chart:
# istiod-1.30.2` with rc=0 and an EMPTY stderr, not even a warning.
#
# It is not a hypothetical: on the box this was written, `bundle/charts/` held base-1.30.2,
# istiod-1.30.3 and gateway-1.30.2 against a 1.30.3 pin — so the glob would have installed a MIXED
# MESH (1.30.2 CRDs + 1.30.3 istiod + 1.30.2 gateway) against 1.30.3 images, silently. Charts
# accumulate forever: mirror_prune_cache (10-mirror-pull.sh) prunes the IMAGE cache only.
#
# `${ISTIO_VERSION#v}`: `helm pull --version v1.30.3` warns, falls back, and writes
# `istiod-1.30.3.tgz` — so a leading `v` in the pin would false-block a correctly-cut bundle.
# (`+build.metadata` needs no handling: helm preserves it in the filename verbatim.)
#
# PURE: it prints or it dies. NEVER call it inside a helm argument — see the plain assignments below.
chart_ref() {
  local want v="${ISTIO_VERSION#v}"
  if [ "$CHART_LOCAL" != 1 ]; then printf '%s/%s' "$CHART_REPO_NAME" "$1"; return; fi
  want="${CHART_DIR}/${1}-${v}.tgz"
  # `ls`, not `find -printf`: -printf is GNU-only and this script runs on the AIR-GAP box, which may
  # be Photon/toybox. There, find would fail, and a `|| echo none` fallback would tell an operator
  # "carried: none" while the charts sit right there — sending them to re-cut an 11 GB bundle that is
  # fine. (That fallback is also unreachable on GNU: find exits 0 on no-match.)
  # shellcheck disable=SC2012  # `ls` is DELIBERATE: SC2012 says use find, but `find -printf` is
  # GNU-only and this runs on the air-gap box (Photon/toybox). Chart filenames are helm-generated
  # (`<name>-<semver>.tgz`), so the non-alphanumeric case SC2012 guards against cannot arise.
  [ -f "$want" ] || die "the bundle carries no ${1} chart at the PINNED version ${v}
  (looked for ${want})
  (carried: $(cd "$CHART_DIR" 2>/dev/null && ls -1 "${1}"-*.tgz 2>/dev/null | tr '\n' ' ' || true))
  Your bundle predates the ISTIO_VERSION pin. Re-cut it on the internet side:
      make mirror-pull && make bundle
  (Refusing to fall back to whatever version is on disk: helm IGNORES --version for a local .tgz, so
   that fallback installs the WRONG chart against ${v} images and reports success.)"
  printf '%s' "$want"
}

# Resolve ALL THREE UP FRONT, as PLAIN assignments. Both halves are load-bearing:
#   - PLAIN ASSIGNMENT, never `helm ... "$(chart_ref x)"`: chart_ref's `die` runs inside the command
#     substitution's SUBSHELL, so at a helm call site it exits only that subshell — the script
#     continues and helm gets an EMPTY argument. It "works" today only because real helm happens to
#     reject it, and `DRY_RUN=1` swallows it entirely (exit 0). An assignment's rc IS the
#     substitution's rc, so `set -e` fires on the die, DRY_RUN or not.
#   - UP FRONT, before any helm call: otherwise base installs its CRDs, THEN istiod dies on a stale
#     chart, leaving a half-installed control plane for the operator to unpick.
# Do NOT write `local x="$(chart_ref …)"` — `local` returns 0 and swallows the failure.
CHART_BASE="$(chart_ref base)"
CHART_ISTIOD="$(chart_ref istiod)"
CHART_GATEWAY="$(chart_ref gateway)"

# --- 2. CRDs (istio/base) -----------------------------------------------------
log_info "installing istio-base (CRDs) v${ISTIO_VERSION} into ${ISTIO_NAMESPACE}"
run helm upgrade --install istio-base "$CHART_BASE" \
  --namespace "$ISTIO_NAMESPACE" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s"

# --- 3. Control plane (istiod), images from Harbor ----------------------------
log_info "installing istiod v${ISTIO_VERSION} (hub=${HUB})"
run helm upgrade --install istiod "$CHART_ISTIOD" \
  --namespace "$ISTIO_NAMESPACE" \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  --set global.hub="$HUB" \
  --set global.tag="$ISTIO_VERSION" \
  --set global.proxy.autoInject=disabled \
  --set meshConfig.enableTracing=false \
  --set pilot.autoscaleEnabled=false

# --- 4. Ingress gateway (LoadBalancer), images from Harbor --------------------
log_info "installing istio ingress gateway (LoadBalancer) into ${ISTIO_GATEWAY_NAMESPACE}"
run helm upgrade --install "$GW_RELEASE" "$CHART_GATEWAY" \
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
state_set INGRESS_LB_IP "$LB_IP"
log_info "published INGRESS_LB_IP=${LB_IP} to $(state_file)"
log_info "Istio installed. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${TEKTON_DASHBOARD_HOST}  $(app_names | while read -r a; do if [ -n "$a" ]; then printf 'http://%s  ' "$(app_host "$a")"; fi; done)"
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
log_info "(no port-forward for the UIs; Harbor keeps its own LB IP)"
