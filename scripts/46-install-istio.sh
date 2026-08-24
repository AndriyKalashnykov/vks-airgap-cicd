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
. "${SCRIPT_DIR}/lib/capacity.sh"
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
  # "carried: none" while the charts sit right there — sending them to re-cut a ~12 GB bundle that is
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

# --- 1b. Namespaces, PSA-LABELLED BEFORE ANYTHING SCHEDULES INTO THEM ---------
# ⚠️ ORDERING IS THE WHOLE POINT. These labels used to be applied at step 4b, AFTER the three
# helm installs -- and helm's --create-namespace makes an UNLABELLED namespace, so on a cluster
# that enforces PSA the pods are rejected before the label ever lands.
# MEASURED 2026-08-10 on a real VKS 9.1 guest cluster: every istiod pod was refused with
#   pods "istiod-69dc675d76-..." is forbidden: violates PodSecurity ...
# helm then sat in --wait until "context deadline exceeded / Replicas: 0/1", and `make
# install-ingress` failed. istio-system carried NO PSA labels at all, so it inherited the
# cluster default, which VKS sets to `restricted` (VKr v1.26+).
# INVISIBLE ON KinD, which enforces nothing -- this is a lab-fidelity gap, not a flake.
# ⚠️ NEITHER mesh namespace goes through ensure_namespace. That helper is create+psa+
# istio_no_inject_label, and TWO controls state the third must never touch these namespaces:
# lib/psa.sh ("istio-system is never passed here, so attach mode cannot touch the platform's own
# namespace") and check-namespace-labelled.sh. Beyond the invariant it is a live hazard:
# ISTIO_GATEWAY_NAMESPACE is env-settable and nothing asserts it differs from ISTIO_NAMESPACE, so
# the classic same-namespace layout would stamp istio-injection=disabled and re-create the
# ImagePullBackOff below. `run` so DRY_RUN=1 stays a dry run; stderr is NOT suppressed, so an RBAC
# refusal says so instead of surfacing as an apply error on empty input.
run bash -c "kubectl create namespace \"$ISTIO_NAMESPACE\" --dry-run=client -o yaml | kubectl apply -f -"
psa_label_namespace "$ISTIO_NAMESPACE" "${PSA_LEVEL_ISTIO_SYSTEM:-baseline}"

# ⚠️ THE GATEWAY NAMESPACE GETS PSA LABELS BUT **NOT** `istio-injection=disabled`.
# ensure_namespace stamps that label on purpose (lib/psa.sh, Backlog B26) so a platform mesh cannot
# inject into namespaces we own -- correct for APP namespaces, FATAL here. The istio/gateway chart
# ships `image: auto`, and ONLY the sidecar-injection webhook rewrites it to <hub>/proxyv2:<ver>.
# MEASURED 2026-08-10: routing this namespace through ensure_namespace set istio-injection=disabled,
# the webhook's namespaceSelector then excluded it, `auto` was never rewritten, and the pod sat in
#   Back-off pulling image "auto"  /  ErrImagePull
# with a perfectly correct `sidecar.istio.io/inject: "true"` LABEL on the pod itself.
run bash -c "kubectl create namespace \"$ISTIO_GATEWAY_NAMESPACE\" --dry-run=client -o yaml | kubectl apply -f -"
psa_label_namespace "$ISTIO_GATEWAY_NAMESPACE" "${PSA_LEVEL_INGRESS:-baseline}"

# --- 2. CRDs (istio/base) -----------------------------------------------------
log_info "installing istio-base (CRDs) v${ISTIO_VERSION} into ${ISTIO_NAMESPACE}"
run helm upgrade --install istio-base "$CHART_BASE" \
  --namespace "$ISTIO_NAMESPACE" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s"

