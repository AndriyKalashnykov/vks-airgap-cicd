#!/usr/bin/env bash
# build every app's image through the REAL pipeline, then wait for its PipelineRun to SUCCEED.
# It does NOT wait for the pod: ArgoCD rolls on its own reconcile timer, and `make verify` is
# the live assertion. MEASURED 2026-09-07: the word RUNNING appeared ONLY on this line and
# nowhere in the code — a claim the file made about itself and did not keep.
#
# WHY THIS EXISTS. `make install-all` advertised "the complete air-gap install end to end" and
# ALWAYS finished with every app in ImagePullBackOff. MEASURED: after install-all, ArgoCD holds one
# Application per app pointing at harbor/<project>/<app>:<tag>, the Harbor apps project holds ZERO
# repositories, and every app host answers 503. Nothing in install-all builds an app image — only
# the Tekton pipeline does, and only a git push triggers it. `gitops` waits for each Application to
# FETCH A REVISION (70-configure-argocd.sh:889), which proves ArgoCD can clone the repo and says
# nothing about pod health, which is why install-all exited 0 on a demo that did not work.
#
# ⚠️ THIS TRIGGERS THE REAL PIPELINE, IT DOES NOT BUILD LOCALLY. That is the point: a local build
# would prove nothing about the in-cluster air-gapped path (the mirrored builder, the Harbor push,
# the write-back, the ArgoCD sync). It pushes an EMPTY COMMIT to <app>-app, which is exactly what a
# developer does, and lets the existing webhook do the rest.
#
# IDEMPOTENT. Re-running must not rebuild what Harbor already holds: for each app it asks Harbor
# whether an artifact tagged with the app repo's CURRENT HEAD sha exists, and skips if so. That
# predicate is the artifact itself, not a local marker file — `secrets/` survives a lab re-cut while
# each cut mints a fresh Harbor, so any local sentinel would lie (CLAUDE.md records exactly that).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

load_env
: "${CI_NAMESPACE:?}"; : "${GITEA_NAMESPACE:?}"; : "${GITEA_ORG:?}"; : "${GITEA_ADMIN_USER:?}"
: "${HARBOR_APP_PROJECT:?}"; : "${APP_BRANCH:?}"

# How long to wait for ONE app's PipelineRun to finish. A cold builder pull plus a real compile is
# minutes, not seconds; the default is generous because the failure mode of being too short is a
# FALSE RED on a working pipeline.
BUILD_APPS_TIMEOUT_SECONDS="${BUILD_APPS_TIMEOUT_SECONDS:-900}"
BUILD_APPS_POLL_SECONDS="${BUILD_APPS_POLL_SECONDS:-10}"
# Set to 1 to rebuild even when Harbor already holds the artifact (the idempotency escape hatch).
BUILD_APPS_FORCE="${BUILD_APPS_FORCE:-0}"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
harbor_setup "$HARBOR_TMP"

GITEA_LOCAL_PORT="${GITEA_LOCAL_PORT:-$(pick_port)}"
kubectl -n "$GITEA_NAMESPACE" port-forward svc/gitea-http "${GITEA_LOCAL_PORT}:3000" >/dev/null 2>&1 &
PF_PID=$!
# shellcheck disable=SC2064  # expand PF_PID now: it must not be re-read at trap time
trap "kill ${PF_PID} 2>/dev/null || true; rm -rf '${HARBOR_TMP}'" EXIT
BASE="http://localhost:${GITEA_LOCAL_PORT}"
for _ in $(seq 1 60); do curl -fsS "${BASE}/api/healthz" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "${BASE}/api/healthz" >/dev/null 2>&1 || die "Gitea is not reachable on ${BASE} — is the platform installed? (make platform)"

TOKEN_FILE="${REPO_ROOT}/secrets/gitea-ci-token"
[ -f "$TOKEN_FILE" ] || die "no ${TOKEN_FILE}: run 'make seed-gitea' first (it mints the CI token)."
TOKEN="$(cat "$TOKEN_FILE")"
GITCREDS="${HARBOR_TMP}/gitcreds"
( umask 077; printf 'http://%s:%s@localhost:%s\n' "$GITEA_ADMIN_USER" "$TOKEN" "$GITEA_LOCAL_PORT" > "$GITCREDS" )

# harbor_has_tag <app> <tag> — is that artifact ALREADY in Harbor? The idempotency predicate.
# ⚠️ Reads the ARTIFACT, never a local file. A 404 (repo absent) is a clean "no", not an error.
harbor_has_tag() {
  local app="$1" tag="$2" body
  body="$(harbor_api_body GET "projects/${HARBOR_APP_PROJECT}/repositories/${app}/artifacts?page_size=100&with_tag=true" 2>/dev/null || true)"
  case "$(harbor_last_code)" in
    200) : ;;
    404) return 1 ;;                     # the repo does not exist yet -> nothing built
    *)   return 1 ;;                     # could not tell -> build (fail toward doing the work)
  esac
  printf '%s' "$body" | jq -e --arg t "$tag" '[.[]?|.tags[]?.name] | index($t) != null' >/dev/null 2>&1
}

