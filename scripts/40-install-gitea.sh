#!/usr/bin/env bash
# 40-install-gitea.sh — install Gitea on VKS from k8s/gitea/gitea.yaml (image from
# Harbor). SQLite backend, single replica, self-contained (no chart to mirror).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/podimages.sh
. "${SCRIPT_DIR}/lib/podimages.sh"   # podimages_is_ours: the ONE "is this image from our registry" rule
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
kubeconfig_ready
: "${GITEA_NAMESPACE:?}"
# Harbor is required, and its mirror is probed, only when the image COMES from Harbor: the default,
# or an explicit GITEA_IMAGE that starts with ${HARBOR_URL}/ (the form .env.example documents). An
# explicit non-Harbor image (the cross-cluster e2e's public gitea/gitea) needs neither. Decided BEFORE
# the defaulting line below, after which GITEA_IMAGE is always set.
# NOT a `${HARBOR_URL}/` prefix match: that missed another spelling of the same registry
# (`host:443/...`, a trailing slash or scheme on HARBOR_URL) and SILENTLY skipped the mirror probe.
# podimages_is_ours normalises through registry_hostport. The `-n` guard is load-bearing: it
# `${3:?}`-dies on an empty registry, and the cross-cluster e2e runs with no HARBOR_URL.
GITEA_IMAGE_FROM_HARBOR=1
if [ -n "${GITEA_IMAGE:-}" ]; then
  if [ -z "${HARBOR_URL:-}" ] || ! podimages_is_ours "$GITEA_IMAGE" "" "$HARBOR_URL"; then
    GITEA_IMAGE_FROM_HARBOR=0
    [ -z "${HARBOR_URL:-}" ] || log_info "GITEA_IMAGE's registry is not HARBOR_URL (${HARBOR_URL}) — the Harbor mirror check is SKIPPED (not a pass): ${GITEA_IMAGE}"
  fi
fi
# HARBOR_INFRA_PROJECT is required only for the DEFAULT image, whose ref is built from it. An explicit
# Harbor GITEA_IMAGE names its own project, and that is the one probed below.
if [ "$GITEA_IMAGE_FROM_HARBOR" = 1 ]; then : "${HARBOR_URL:?}"; fi
if [ -z "${GITEA_IMAGE:-}" ]; then : "${HARBOR_INFRA_PROJECT:?}"; fi
HARBOR_URL="${HARBOR_URL:-}"; HARBOR_INFRA_PROJECT="${HARBOR_INFRA_PROJECT:-}"
# GITEA_URL DERIVES from GITEA_HOST (the ingress hostname) so the hostname has ONE source of
# truth. It used to be a second literal in .env.example kept in sync with GITEA_HOST by a prose
# "keep aligned" comment — i.e. by nothing. Set GITEA_URL explicitly only when the scheme/port
# genuinely differ from the ingress route.
GITEA_URL="${GITEA_URL:-http://${GITEA_HOST:?set GITEA_HOST (or GITEA_URL) in .env}}"
: "${GITEA_STORAGE_SIZE:?}"
# Gitea's Service type. LoadBalancer by default: ArgoCD's repo-server may live in ANOTHER cluster
# (on a real lab it is a Supervisor Service) and must clone <app>-deploy over the network. The
# in-cluster DNS name does not resolve there, and the ingress cannot serve a machine (its routes
# match the hostname gitea.vks.local, which exists only in the operator's /etc/hosts) — see the
# comment on the Service in k8s/gitea/gitea.yaml. A LoadBalancer keeps its ClusterIP, so Tekton's
# in-cluster clone/write-back over GITEA_INTERNAL_URL is unaffected.
GITEA_SERVICE_TYPE="${GITEA_SERVICE_TYPE:-LoadBalancer}"
# The air-gap default: the image mirrored into Harbor. Overridable so a test WITHOUT a Harbor (the
# cross-cluster e2e, which exercises the ArgoCD topology rather than the air gap) can still run Gitea.
_gi_default=0; [ -n "${GITEA_IMAGE:-}" ] || _gi_default=1
GITEA_IMAGE="${GITEA_IMAGE:-${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/gitea/gitea:1.27.2-rootless}"
# The Harbor project the kubelet will actually pull from: the first path segment after the registry.
# It used to probe HARBOR_INFRA_PROJECT regardless -- measured: an explicit `harbor.test/infra/...`
# image made the probe query `/projects/cicd`, so an empty image project passed (then ImagePullBackOff,
# the B527 misdiagnosis) and a missing infra project died "Run: make mirror" for a project gitea never
# pulls from. A ref with no project segment leaves it empty -> harbor_assert_mirrored says SKIPPED.
# The DEFAULT image takes HARBOR_INFRA_PROJECT directly, never a re-parse of the built ref: a
# `HARBOR_URL` with a trailing slash or a scheme yields `h//cicd/...` or `https://...`, whose parse is
# empty, and the default image would silently lose its mirror probe (implementation round, measured).
GITEA_IMAGE_PROJECT=""
if [ "$_gi_default" = 1 ]; then
  GITEA_IMAGE_PROJECT="${HARBOR_INFRA_PROJECT}"
