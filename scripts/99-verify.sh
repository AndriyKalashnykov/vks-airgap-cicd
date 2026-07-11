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
# LOCAL port-forward aliases — ephemeral by default (pick_port) so parallel runs
# never collide; an operator can still pin them via the env vars.
GITEA_LOCAL_PORT="${GITEA_LOCAL_PORT:-$(pick_port)}"
APP_LOCAL_PORT="${APP_LOCAL_PORT:-$(pick_port)}"

TOKEN_FILE="${REPO_ROOT}/secrets/gitea-ci-token"
[ -s "$TOKEN_FILE" ] || die "missing $TOKEN_FILE — run 'make seed-gitea' first"
TOKEN="$(cat "$TOKEN_FILE")"
MARKER="vks-airgap-cicd-verify-$(date +%s)"

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
# Capture the currently-deployed image so step 3 can wait for it to CHANGE. A
# generic ArgoCD "Synced/Healthy" reflects the PRE-write-back revision (auto-sync
# polls every ~3 min), so waiting on that alone races the old pods — the deployed
# image, not the sync status, is the ground truth that the new build landed.
pre_img="$(kubectl -n "$ARGOCD_DEST_NAMESPACE" get deploy "$APP_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

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
git -C "$d" config user.email "verify@vks-airgap-cicd.local"
git -C "$d" config user.name  "vks-airgap-cicd-verify"
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

# ---- 3. Force ArgoCD to pick up the write-back NOW, then wait for the NEW image ----
argo_status() {
  kubectl -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null
}
deploy_img() {
  kubectl -n "$ARGOCD_DEST_NAMESPACE" get deploy "$APP_NAME" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
}
# Hard-refresh so ArgoCD reconciles the write-back commit immediately instead of
# waiting out its ~3 min auto-sync poll.
kubectl -n "$ARGOCD_NAMESPACE" annotate application "$ARGOCD_APP_NAME" \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
# Ground truth = the deployed image actually CHANGED (not a generic "Synced/Healthy",
# which can still reflect the pre-write-back revision mid-poll and race the old pods).
if ! wait_for "ArgoCD rolls a new image (was ${pre_img:-none})" \
     sh -c "[ \"\$(kubectl -n $ARGOCD_DEST_NAMESPACE get deploy $APP_NAME -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)\" != '${pre_img}' ]"; then
  log_error "ArgoCD did not roll a new image (still ${pre_img:-none}); status: $(argo_status)"
  kubectl -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" -o wide >&2 || true
  die "ArgoCD did not converge on the new build"
fi
log_info "ArgoCD: $(argo_status) — deployed image now $(deploy_img)"

# ---- 4. Verify the running app serves the new marker (the USER-FACING result) ----
# Wait for the NEW ReplicaSet to fully roll out before port-forwarding, so the
# forward lands on a new pod (not one being torn down).
wait_for "new app rollout complete" kubectl -n "$ARGOCD_DEST_NAMESPACE" rollout status "deploy/${APP_NAME}" --timeout=30s
log_info "deployed image: $(deploy_img)"
kubectl -n "$ARGOCD_DEST_NAMESPACE" port-forward "svc/${APP_NAME}" "${APP_LOCAL_PORT}:80" >/dev/null 2>&1 &
PF_PID=$!
app="http://localhost:${APP_LOCAL_PORT}"
wait_for "app HTTP up" curl -fsS "${app}/actuator/health" || die "app not serving"

# Poll (not single-shot): the Service briefly load-balances across old+new pods
# during rollout, so the marker may take a few polls to appear on every replica.
# Capture the page first, then grep the variable: piping `curl … | grep -q` lets grep exit on
# its first match and SIGPIPE `curl` (exit 141) while it is still streaming the body, which under
# `set -o pipefail` reads as "marker absent" → a false "end result not observed" on a page that
# DID show the marker. `|| true` preserves the original semantics (a curl HTTP error → not visible).
marker_visible() { local b; b="$(curl -fsS "${app}/" 2>/dev/null || true)"; printf '%s' "$b" | grep -q "$MARKER"; }
if wait_for "deployed page shows marker $MARKER" marker_visible; then
  log_info "SUCCESS — the deployed page shows the new marker '$MARKER'"
  log_info "End-to-end verified: git push -> Tekton -> Harbor -> write-back -> ArgoCD -> live app."
else
  log_error "app is up but the page does NOT show marker '$MARKER' (deployed image: $(deploy_img))"
  curl -fsS "${app}/" | grep -i 'class=\"message\"' >&2 || true
  die "end result not observed"
fi
