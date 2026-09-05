#!/usr/bin/env bash
# 49-install-headlamp.sh — install headlamp (Kubernetes web UI) into the GUEST cluster, from HARBOR.
#
# NOT the VKS Standard Package path, and that is the owner's ruling with the mechanism behind it:
# scripts/vks-package.sh creates a Carvel PackageInstall resolving against the SYSTEM-managed
# PackageRepository in vmware-system-tkg, whose imgpkgBundle is VMware-hosted -- internet-dependent
# unless the entire repo is mirrored. Identical to the Istio correction: the package path
# (43-install-istio-package.sh:73) sets no global.hub and so proves nothing about the air gap, while
# the DEFAULT helm path points the images at Harbor.
#
# ─────────────────────────────────────────────────────────────────────────────────────────────
# THREE THINGS HERE ARE NOT COSMETIC. An adversary rendered the real chart (0.45.0) and found them.
#
# 1. THE CHART BINDS cluster-admin BY DEFAULT.
#    values.yaml ships clusterRoleBinding.create=true with clusterRoleName=cluster-admin, and the
#    default render emits a real ClusterRoleBinding headlamp-admin -> cluster-admin -> SA headlamp.
#    So a plain `helm install` IS a cluster-admin grant, before anyone mints a token. We force
#    `view`. That keeps the full browsing dashboard AND pod logs (pods/log is in `view`); it drops
#    edit/scale/delete and the in-browser terminal. Note pods/exec is admin-equivalent on any
#    cluster running a privileged pod, so granting it back would undo most of this.
#
# 2. HEADLAMP'S FRONTEND PULLS busybox FROM docker.io AT RUNTIME.
#    config.podDebugImage and config.nodeShellImage default to "" in the chart AND in the backend,
#    so nothing is passed and the frontend falls back to a hardcoded
#    DEFAULT_NODE_SHELL_LINUX_IMAGE = 'docker.io/library/busybox:latest'. On an air-gapped cluster
#    the mirror is green, the install is green, the Deployment is Running -- and the first person
#    to click "Node Shell" or "Debug" gets ImagePullBackOff forever. No offline gate can see it.
#    We pass BOTH, pointed at the mirrored, PINNED busybox in images/images.txt.
#
# 3. THE DEFAULT POD SPEC FAILS Pod Security `restricted` ON THREE COUNTS.
#    The rendered container securityContext is {privileged:false, runAsGroup:101, runAsNonRoot:true,
#    runAsUser:100} with NO seccompProfile, NO capabilities.drop and NO allowPrivilegeEscalation.
#    VKS enforces `restricted` by DEFAULT on guest clusters (VKr v1.26+); KinD enforces nothing, so
#    a local run is green and the lab REJECTS the pod at admission. The overrides below were
#    rendered and confirmed to produce all four required fields, so headlamp does NOT need a
#    `baseline` namespace.
# ─────────────────────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
load_env

require_cmd helm
require_cmd kubectl

: "${HEADLAMP_VERSION:?HEADLAMP_VERSION is not set — see .env.example}"
# ⚠️ USE THE ENV VAR NAME DIRECTLY, no local alias. check-namespace-labelled resolves the
# VARIABLE NAME at the ensure_namespace call site and matches it against NS_SPEC; an alias
# (HEADLAMP_NS=...) reads as an undeclared namespace and the gate correctly refuses it. Every
# sibling installer does the same (GITEA_NAMESPACE, TEKTON_NAMESPACE, CI_NAMESPACE).
HEADLAMP_NAMESPACE="${HEADLAMP_NAMESPACE:-headlamp}"
HEADLAMP_HOST="${HEADLAMP_HOST:-headlamp.vks.local}"
# The SA whose token is the login credential. DELIBERATELY NOT the chart's own SA: that one is
# bound by the chart, and if anyone ever restores the cluster-admin default we must not be handing
# out a token attached to it.
HEADLAMP_SA="${HEADLAMP_SA:-headlamp-viewer}"

# ---- the chart: CARRIED first, network only as a declared exception -----------------------------
# `helm repo add` CANNOT WORK on an air-gapped box, so 10-mirror-pull.sh carries the .tgz.
CHART_DIR="${BUNDLE_DIR:-./bundle}/charts"
# ⚠️ THE FILENAME IS CONSTRUCTED FROM THE PIN, NEVER GLOBBED (B36). For a LOCAL .tgz helm IGNORES
# `--version` -- measured elsewhere in this repo: `helm template ./x-1.30.2.tgz --version 1.30.3`
# renders 1.30.2 with rc=0 and an EMPTY stderr. Charts also accumulate forever (the mirror prune
# clears images only), so a glob silently installs whichever version the directory happens to hold.
CHART_TGZ="${CHART_DIR}/headlamp-${HEADLAMP_VERSION}.tgz"
if [ -f "$CHART_TGZ" ]; then
  CHART_REF="$CHART_TGZ"
  log_info "installing headlamp from the CARRIED chart ${CHART_TGZ} (no network)"
