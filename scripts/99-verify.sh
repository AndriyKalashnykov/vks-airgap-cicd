#!/usr/bin/env bash
# 99-verify.sh — END-TO-END smoke test on the LIVE VKS cluster.
#
# Pushes a uniquely-marked change to javawebapp-app, then verifies the full chain:
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
kubeconfig_ready
: "${GITEA_NAMESPACE:?}"; : "${GITEA_ADMIN_USER:?}"; : "${GITEA_ORG:?}"
: "${APP_BRANCH:?}"; : "${CI_NAMESPACE:?}"; : "${ARGOCD_NAMESPACE:?}"
# Per-app values come from the registry — verify runs the SAME proof for EVERY app.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
READY_TIMEOUT_SECONDS="${VERIFY_READY_TIMEOUT_SECONDS:-600}"
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

# ---- 0. Wait for the EventListener POD to be Ready to receive ----
# The EL pod crash-loops on startup until the Tekton Triggers controller populates the
# clusterInterceptor CaBundle ("empty caBundle in clusterInterceptor spec"); meanwhile the
# EL *resource* already reports Ready=True. A one-shot Gitea webhook pushed during that
# window is LOST -> no PipelineRun. Gate the push on the POD being Ready (it only stays
# Ready once the CaBundle is populated).
log_info "waiting for the EventListener pod to be ready (Tekton Triggers CaBundle race)"
kubectl -n "$CI_NAMESPACE" wait --for=condition=Ready pod -l eventlistener=apps \
  --timeout="${EL_READY_TIMEOUT_SECONDS:-180}s" >/dev/null 2>&1 \
  || log_warn "EventListener pod not confirmed Ready in time — proceeding (the webhook re-fire below covers a lost delivery)"