# --- 3. Control plane (istiod), images from Harbor ----------------------------
log_info "installing istiod v${ISTIO_VERSION} (hub=${HUB})"
# ISTIOD_MEMORY_REQUEST — why we pin it, and why 2048Mi does not fit here.
# MEASURED 2026-08-24 on a real VKS guest cluster (best-effort-small workers, the sizing this repo
# documents): istiod Pending 42m, "0/3 nodes are available: 1 node(s) had untolerated taint(s),
# 2 Insufficient memory". Worker allocatable 2833Mi; the demo's own workload already holds
# 874/957Mi. Even PERFECTLY BALANCED that leaves 1918Mi free against the chart's 2048Mi request --
# 130Mi short with NO placement that fits. Irreducible FOR THIS WORKLOAD; it is not a universal.
# WHY IT USED TO WORK: the demo grew. Measured from the row logs, the runs that installed istio at
# 2048Mi carried TWO apps; it now carries SIX. Nothing about istio changed -- the cluster filled up
# underneath it, and 2048Mi was always going to cross the line eventually. That also means a
# passing install is NOT evidence the next one fits, which is what the preflight below is for.
# ⚠️ NOT ESTABLISHED: two runs on the SAME day, same app count and ordering, disagreed -- one fit
# istiod twice, the next did not. Do not invent a mechanism for that; it is unexplained.
# The chart's own values.yaml calls 2048Mi "Resources for a small pilot install" -- a scheduling
# RESERVATION for a general small production mesh, not a working-set measurement. This install sets
# global.proxy.autoInject=disabled (line above), so the mesh has exactly ONE xDS client: the ingress
# gateway proxy. Istio's perf guidance benchmarks 1000 services / 2000 pods; this demo is ~20
# services and 1 proxy.
# ⚠️ CATEGORY-1 CONSTANT (no-magic taxonomy): a MEASURED metric. It is NOT category-3 -- that
# requires the value to be underspecified on BOTH ends, and the chart specifies 2048Mi.
# MEASURED 2026-08-24, same cluster, istiod fully configured (25 svc / 96 pods, 8 VirtualServices
# applied 6m30s before the first sample, gateway attached, ONE xDS client), 3 samples over 12 min:
#   istiod RSS 43Mi / 39Mi / 39Mi, 0 restarts   (the gateway proxy: 26Mi)
# So 768Mi is ~18.7x the steady state. It is deliberately NOT tightened to ~256Mi yet: all three
# samples are IDLE-ish -- no Tekton build was running and `make verify` had not run. Re-sample
# `kubectl top pod -n istio-system` during a build before lowering it; PEAK is the number that
# should set a request, and the only cost of over-reserving is headroom (see the next paragraph).
# ⚠️ It lowers only the RESERVATION, never a ceiling: the rendered Deployment sets no limits and no
# GOMEMLIMIT, so istiod stays Burstable and cannot be cgroup-OOMKilled. The real cost is OOM-kill
# PRIORITY under node pressure (oom_score_adj 477 -> 804), which is why it must not be paired with
# cramming istiod onto the fullest node.
# ONE arg array, shared by the capacity render and the install. If they diverged, the check would
# measure a DIFFERENT Deployment than the one created -- a green that describes nothing.
ISTIOD_SET=(
  --set global.hub="$HUB"
  --set global.tag="$ISTIO_VERSION"
  --set global.proxy.autoInject=disabled
  --set meshConfig.enableTracing=false
  --set pilot.autoscaleEnabled=false
  --set pilot.resources.requests.memory="${ISTIOD_MEMORY_REQUEST:-768Mi}"
)
# Refuse a pod the scheduler cannot place, BEFORE helm burns its --wait discovering it.
capacity_assert_fits \
  "$(capacity_chart_request "$CHART_ISTIOD" "$ISTIO_VERSION" "${ISTIOD_SET[@]}")" istiod
run helm upgrade --install istiod "$CHART_ISTIOD" \
  --namespace "$ISTIO_NAMESPACE" \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  "${ISTIOD_SET[@]}"

# --- 4. Ingress gateway (LoadBalancer), images from Harbor --------------------
log_info "installing istio ingress gateway (LoadBalancer) into ${ISTIO_GATEWAY_NAMESPACE}"
GW_SET=(
  --set service.type=LoadBalancer
  --set labels.istio="$ISTIO_GATEWAY_LABEL"
  --set global.hub="$HUB"
  --set global.tag="$ISTIO_VERSION"
)
# A SECOND check, not a duplicate: it runs AFTER istiod is Running, so istiod's request is in the
# node's `used` and this is the CUMULATIVE question ("does the gateway fit in what is LEFT?").
# The request comes from the chart under these exact args, so a chart bump cannot drift past it.
capacity_assert_fits \
  "$(capacity_chart_request "$CHART_GATEWAY" "$ISTIO_VERSION" "${GW_SET[@]}")" "istio gateway"
run helm upgrade --install "$GW_RELEASE" "$CHART_GATEWAY" \
  --namespace "$ISTIO_GATEWAY_NAMESPACE" --create-namespace \
  --version "$ISTIO_VERSION" --wait --timeout "${READY_TIMEOUT_SECONDS}s" \
  "${GW_SET[@]}"

# --- 4b. RE-ASSERT the PSA labels ---------------------------------------------
# They are applied at 1b, BEFORE anything schedules (that ordering is load-bearing -- see there).
# This second pass is deliberate belt-and-braces: helm may recreate a namespace it owns, and a
# re-assert is idempotent and free.
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
# Published HERE, not in 44's dispatcher, so the controller and the IP land together: a run that
# died earlier must not leave "istio" beside the PREVIOUS controller's IP (47:119 does the same).
state_set INGRESS_CONTROLLER "istio"
log_info "published INGRESS_LB_IP=${LB_IP} to $(state_file)"
log_info "Istio installed. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${TEKTON_DASHBOARD_HOST}  $(app_names | while read -r a; do if [ -n "$a" ]; then printf 'http://%s  ' "$(app_host "$a")"; fi; done)"
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
log_info "(no port-forward for the UIs; Harbor keeps its own LB IP)"
