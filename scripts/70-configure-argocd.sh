#!/usr/bin/env bash
# 70-configure-argocd.sh — register the Gitea deploy repo with ArgoCD (so it can
# clone private repos) and create the ArgoCD Application that syncs javawebapp-deploy
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
: "${ARGOCD_NAMESPACE:?}"
: "${ARGOCD_TRACK_BRANCH:?}"; : "${GITEA_INTERNAL_URL:?}"; : "${GITEA_ORG:?}"
# One ArgoCD Application PER APP, from the registry.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
: "${GITEA_CI_USER:?}"
# ArgoCD deploy destination. Default in-cluster (KinD / ArgoCD-in-guest). On a real lab where
# ArgoCD runs on the Supervisor, `make argocd-register-guest` registers the guest cluster and
# sets ARGOCD_DEST_SERVER to its API URL so the Application deploys THERE, not on the Supervisor.
: "${ARGOCD_DEST_SERVER:=https://kubernetes.default.svc}"
export ARGOCD_NAMESPACE ARGOCD_TRACK_BRANCH ARGOCD_DEST_SERVER

kubectl get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 \
  || die "namespace '$ARGOCD_NAMESPACE' not found — is ArgoCD installed on this VKS cluster?"

# ---- PER APP: its deploy-repo credentials + its Application -----------------------------------
# One Application per app, each watching its OWN <app>-deploy repo and deploying into its OWN
# namespace. ONE template (k8s/argocd/application.yaml) rendered per app — adding an app is a row
# in apps/registry.tsv, not a new manifest.
TOKEN=""
[ -f "${REPO_ROOT}/secrets/gitea-ci-token" ] && TOKEN="$(cat "${REPO_ROOT}/secrets/gitea-ci-token")"

configure_app_argocd() {
  local app="$1"
  export DEPLOY_REPO_CLONE_URL="${GITEA_INTERNAL_URL}/${GITEA_ORG}/${APP_DEPLOY_REPO}.git"

  if [ -n "$TOKEN" ]; then
    log_info "registering ${APP_DEPLOY_REPO} with ArgoCD"
    # The token reaches kubectl on STDIN (a heredoc), never on argv — see common/security.md.
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-${APP_DEPLOY_REPO}
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
    log_warn "no CI token found — assuming a public deploy repo (no ArgoCD repo secret) for ${app}"
  fi

  log_info "creating ArgoCD Application '${APP_NAME}' -> ${DEPLOY_REPO_CLONE_URL} (ns ${APP_NAMESPACE})"
  # shellcheck disable=SC2016
  envsubst '${ARGOCD_NAMESPACE} ${APP_NAME} ${APP_NAMESPACE} ${ARGOCD_TRACK_BRANCH} ${DEPLOY_REPO_CLONE_URL} ${ARGOCD_DEST_SERVER}' \
    < "${REPO_ROOT}/k8s/argocd/application.yaml" | run kubectl apply -f -
}
for_each_app configure_app_argocd

log_info "ArgoCD Applications created: $(app_names | tr '\n' ' ')"