built=0; skipped=0; failed=0
build_app() {
  local app="$1" d sha pr rc elapsed
  d="${HARBOR_TMP}/src-${app}"
  rm -rf "$d"
  git clone -q "${BASE}/${GITEA_ORG}/${APP_GIT_REPO}.git" "$d" 2>/dev/null \
    || { log_error "[${app}] cannot clone ${APP_GIT_REPO} — run 'make seed-gitea'"; failed=$((failed+1)); return; }
  sha="$(git -C "$d" rev-parse --short HEAD)"

  # ⚠️ THE PREDICATE IS THE DEPLOYED STATE, NOT A MID-PIPELINE ARTIFACT. "Harbor holds the sha"
  # was sufficient while the DEPLOYED tag WAS the sha; it is not any more. deploy-update runs
  # AFTER build, and it has three `exit 1` paths — so a run can push both image tags and then fail
  # the write-back, leaving <app>-deploy still on the NEVER-BUILT placeholder. A sha-only predicate
  # then SKIPS every retry and this script reports "Every app's image is in Harbor" while the pods
  # sit in ImagePullBackOff: precisely the false-green its own header says it exists to end.
  # So: skip only when the DEPLOY REPO names a real tag AND Harbor actually holds that tag.
  local dd deployed_tag=""
  dd="${HARBOR_TMP}/deploy-${app}"
  rm -rf "$dd"
  if git clone -q --depth 1 "${BASE}/${GITEA_ORG}/${APP_DEPLOY_REPO}.git" "$dd" 2>/dev/null; then
    deployed_tag="$(yq -r '.images[0].newTag // ""' "${dd}/kustomization.yaml" 2>/dev/null || true)"
  fi
  case "$deployed_tag" in
    ''|NEVER-BUILT-*|null) deployed_tag="" ;;   # never written back -> must build
  esac
  if [ "$BUILD_APPS_FORCE" != 1 ] && [ -n "$deployed_tag" ] \
     && harbor_has_tag "$app" "$sha" && harbor_has_tag "$app" "$deployed_tag"; then
    log_info "[${app}] SKIP — ${APP_DEPLOY_REPO} deploys ${APP_IMAGE}:${deployed_tag} and Harbor holds it (+ ${sha})"
    skipped=$((skipped+1)); return
  fi

  # ⚠️ SNAPSHOT THE NEWEST EXISTING RUN *BEFORE* THE PUSH. Selecting "the newest PipelineRun for
  # this app" AFTER the push returns whatever already existed — and on a lab where the app was built
  # minutes ago that run is already Succeeded, so the wait returns INSTANTLY and reports a build that
  # never happened. MEASURED: my first version reported built=6 in 24 SECONDS for six apps whose
  # builds take 3-4 minutes each. The app-identity guard is necessary and NOT sufficient; recency is
  # the other half, and 99-verify.sh's own comment warns about exactly this shape.
  local before
  before="$(kubectl -n "$CI_NAMESPACE" get pipelinerun -l "tekton.dev/pipeline=${app}-ci" \
              --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1 || true)"

  git -C "$d" config credential.helper "store --file=${GITCREDS}"
  git -C "$d" config user.email "build-apps@vks-airgap-cicd.local"
  git -C "$d" config user.name  "vks-airgap-cicd-build"
  # An EMPTY commit: the source is already what the operator wants built. This is the documented
  # developer action (a push), so it exercises the webhook -> EventListener -> PipelineRun path
  # rather than creating a PipelineRun behind the demo's back.
  git -C "$d" commit -q --allow-empty -m "build: install-all requested a build of ${app}"
  git -C "$d" push -q origin "$APP_BRANCH"
  sha="$(git -C "$d" rev-parse --short HEAD)"
  log_info "[${app}] pushed ${sha} to ${APP_GIT_REPO} — waiting for its PipelineRun"

  # Wait for a PipelineRun for THIS app that started after the push. Selecting by the app's own
  # pipeline label matters: matching "any new PipelineRun" would let a sibling app's run satisfy
  # this check — a green that proves nothing.
  elapsed=0; pr=""
  while [ "$elapsed" -lt "$BUILD_APPS_TIMEOUT_SECONDS" ]; do
    pr="$(kubectl -n "$CI_NAMESPACE" get pipelinerun \
            -l "tekton.dev/pipeline=${app}-ci" \
            --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1 || true)"
    # A NEW one, not the one that was already there. Without this the loop exits on the pre-existing
    # run and the "Succeeded" below is about a build from before this push.
    [ -n "$pr" ] && [ "$pr" != "$before" ] && break
    pr=""
    sleep "$BUILD_APPS_POLL_SECONDS"; elapsed=$((elapsed + BUILD_APPS_POLL_SECONDS))
  done
  [ -n "$pr" ] || { log_error "[${app}] no PipelineRun appeared in ${BUILD_APPS_TIMEOUT_SECONDS}s — is the webhook registered? (make seed-gitea)"; failed=$((failed+1)); return; }

  while [ "$elapsed" -lt "$BUILD_APPS_TIMEOUT_SECONDS" ]; do
    rc="$(kubectl -n "$CI_NAMESPACE" get "$pr" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)"
    case "$rc" in
      Succeeded) log_info "[${app}] ${pr#*/} Succeeded"; built=$((built+1)); return ;;
      Failed|CouldntGetTask|PipelineRunTimeout|Cancelled)
        log_error "[${app}] ${pr#*/} ${rc} — kubectl -n ${CI_NAMESPACE} describe ${pr}"
        failed=$((failed+1)); return ;;
    esac
    sleep "$BUILD_APPS_POLL_SECONDS"; elapsed=$((elapsed + BUILD_APPS_POLL_SECONDS))
  done
  log_error "[${app}] ${pr#*/} still running after ${BUILD_APPS_TIMEOUT_SECONDS}s (BUILD_APPS_TIMEOUT_SECONDS)"
  failed=$((failed+1))
}
for_each_app build_app

log_info "build-apps: built=${built} skipped=${skipped} failed=${failed} (of $(app_names | grep -c .) app(s))"
[ "$failed" -eq 0 ] || die "build-apps: ${failed} app(s) did not build — the demo will show ImagePullBackOff for them."
log_info "Every app's image is in Harbor. ArgoCD rolls each one on its next reconcile"
log_info "  (timeout.reconciliation, 180s by default) — 'make verify' asserts the live pages."
