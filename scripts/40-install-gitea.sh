#!/usr/bin/env bash
# 40-install-gitea.sh — install Gitea on VKS from k8s/gitea/gitea.yaml (image from
# Harbor). SQLite backend, single replica, self-contained (no chart to mirror).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${GITEA_NAMESPACE:?}"; : "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
# GITEA_URL DERIVES from GITEA_HOST (the ingress hostname) so the hostname has ONE source of
# truth. It used to be a second literal in .env.example kept in sync with GITEA_HOST by a prose
# "keep aligned" comment — i.e. by nothing. Set GITEA_URL explicitly only when the scheme/port
# genuinely differ from the ingress route.
GITEA_URL="${GITEA_URL:-http://${GITEA_HOST:?set GITEA_HOST (or GITEA_URL) in .env}}"
: "${GITEA_STORAGE_SIZE:?}"
export GITEA_NAMESPACE HARBOR_URL HARBOR_INFRA_PROJECT GITEA_URL GITEA_STORAGE_SIZE
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

# shellcheck disable=SC2016
ALLOWLIST='${GITEA_NAMESPACE} ${HARBOR_URL} ${HARBOR_INFRA_PROJECT} ${GITEA_URL} ${GITEA_STORAGE_SIZE}'

log_info "installing Gitea into namespace '$GITEA_NAMESPACE'"
# shellcheck disable=SC2016
envsubst "$ALLOWLIST" < "${REPO_ROOT}/k8s/gitea/gitea.yaml" | run kubectl apply -f -

log_info "waiting for Gitea to become ready (timeout ${READY_TIMEOUT_SECONDS}s)"
run kubectl -n "$GITEA_NAMESPACE" rollout status deploy/gitea --timeout="${READY_TIMEOUT_SECONDS}s"

log_info "Gitea installed. In-cluster: ${GITEA_INTERNAL_URL:-http://gitea-http.${GITEA_NAMESPACE}.svc:3000}"
log_info "next: make seed-gitea"