elif [ "$GITEA_IMAGE_FROM_HARBOR" = 1 ]; then
  _gi_rest="${GITEA_IMAGE#*/}"
  case "$_gi_rest" in */*) GITEA_IMAGE_PROJECT="${_gi_rest%%/*}" ;; esac
fi
export GITEA_NAMESPACE HARBOR_URL HARBOR_INFRA_PROJECT GITEA_URL GITEA_STORAGE_SIZE GITEA_SERVICE_TYPE GITEA_IMAGE
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
LB_TIMEOUT_SECONDS="${GITEA_LB_TIMEOUT_SECONDS:-180}"

# shellcheck disable=SC2016
ALLOWLIST='${GITEA_NAMESPACE} ${HARBOR_URL} ${HARBOR_INFRA_PROJECT} ${GITEA_URL} ${GITEA_STORAGE_SIZE} ${GITEA_SERVICE_TYPE} ${GITEA_IMAGE}'

log_info "installing Gitea into namespace '$GITEA_NAMESPACE' (Service type: ${GITEA_SERVICE_TYPE})"

# Create the namespace WITH its PSA + no-inject labels, HERE, before the manifest that carries its
# pods. Two bugs, one fix:
#
#   1. `make install-all` did NOT run `install-ingress` when this was written (it has since #1091) — and until then the ONLY
#      ensure_namespace calls for gitea lived inside lib/istio.sh's route functions (:278, :566),
#      reachable only from that target. So on the documented real-lab install the label landed
#      NEVER, not late. `make e2e-kind` runs install-ingress explicitly, which is precisely what
#      hid it: the e2e's own target list made gitea look labelled while an operator got nothing.
#   2. Even when install-ingress DID run, k8s/gitea/gitea.yaml used to declare `kind: Namespace`
#      alongside this Deployment, so the ns and its pods were created together and any later label
#      arrived after the pods it exists to protect. Admission webhooks fire on CREATE.
#
# This mirrors 70-configure-argocd.sh:362, which already fixed exactly this for the app namespaces
# and says so in its own comment — gitea and tekton were simply left behind.
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"

# ── Is there anything in this Harbor to pull? (B527) ─────────────────────────────────────────────
# MEASURED 2026-09-05: the lab was rebuilt, Harbor came back EMPTY, the project did not exist, and
# this install died `ImagePullBackOff / 401 Unauthorized`. That 401 is the Docker Registry v2 AUTH
# CHALLENGE — returned for every repository, present or absent — so it read as a credential problem
# and was diagnosed as one TWICE. Nothing checked whether the images were there.
# One anonymous, credential-OPTIONAL API call (measured 15-30 ms on the live lab) answers it before
# a helm --wait burns READY_TIMEOUT_SECONDS discovering it. Same shape as capacity_assert_fits:
# an escape hatch, and every unknown is a LOUD SKIP that says it is not a pass.
# shellcheck source=scripts/lib/harbor_probe.sh
. "${SCRIPT_DIR}/lib/harbor_probe.sh"
# A non-Harbor image does not pull from Harbor, so a Harbor mirror check would measure the wrong thing.
[ "$GITEA_IMAGE_FROM_HARBOR" = 0 ] || harbor_assert_mirrored "${GITEA_IMAGE_PROJECT}" "gitea"
ensure_namespace "$GITEA_NAMESPACE" "${PSA_LEVEL_GITEA:-restricted}"

# shellcheck disable=SC2016
envsubst "$ALLOWLIST" < "${REPO_ROOT}/k8s/gitea/gitea.yaml" | run kubectl apply -f -

log_info "waiting for Gitea to become ready (timeout ${READY_TIMEOUT_SECONDS}s)"
run kubectl -n "$GITEA_NAMESPACE" rollout status deploy/gitea --timeout="${READY_TIMEOUT_SECONDS}s"

# --- publish the address an OFF-CLUSTER ArgoCD can clone from -------------------------------------
# GITEA_ARGOCD_URL is what k8s/argocd/application.yaml's repoURL is rendered with. It MUST be
# routable from the cluster ArgoCD runs in. When ArgoCD is in THIS cluster (KinD, ArgoCD-in-guest)
# the in-cluster URL is correct and this is a no-op; when it is not, only the LB address works.
if [ "$GITEA_SERVICE_TYPE" = "LoadBalancer" ]; then
  log_info "waiting for the Gitea LoadBalancer to be assigned an address (timeout ${LB_TIMEOUT_SECONDS}s)"
  GITEA_LB_IP=""
  for _ in $(seq 1 "$LB_TIMEOUT_SECONDS"); do
    GITEA_LB_IP="$(kubectl -n "$GITEA_NAMESPACE" get svc gitea-http \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [ -n "$GITEA_LB_IP" ] && break
    sleep 1
  done
  if [ -n "$GITEA_LB_IP" ]; then
    # Publish the IP for humans (`make creds-show`) — but NOT a GITEA_ARGOCD_URL for a later step to
    # read back as an input. 70-configure-argocd.sh RESOLVES the address from the live Service at the
    # moment it needs it, so a rebuilt Gitea can never be cloned from a stale address. (Publishing it
    # as an input is the trap INGRESS_LB_IP_OVERRIDE exists to avoid.)
    state_set GITEA_LB_IP "$GITEA_LB_IP"
    log_info "Gitea LoadBalancer: ${GITEA_LB_IP}:3000 (published as GITEA_LB_IP)"
  else
    # NOT fatal here: a single-cluster deploy never needs it. It IS fatal in 70-configure-argocd.sh,
    # which refuses to build a repoURL an off-cluster ArgoCD cannot reach.
    log_warn "the Gitea LoadBalancer never got an address — no cluster-external Gitea URL."
    log_warn "  Fine when ArgoCD runs in THIS cluster. If it does NOT, 'make gitops' will refuse to"
    log_warn "  continue: set GITEA_ARGOCD_URL_OVERRIDE to an address the ArgoCD cluster can reach."
  fi
fi

log_info "Gitea installed. In-cluster (Tekton): ${GITEA_INTERNAL_URL:-http://gitea-http.${GITEA_NAMESPACE}.svc:3000}"
log_info "next: make seed-gitea"
