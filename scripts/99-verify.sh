#!/usr/bin/env bash
# 99-verify.sh — END-TO-END smoke test on the LIVE VKS cluster.
#
# Pushes a uniquely-marked change to webui-app, then verifies the full chain:
#   push -> Tekton PipelineRun succeeds -> deploy repo tag bumped
#        -> ArgoCD Synced/Healthy -> the app HTTP page shows the new marker.
#
# This REQUIRES a working cluster (make vks-login) with the platform installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl; require_cmd git; require_cmd curl
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${GITEA_NAMESPACE:?}"; : "${GITEA_ADMIN_USER:?}"; : "${GITEA_ORG:?}"; : "${GITEA_APP_REPO:?}"
: "${APP_BRANCH:?}"; : "${CI_NAMESPACE:?}"; : "${ARGOCD_NAMESPACE:?}"; : "${ARGOCD_APP_NAME:?}"
: "${ARGOCD_DEST_NAMESPACE:?}"; : "${APP_NAME:?}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-600}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
GITEA_LOCAL_PORT="${GITEA_LOCAL_PORT:-3000}"
APP_LOCAL_PORT="${APP_LOCAL_PORT:-18080}"

TOKEN_FILE="${REPO_ROOT}/secrets/gitea-ci-token"
[ -s "$TOKEN_FILE" ] || die "missing $TOKEN_FILE — run 'make seed-gitea' first"
TOKEN="$(cat "$TOKEN_FILE")"
MARKER="vks-cicd-verify-$(date +%s)"

tmp="$(mktemp -d)"; PF_PID=""
cleanup() { if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi; rm -rf "$tmp"; }
trap cleanup EXIT
umask 077

wait_for() { # wait_for <desc> <cmd...> ; polls until cmd succeeds or timeout
  local desc="$1"; shift; local end=$((SECONDS + READY_TIMEOUT_SECONDS))
  log_info "waiting: $desc"
  while [ "$SECONDS" -lt "$end" ]; do "$@" >/dev/null 2>&1 && return 0; sleep "$POLL_INTERVAL_SECONDS"; done
  return 1
}

# ---- 1. Record existing PipelineRuns, then push a marked change ----
before="$(kubectl -n "$CI_NAMESPACE" get pipelineruns -o name 2>/dev/null | sort || true)"

log_info "port-forwarding Gitea + pushing marked change ($MARKER)"
kubectl -n "$GITEA_NAMESPACE" port-forward svc/gitea-http "${GITEA_LOCAL_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
base="http://localhost:${GITEA_LOCAL_PORT}"
wait_for "Gitea reachable" curl -fsS "${base}/api/healthz" || die "Gitea not reachable"

gitcreds="${tmp}/gitcreds"
printf 'http://%s:%s@localhost:%s\n' "$GITEA_ADMIN_USER" "$TOKEN" "$GITEA_LOCAL_PORT" > "$gitcreds"
d="${tmp}/app"
git clone -q "${base}/${GITEA_ORG}/${GITEA_APP_REPO}.git" "$d"
git -C "$d" config credential.helper "store --file=${gitcreds}"
git -C "$d" config user.email "verify@vks-cicd.local"
git -C "$d" config user.name  "vks-cicd-verify"
# Change the greeting default so the rebuilt image visibly shows the marker.
sed -i "s#\${APP_MESSAGE:[^}]*}#\${APP_MESSAGE:${MARKER}}#" \
  "$d/src/main/resources/application.yml"
git -C "$d" commit -aqm "verify: ${MARKER}"
git -C "$d" push -q origin "$APP_BRANCH"
kill "$PF_PID" 2>/dev/null || true; PF_PID=""
log_info "pushed marker $MARKER to ${GITEA_APP_REPO}"

# ---- 2. Wait for a NEW PipelineRun and its success ----
log_info "waiting for the webhook-triggered PipelineRun"
pr=""
end=$((SECONDS + 120))
while [ "$SECONDS" -lt "$end" ]; do
  now="$(kubectl -n "$CI_NAMESPACE" get pipelineruns -o name 2>/dev/null | sort || true)"
  pr="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$now") | head -1)"
  [ -n "$pr" ] && break
  sleep "$POLL_INTERVAL_SECONDS"
done
[ -n "$pr" ] || die "no new PipelineRun appeared — check the Gitea webhook + EventListener (kubectl -n $CI_NAMESPACE get el,pods)"
log_info "PipelineRun: $pr"

if ! kubectl -n "$CI_NAMESPACE" wait --for=condition=Succeeded --timeout="${READY_TIMEOUT_SECONDS}s" "$pr"; then
  log_error "PipelineRun did not succeed — diagnostics:"
  kubectl -n "$CI_NAMESPACE" get "$pr" -o wide >&2 || true
  kubectl -n "$CI_NAMESPACE" get taskruns >&2 || true
  die "pipeline failed"
fi
log_info "PipelineRun succeeded"

# ---- 3. Wait for ArgoCD Synced + Healthy ----
argo_status() {
  kubectl -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null
}
if ! wait_for "ArgoCD Synced/Healthy" sh -c "[ \"\$(kubectl -n $ARGOCD_NAMESPACE get application $ARGOCD_APP_NAME -o jsonpath='{.status.sync.status}/{.status.health.status}')\" = 'Synced/Healthy' ]"; then
  log_error "ArgoCD not Synced/Healthy (got: $(argo_status))"
  kubectl -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" -o wide >&2 || true
  die "ArgoCD did not converge"
fi
log_info "ArgoCD: $(argo_status)"

# ---- 4. Verify the running app serves the new marker (the USER-FACING result) ----
wait_for "app deployment available" kubectl -n "$ARGOCD_DEST_NAMESPACE" rollout status "deploy/${APP_NAME}" --timeout=30s
# Diagnostic: log the deployed image tag so a "marker missing" failure below is
# localized to build/push+write-back vs ArgoCD-sync (i.e. did the new image tag
# actually reach the running Deployment) rather than just "end result not observed".
deployed_img="$(kubectl -n "$ARGOCD_DEST_NAMESPACE" get deploy "$APP_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
log_info "deployed image: ${deployed_img:-<unknown>}"
kubectl -n "$ARGOCD_DEST_NAMESPACE" port-forward "svc/${APP_NAME}" "${APP_LOCAL_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
app="http://localhost:${APP_LOCAL_PORT}"
wait_for "app HTTP up" curl -fsS "${app}/actuator/health" || die "app not serving"

if curl -fsS "${app}/" | grep -q "$MARKER"; then
  log_info "SUCCESS — the deployed page shows the new marker '$MARKER'"
  log_info "End-to-end verified: git push -> Tekton -> Harbor -> write-back -> ArgoCD -> live app."
else
  log_error "app is up but the page does NOT show marker '$MARKER' (deployed an older image?)"
  curl -fsS "${app}/" | grep -i 'class=\"message\"' >&2 || true
  die "end result not observed"
fi