# ============================================================================================
# verify_app <app> — the FULL proof, for ONE app. Run for EVERY app in apps/registry.tsv.
#
# A green run for javawebapp says NOTHING about gowebapp: each app gets its OWN marker, its OWN
# PipelineRun (matched by the pipeline label, not "some new run appeared"), its OWN deployed-image
# change and its OWN page assertion. If any app fails, `make verify` fails.
# ============================================================================================
verify_app() {
  local app="$1"
  local marker="${MARKER}-${app}"
  local ns="$APP_NAMESPACE" health; health="$(app_health_path "$app")"
  local app_local_port; app_local_port="${APP_LOCAL_PORT:-$(pick_port)}"

  log_info "=== verify [${app}] (lang=${APP_LANG}) ==="

  # Ground truth for "did the new build land": the DEPLOYED IMAGE, not a generic ArgoCD
  # "Synced/Healthy" (auto-sync polls ~3 min, so that can still reflect the pre-write-back
  # revision and race the old pods).
  local pre_img
  pre_img="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

  # Only THIS app's PipelineRuns. Matching "any new PipelineRun" would let the other app's run
  # satisfy this app's check — a green that proves nothing.
  local sel="tekton.dev/pipeline=${app}-ci"
  local before
  before="$(kubectl -n "$CI_NAMESPACE" get pipelineruns -l "$sel" -o name 2>/dev/null | sort || true)"

  # ---- push a marked change to <app>-app -----------------------------------------------------
  log_info "[${app}] port-forwarding Gitea + pushing marked change (${marker})"
  kubectl -n "$GITEA_NAMESPACE" port-forward svc/gitea-http "${GITEA_LOCAL_PORT}:3000" >/dev/null 2>&1 &
  PF_PID=$!
  local base="http://localhost:${GITEA_LOCAL_PORT}"
  wait_for "Gitea reachable" curl -fsS "${base}/api/healthz" || die "Gitea not reachable"

  local gitcreds="${tmp}/gitcreds"
  printf 'http://%s:%s@localhost:%s\n' "$GITEA_ADMIN_USER" "$TOKEN" "$GITEA_LOCAL_PORT" > "$gitcreds"
  local d="${tmp}/src-${app}"
  rm -rf "$d"
  git clone -q "${base}/${GITEA_ORG}/${APP_GIT_REPO}.git" "$d"
  git -C "$d" config credential.helper "store --file=${gitcreds}"
  git -C "$d" config user.email "verify@vks-airgap-cicd.local"
  git -C "$d" config user.name  "vks-airgap-cicd-verify"
  # WHERE the greeting lives is the only language-specific thing here (application.yml vs main.go);
  # lib/apps.sh owns that, so this script has no per-language knowledge.
  app_set_message "$app" "$d" "$marker"
  git -C "$d" commit -aqm "verify: ${marker}"
  git -C "$d" push -q origin "$APP_BRANCH"
  kill "$PF_PID" 2>/dev/null || true; PF_PID=""
  log_info "[${app}] pushed marker to ${APP_GIT_REPO}"

  # ---- wait for THIS app's PipelineRun; re-fire once if the webhook delivery was lost ---------
  local pr="" attempt end now
  for attempt in 1 2; do
    end=$((SECONDS + ${PIPELINERUN_WAIT_SECONDS:-120}))
    while [ "$SECONDS" -lt "$end" ]; do
      now="$(kubectl -n "$CI_NAMESPACE" get pipelineruns -l "$sel" -o name 2>/dev/null | sort || true)"
      pr="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$now") | head -1)"
      [ -n "$pr" ] && break
      sleep "$POLL_INTERVAL_SECONDS"
    done
    [ -n "$pr" ] && break
    [ "$attempt" -ge 2 ] && break
    # Gitea fires the webhook ONCE per push; a delivery that hits the EventListener while it is
    # still stabilizing is lost. Re-fire with an empty commit (the marker is already committed,
    # so the rebuilt image still shows it).
    log_warn "[${app}] no PipelineRun yet — re-firing the Gitea webhook (empty commit)"
    kubectl -n "$GITEA_NAMESPACE" port-forward svc/gitea-http "${GITEA_LOCAL_PORT}:3000" >/dev/null 2>&1 &
    PF_PID=$!
    wait_for "Gitea reachable" curl -fsS "http://localhost:${GITEA_LOCAL_PORT}/api/healthz" || true
    git -C "$d" commit -q --allow-empty -m "verify: re-fire ${marker}" >/dev/null 2>&1 || true
    git -C "$d" push -q origin "$APP_BRANCH" >/dev/null 2>&1 || true
    kill "$PF_PID" 2>/dev/null || true; PF_PID=""
  done
  if [ -z "$pr" ]; then
    # COLLECT THE EVIDENCE BEFORE DYING. This die used to name `kubectl -n ci get el,trigger,pods`
    # — and every object in that list looks HEALTHY when this fails, so it sent the operator to
    # inspect things that are all fine. MEASURED (walk row 2, 2026-08-12): the real cause was a
    # webhook whose HMAC secret had been rotated on one side only, and the rejection is logged by
    # tekton-triggers-core-interceptors — a SEPARATE deployment in a DIFFERENT namespace that this
    # message never mentioned. On a throwaway walkbox that evidence dies with the VM.
    log_error "[${app}] no PipelineRun for ${app}-ci after 2 attempts. Collecting the logs that name the cause:"
    log_error "--- EventListener sink (${CI_NAMESPACE}/el-apps) ---"
    kubectl -n "$CI_NAMESPACE" logs deploy/el-apps --tail=50 2>&1 | sed 's/^/    /' >&2 || true
    log_error "--- Tekton core interceptors (tekton-pipelines) — an HMAC mismatch is logged HERE ---"
    kubectl -n tekton-pipelines logs deploy/tekton-triggers-core-interceptors --tail=50 2>&1 | sed 's/^/    /' >&2 || true
    die "[${app}] no PipelineRun for ${app}-ci after 2 attempts.
  If the interceptor log above shows a signature/HMAC failure, Gitea's webhook secret and the
  ${CI_NAMESPACE}/gitea-webhook-secret Secret have diverged — re-run 'make seed-gitea', which now
  rewrites the hook (Gitea cannot patch a webhook secret, so it is deleted and recreated).
  If it shows nothing at all, the delivery never arrived: check the hook in Gitea itself."
  fi
  log_info "[${app}] PipelineRun: $pr"

  if ! kubectl -n "$CI_NAMESPACE" wait --for=condition=Succeeded --timeout="${READY_TIMEOUT_SECONDS}s" "$pr"; then
    log_error "[${app}] PipelineRun did not succeed — diagnostics:"
    kubectl -n "$CI_NAMESPACE" get "$pr" -o wide >&2 || true
    kubectl -n "$CI_NAMESPACE" get taskruns -l "$sel" >&2 || true
    die "[${app}] pipeline failed"
  fi
  log_info "[${app}] PipelineRun succeeded"

  # ---- INSTRUMENT: split scheduling+image-pull from actual build time ------------------------
  # WHY THIS EXISTS. Across the archived matrix rows in ~/walk-evidence/, rustwebapp's PipelineRun
  # interval is BIMODAL by roughly 4x while every other app's is tight. The archive cannot say why:
  # `grep -c FailedScheduling` over every archived row log is ZERO, because diagnostics are dumped
  # only on the FAILURE path above -- a run that is 4x slow but SUCCEEDS emits two INFO lines and
  # nothing else. The slow runs are unattributable BY CONSTRUCTION, and the slow mode consumes ~71%
  # of READY_TIMEOUT_SECONDS, so this is not a curiosity.
  #   reproduce the distribution:  grep -h 'PipelineRun succeeded' ~/walk-evidence/*/MATRIX-row*.log
  # (Deliberately NO frozen per-app second-ranges here: they rot as apps and builders change, which
  # is the same trap CLAUDE.md records for the matrix duration figures.)
  #
  # A TaskRun's .status.startTime versus its first step's .terminated.startedAt IS the discriminator:
  #   gap large, step small  -> scheduling / image-pull  (node pressure, affinity, registry latency)
  #   gap ~0,    step large  -> the BUILD did more work  (e.g. a cold cargo cache)
  #
  # ⚠️ SELECTED BY pipelineRun, NOT pipeline. $sel is `tekton.dev/pipeline=<app>-ci`, which matches
  # EVERY run of that pipeline -- and nothing prunes TaskRuns, so archived rows routinely hold two
  # runs of one app. Timing rows from an older (possibly fast) run, carrying absolute timestamps,
  # are worse than none: a reader computing a delta off the wrong row gets a real, wrong number.
  #
  # ⚠️ The KEYS ARE INSIDE the jsonpath, so the output carries no positional meaning and no field
  # can shift. That is why there is no `while IFS=... read` here and no delimiter to reason about.
  #
  # ⚠️ NO `date -d` ARITHMETIC. The walk box is Photon (toybox) as often as Ubuntu (GNU). Raw
  # timestamps are portable; a wrong delta would be worse than two honest timestamps.
  #
  # Rows print in NAME order, not execution order (build, clone-app, deploy-update, test) -- each
  # row carries its own timestamps, so read those, not the order.
  _pr_name="${pr##*/}"
  _timing="$(kubectl -n "$CI_NAMESPACE" get taskruns -l "tekton.dev/pipelineRun=${_pr_name}" \
    -o jsonpath='{range .items[*]}{.metadata.name} sched={.status.startTime} step0={.status.steps[0].terminated.startedAt} done={.status.completionTime}{"\n"}{end}' \
    2>/dev/null || true)"
  # A COUNT, always. Silence has five indistinguishable causes (no TaskRuns matched, RBAC denied,
  # CRD not served, jsonpath errored, kubectl absent) -- and printing nothing would reproduce the
  # exact defect this block exists to fix. 0 is a legitimate, informative answer.
  log_info "  timing[${app}] $(printf '%s' "$_timing" | grep -c . || true) TaskRun(s) for ${_pr_name}"
  # if/then, not `A && B || C`: the || arm runs when A is TRUE and B fails, which is the shape this
  # repo has repeatedly recorded as a fake-green. Here C is `true` so it is harmless, but the shape
  # is not worth keeping — and the block must still never be able to fail the run.
  if [ -n "$_timing" ]; then
    printf '%s\n' "$_timing" | sed "s|^|    timing[${app}] |" >&2 || true
  fi

  # ---- ArgoCD: force the write-back to reconcile NOW, then wait for the image to CHANGE -------
  # ⚠️ --kubeconfig "$ARGOCD_KUBECONFIG", NOT the ambient one. ArgoCD's Applications live on the
  # cluster ARGOCD runs in, which on a real lab is the SUPERVISOR while $KUBECONFIG is the GUEST.
  # MEASURED 2026-08-08: without this the annotate silently no-opped (it is `|| true`) so ArgoCD was
  # never nudged, and the diagnostic below printed `error: the server doesn't have a resource type
  # "application"` — the guest has no ArgoCD CRDs at all. On KinD the two are the same file, which
  # is why this survived: the bug is invisible in the only topology the local e2e exercises.
  # ⚠️ The rc is CAPTURED, and stderr goes to its OWN FILE -- never `2>&1`. os.sh:1836 states the
  # rule and why: merging the streams makes the capture non-empty, which inverts any emptiness test
  # downstream. Capturing rc alone would recover "did it fail" and throw away "why", and kubectl
  # exits 1 for Forbidden, NotFound, no-such-resource and connection-refused alike -- so rc
  # discriminates almost nothing. classify_kube_failure (os.sh) is already in scope via lib/os.sh.
  #
  # THE CAUSE IS MEASURED, NOT GUESSED. lib/argocd.sh:645-657 already fixed this exact annotate and
  # records it: with a get-but-not-patch tenant RBAC -- the scenario-2 shape -- the annotate returns
  # Forbidden. Scenario-2 is also where this wait is slow in the archive. So the first thing to
  # suspect is an RBAC grant the tenant CANNOT self-service (RULE ZERO-B), not a kubeconfig typo.
  #
  # NON-FATAL, deliberately, and this is where it differs from lib/argocd.sh. There the annotate
  # gates a reachability CLAIM, so failing it must die rather than report a result it did not
  # obtain. Here it only makes the wait below slower: ArgoCD still reconciles on its own timer.
  # Making it fatal would convert a slow row into a failed one.
  local _refresh_rc=0 _refresh_err
  _refresh_err="$(mktemp)"
  kubectl --kubeconfig "${ARGOCD_KUBECONFIG:-$KUBECONFIG}" -n "$ARGOCD_NAMESPACE" \
    annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>"$_refresh_err" || _refresh_rc=$?
  if [ "$_refresh_rc" -ne 0 ]; then
    log_warn "[${app}] ArgoCD refresh nudge FAILED (rc=${_refresh_rc}, $(classify_kube_failure "$_refresh_err")) — the"
    log_warn "  wait below falls back to ArgoCD's own reconcile timer, so expect SLOW, not broken."
    log_warn "  (that timer is argocd-cm's timeout.reconciliation; this repo overrides it NOWHERE, so"
    log_warn "   its default applies here — but a platform team's lab may have changed it.)"
    log_warn "  kubectl said:"
    sed 's/^/    /' "$_refresh_err" >&2 2>/dev/null || true
    log_warn "  A tenant with get-but-not-patch on applications hits exactly this — an RBAC fault, not"
    log_warn "  a kubeconfig fault, and not one a tenant can self-service. See lib/argocd.sh:645."
  fi
  rm -f "$_refresh_err"
  if ! wait_for "[${app}] ArgoCD rolls a new image (was ${pre_img:-none})" \
       sh -c "[ \"\$(kubectl -n $ns get deploy $app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)\" != '${pre_img}' ]"; then
    log_error "[${app}] ArgoCD did not roll a new image (still ${pre_img:-none})"
    kubectl --kubeconfig "${ARGOCD_KUBECONFIG:-$KUBECONFIG}" -n "$ARGOCD_NAMESPACE" \
      get application "$app" -o wide >&2 || true
    die "[${app}] ArgoCD did not converge on the new build"
  fi
  local img; img="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  log_info "[${app}] deployed image now ${img}"

  # ---- THE USER-FACING END RESULT: the running page shows THIS app's marker -------------------
  wait_for "[${app}] new rollout complete" kubectl -n "$ns" rollout status "deploy/${app}" --timeout=30s
  kubectl -n "$ns" port-forward "svc/${app}" "${app_local_port}:80" >/dev/null 2>&1 &
  PF_PID=$!
  local url="http://localhost:${app_local_port}"
  wait_for "[${app}] app HTTP up" curl -fsS "${url}${health}" || die "[${app}] app not serving ${health}"

  # Capture the page, THEN grep the variable: `curl | grep -q` lets grep close the pipe on its
  # first match and SIGPIPE curl (141), which under `set -o pipefail` reads as "marker absent" —
  # a false failure on a page that DID show it.
  # shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
  marker_visible() { local b; b="$(curl -fsS "${url}/" 2>/dev/null || true)"; grep -q "$marker" <<< "$b"; }
  if wait_for "[${app}] deployed page shows marker ${marker}" marker_visible; then
    log_info "[${app}] SUCCESS — the deployed page shows '${marker}'"
  else
    log_error "[${app}] app is up but the page does NOT show '${marker}' (deployed image: ${img})"
    curl -fsS "${url}/" | grep -i 'class="message"' >&2 || true
    die "[${app}] end result not observed"
  fi
  kill "$PF_PID" 2>/dev/null || true; PF_PID=""
}

for_each_app verify_app

log_info "End-to-end verified for EVERY app ($(app_names | tr '\n' ' ')): git push -> Tekton -> Harbor -> write-back -> ArgoCD -> live page."
