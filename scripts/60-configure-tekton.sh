#!/usr/bin/env bash
# 60-configure-tekton.sh — create the CI namespace, secrets (Gitea git-auth,
# Harbor dockerconfig, webhook HMAC), the Harbor CA configmap, then render and
# apply the RBAC, tasks, pipeline, and triggers.
#
# Secrets are created via stdin / temp files (never argv). Manifest image refs +
# in-cluster URLs are rendered from .env with a RESTRICTED envsubst allowlist so
# step-script $(...)/${...} are left untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
load_env

require_cmd kubectl
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${CI_NAMESPACE:?}"; : "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_APP_PROJECT:?}"
: "${HARBOR_USERNAME:?}"; : "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env}"
: "${GITEA_INTERNAL_URL:?}"; : "${GITEA_ORG:?}"
: "${GITEA_CI_USER:?}"; : "${APP_BRANCH:?}"; : "${ARGOCD_TRACK_BRANCH:?}"
: "${BUILDER_IMAGE_TAG:?}"
# The app registry: everything below is rendered ONCE PER APP from it.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

# ---- CI-bot Gitea token (minted by 50-seed-gitea-repos.sh) ----
GITEA_CI_TOKEN="${GITEA_CI_TOKEN:-}"
[ -z "$GITEA_CI_TOKEN" ] && [ -f "${REPO_ROOT}/secrets/gitea-ci-token" ] \
  && GITEA_CI_TOKEN="$(cat "${REPO_ROOT}/secrets/gitea-ci-token")"
[ -n "$GITEA_CI_TOKEN" ] || die "GITEA_CI_TOKEN not set and secrets/gitea-ci-token missing — run 'make seed-gitea' first"

# ---- Derived values for envsubst rendering ----
# App-INDEPENDENT tokens. The per-app ones (APP_NAME/APP_IMAGE/APP_BUILDER_IMAGE/APP_RUNTIME_IMAGE/
# APP_TEST_TASK/APP_REPO_CLONE_URL/DEPLOY_REPO_CLONE_URL) are exported inside the loop below.
export CI_NAMESPACE HARBOR_URL HARBOR_INFRA_PROJECT APP_BRANCH ARGOCD_TRACK_BRANCH
if [ "${HARBOR_INSECURE:-0}" = "1" ]; then export HARBOR_INSECURE_BOOL="true"; else export HARBOR_INSECURE_BOOL="false"; fi

# Single-quoted on purpose: envsubst needs the literal ${VAR} names (an allowlist),
# not their expansions.
# shellcheck disable=SC2016
ALLOWLIST='${CI_NAMESPACE} ${HARBOR_URL} ${HARBOR_INFRA_PROJECT} ${APP_BRANCH} ${APP_REPO_CLONE_URL} ${DEPLOY_REPO_CLONE_URL} ${ARGOCD_TRACK_BRANCH} ${APP_IMAGE} ${APP_NAME} ${APP_TEST_TASK} ${APP_GIT_REPO} ${APP_BUILDER_IMAGE} ${APP_RUNTIME_IMAGE} ${HARBOR_INSECURE_BOOL}'

require_cmd envsubst "install gettext (provides envsubst)"

# ---- Namespace ----
# The CI namespace needs `baseline`, not `restricted`: Kaniko builds run as root (runAsUser=0,
# unrestricted capabilities, no seccompProfile) — VKS enforces `restricted` by DEFAULT from VKr
# v1.26, so without this label the build TaskRun pods are REJECTED outright on a real guest
# cluster. Measured, not guessed: `make psa-check`.
ensure_namespace "$CI_NAMESPACE" "${PSA_LEVEL_CI:-baseline}"

# ---- Secret: Gitea git basic-auth (annotated for Tekton SA credential wiring) ----
log_info "creating gitea-git-auth secret"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-git-auth
  namespace: ${CI_NAMESPACE}
  annotations:
    tekton.dev/git-0: ${GITEA_INTERNAL_URL}
type: kubernetes.io/basic-auth
stringData:
  username: ${GITEA_CI_USER}
  password: ${GITEA_CI_TOKEN}
EOF