elif [ -d "${BUNDLE_DIR:-./bundle}/images" ] && [ "${ALLOW_PUBLIC_CHARTS:-0}" != "1" ]; then
  # A bundle exists but carries no headlamp chart -> REFUSE to reach for the internet. On a
  # dual-homed box that turns a BROKEN BUNDLE into a GREEN INSTALL proving nothing about the air
  # gap, and the air-gapped operator discovers it on the box that cannot fix it.
  die "the bundle at ${BUNDLE_DIR:-./bundle} carries no headlamp chart (${CHART_TGZ} is absent).
    Your bundle predates it, or HEADLAMP_VERSION changed since it was cut.
    Re-cut it on the internet side:  make mirror-pull && make bundle
    (carried: $(find "$CHART_DIR" -maxdepth 1 -name 'headlamp-*.tgz' -printf '%f ' 2>/dev/null || printf 'none'))
    Installing from the internet deliberately? Say so: ALLOW_PUBLIC_CHARTS=1"
else
  HEADLAMP_CHART_REPO="${HEADLAMP_CHART_REPO:-https://kubernetes-sigs.github.io/headlamp/}"
  log_info "no carried chart at ${CHART_TGZ} — fetching from ${HEADLAMP_CHART_REPO} (needs the internet)"
  run helm repo add headlamp-airgap "$HEADLAMP_CHART_REPO" --force-update
  run helm repo update headlamp-airgap
  CHART_REF="headlamp-airgap/headlamp"
fi

# ---- images, resolved through the SAME helper the mirror uses -----------------------------------
# Single-sourced deliberately: hand-composing "${HARBOR_URL}/${PROJECT}/..." here would be a second
# way to spell the same ref, and this repo's image-alignment gate exists because that drifts.
HL_IMG="$(mirror_target_ref "ghcr.io/headlamp-k8s/headlamp:v${HEADLAMP_VERSION}")"
BUSYBOX_IMG="$(mirror_target_ref "docker.io/library/busybox:1.37.0")"
HL_REGISTRY="${HL_IMG%/*}"          # harbor/project/headlamp-k8s
HL_REPO="${HL_IMG##*/}"; HL_REPO="${HL_REPO%%:*}"   # headlamp
log_info "headlamp image : ${HL_IMG}"
log_info "node-shell img : ${BUSYBOX_IMG}   (the one the FRONTEND pulls at runtime)"

ensure_namespace "$HEADLAMP_NAMESPACE" restricted

run helm upgrade --install headlamp "$CHART_REF" \
  --namespace "$HEADLAMP_NAMESPACE" \
  --set "image.registry=${HL_REGISTRY}" \
  --set "image.repository=${HL_REPO}" \
  --set "image.tag=v${HEADLAMP_VERSION}" \
  --set "clusterRoleBinding.clusterRoleName=view" \
  --set "config.nodeShellImage=${BUSYBOX_IMG}" \
  --set "config.podDebugImage=${BUSYBOX_IMG}" \
  --set "config.nodeShellNamespace=${HEADLAMP_NAMESPACE}" \
  --set "config.oidc.secret.create=false" \
  --set "podSecurityContext.seccompProfile.type=RuntimeDefault" \
  --set "securityContext.allowPrivilegeEscalation=false" \
  --set "securityContext.runAsNonRoot=true" \
  --set "securityContext.capabilities.drop={ALL}" \
  --set "securityContext.seccompProfile.type=RuntimeDefault" \
  --wait --timeout "${HEADLAMP_INSTALL_TIMEOUT:-5m}"

# ---- the login credential ------------------------------------------------------------------------
# A SEPARATE ServiceAccount bound to `view`, so the printed token is never attached to whatever the
# chart's own SA is bound to.
# ⚠️ NO TOKEN IS STORED HERE, DELIBERATELY. `kubectl create token` mints a BOUND, EXPIRING token
# (default 1 hour), so writing one into .env or the state overlay would reproduce exactly the
# stale-credential complaint this work started from: the operator copies it, gets 401, and nothing
# says why. `make creds` mints one AT REPORT TIME instead -- the same shape argocd-password.sh
# already uses. A long-lived Secret-based token was REJECTED: a permanent credential at rest in
# etcd that survives every teardown, and indefensible if the binding is ever widened.
run kubectl -n "$HEADLAMP_NAMESPACE" create serviceaccount "$HEADLAMP_SA" --dry-run=client -o yaml \
  | run kubectl apply -f -
run kubectl create clusterrolebinding "headlamp-viewer-${HEADLAMP_NAMESPACE}" \
  --clusterrole=view --serviceaccount="${HEADLAMP_NAMESPACE}:${HEADLAMP_SA}" \
  --dry-run=client -o yaml | run kubectl apply -f -

log_info "headlamp installed in namespace '${HEADLAMP_NAMESPACE}'"
log_info "  URL (once the ingress fronts it): http://${HEADLAMP_HOST}"
log_info "  login: paste a token from -> make creds   (minted fresh each time; they expire)"
