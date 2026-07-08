#!/usr/bin/env bash
# 70-configure-argocd.sh — register the Gitea deploy repo with ArgoCD (so it can
# clone private repos) and create the ArgoCD Application that syncs webui-deploy
# to the cluster. ArgoCD is provided by VKS.
#
# The demo seeds public repos, so the repo secret is optional; it is created when
# a CI token is available (also makes private repos work). Token travels via
# stdin, never argv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${ARGOCD_NAMESPACE:?}"; : "${ARGOCD_APP_NAME:?}"; : "${ARGOCD_DEST_NAMESPACE:?}"
: "${ARGOCD_TRACK_BRANCH:?}"; : "${GITEA_INTERNAL_URL:?}"; : "${GITEA_ORG:?}"; : "${GITEA_DEPLOY_REPO:?}"
: "${GITEA_CI_USER:?}"
export ARGOCD_NAMESPACE ARGOCD_APP_NAME ARGOCD_DEST_NAMESPACE ARGOCD_TRACK_BRANCH
export DEPLOY_REPO_CLONE_URL="${GITEA_INTERNAL_URL}/${GITEA_ORG}/${GITEA_DEPLOY_REPO}.git"

kubectl get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
  || die "namespace '$ARGOCD_NAMESPACE' not found — is ArgoCD installed on this VKS cluster?"

# ---- Optional: register the deploy repo credentials with ArgoCD ----
TOKEN=""
[ -f "${REPO_ROOT}/secrets/gitea-ci-token" ] && TOKEN="$(cat "${REPO_ROOT}/secrets/gitea-ci-token")"
if [ -n "$TOKEN" ]; then
  log_info "registering Gitea deploy repo with ArgoCD"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-${GITEA_DEPLOY_REPO}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${DEPLOY_REPO_CLONE_URL}
  username: ${GITEA_CI_USER}
  password: ${TOKEN}
EOF
else
  log_warn "no CI token found — assuming a public deploy repo (no ArgoCD repo secret)"
fi

# ---- Create the Application ----
log_info "creating ArgoCD Application '$ARGOCD_APP_NAME' -> $DEPLOY_REPO_CLONE_URL"
# shellcheck disable=SC2016
envsubst '${ARGOCD_NAMESPACE} ${ARGOCD_APP_NAME} ${ARGOCD_DEST_NAMESPACE} ${ARGOCD_TRACK_BRANCH} ${DEPLOY_REPO_CLONE_URL}' \
  < "${REPO_ROOT}/argocd/application.yaml" | run kubectl apply -f -

log_info "Application created. ArgoCD will sync automatically (automated + selfHeal)."
log_info "Check: kubectl -n ${ARGOCD_NAMESPACE} get application ${ARGOCD_APP_NAME}"