# ---- Secret: Harbor dockerconfig for kaniko push (built in a temp file, not argv) ----
log_info "creating harbor-dockerconfig secret"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
auth="$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 -w0 2>/dev/null || printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64)"
( umask 077; printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" > "${tmp}/config.json" )
# Generic secret keyed EXACTLY 'config.json' (not .dockerconfigjson): the kaniko
# task sets DOCKER_CONFIG to the workspace dir, and kaniko reads <dir>/config.json.
# A kubernetes.io/dockerconfigjson secret would mount as '.dockerconfigjson' and
# kaniko would push anonymously (UNAUTHORIZED).
# Delete-then-create: a Secret's `type` is immutable, so `apply` can't convert an
# existing dockerconfigjson secret to this generic one — recreate it.
run kubectl -n "$CI_NAMESPACE" delete secret harbor-dockerconfig --ignore-not-found
run kubectl -n "$CI_NAMESPACE" create secret generic harbor-dockerconfig \
  --from-file=config.json="${tmp}/config.json"

# ---- Secret: webhook HMAC token (shared with the Gitea webhook from 50-seed) ----
token="$(ensure_secret_token "${REPO_ROOT}/secrets/webhook-token")"
log_info "creating gitea-webhook-secret"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitea-webhook-secret
  namespace: ${CI_NAMESPACE}
type: Opaque
stringData:
  secretToken: ${token}
EOF

# ---- ConfigMap: Harbor CA (for kaniko TLS trust) ----
if [ "${HARBOR_INSECURE:-0}" != "1" ] && [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "$HARBOR_CA_FILE" ]; then
  log_info "creating harbor-ca configmap from $HARBOR_CA_FILE"
  run kubectl -n "$CI_NAMESPACE" create configmap harbor-ca \
    --from-file=ca.crt="$HARBOR_CA_FILE" --dry-run=client -o yaml | run kubectl apply -f -
else
  log_warn "no Harbor CA file (or HARBOR_INSECURE=1) — kaniko will rely on insecure-registry=$HARBOR_INSECURE_BOOL"
fi

# ---- Render + apply RBAC, tasks, pipeline, triggers ----
render_and_apply() {
  local f="$1"
  log_info "applying $(basename "$f")"
  # shellcheck disable=SC2016
  envsubst "$ALLOWLIST" < "$f" | run kubectl apply -f -
}
# SHARED, applied once: the RBAC, every Task (git-clone/kaniko-build/update-deploy + each
# language's test task), and the ONE EventListener that label-selects the per-app Triggers.
render_and_apply "${REPO_ROOT}/k8s/tekton/rbac.yaml"
for t in "${REPO_ROOT}"/k8s/tekton/tasks/*.yaml; do render_and_apply "$t"; done
render_and_apply "${REPO_ROOT}/k8s/tekton/eventlistener.yaml"

# PER APP, from apps/registry.tsv: its Pipeline (<app>-ci) and its Trigger/Binding/Template.
# ONE template each — only the name and the test task differ, so the walk is provably identical
# for every app and adding one is a registry row, not a YAML edit.
# shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
configure_app() {
  local app="$1"
  export APP_REPO_CLONE_URL="${GITEA_INTERNAL_URL}/${GITEA_ORG}/${APP_GIT_REPO}.git"
  export DEPLOY_REPO_CLONE_URL="${GITEA_INTERNAL_URL}/${GITEA_ORG}/${APP_DEPLOY_REPO}.git"
  log_info "configuring pipeline for app '${app}' (lang=${APP_LANG}, test=${APP_TEST_TASK})"
  render_and_apply "${REPO_ROOT}/k8s/tekton/pipeline.yaml"
  render_and_apply "${REPO_ROOT}/k8s/tekton/trigger-app.yaml"
}
for_each_app configure_app

# ---- Attach the git-auth secret to the SHARED CI ServiceAccount ----
run kubectl -n "$CI_NAMESPACE" patch serviceaccount apps-ci \
  -p '{"secrets":[{"name":"gitea-git-auth"}]}'

log_info "Tekton pipelines configured in namespace '$CI_NAMESPACE' for: $(app_names | tr '\n' ' ')"
log_info "EventListener service: el-apps.${CI_NAMESPACE}.svc:8080 (the webhook target for EVERY app repo)"
