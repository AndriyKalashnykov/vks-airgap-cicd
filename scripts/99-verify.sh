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
# APP_LOCAL_PORT is deliberately NOT resolved here. Each app now picks its own free port at the
# moment it binds (see verify_app), so a single global would put all six on one port -- which is
# what it did, and how a slow port release from app N surfaced as "app N+1 not serving /healthz".
# An operator who sets it still wins, at the point of use, for a single-app debug run.

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
  # ⚠️ A PORT PER APP. This used to read `${APP_LOCAL_PORT:-$(pick_port)}` while line 28 set
  # APP_LOCAL_PORT unconditionally -- so the fallback was DEAD and all six apps shared ONE local
  # port. The six verifies run in sequence; if app N's port has not been released when app N+1
  # binds, the new port-forward exits silently (output -> /dev/null) and the HTTP-up check dies with
  # "app not serving /healthz" -- another wrong cause. Line 28 no longer resolves it; the operator's
  # value, if any, is honoured at the point of use below.
  local app_local_port=""

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
  # The FULL sha of the commit we just pushed. The deployed image tag is the app repo's
  # `git rev-parse --short HEAD` (k8s/tekton/tasks/git-clone.yaml:40 -> results.commit ->
  # kaniko --destination=$(params.image):$(params.tag) -> update-deploy.yaml newTag), so the tag is
  # an ABBREVIATION of this. Full sha + prefix test, never equality: `--short` length is not fixed
  # (git widens it as a repo grows, and core.abbrev may differ between this clone and Tekton's), so
  # an equality test against our own --short output would be comparing two independently-chosen
  # abbreviation lengths.
  local marker_sha; marker_sha="$(git -C "$d" rev-parse HEAD)"
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
    # RE-CAPTURE THE SHA. The re-fire COMMITS (--allow-empty above), so HEAD MOVED, and the
    # pipeline it triggers builds the NEW sha. The image-attribution wait below tests the
    # deployed tag against marker_sha, so leaving it at the pre-re-fire value makes that wait
    # PERMANENTLY UNSATISFIABLE -- it would burn the full readiness timeout and die, on
    # exactly the run the old "!= pre_img" test recovered from. Adversary-caught and
    # RED-proven against a real re-fire commit (marker 13ddaa7..., re-fire tag fcfcd18 ->
    # NO MATCH). Measured: 0 re-fires in 341 archived verify attempts, so this is latent,
    # which is precisely why no test or run would have found it.
    marker_sha="$(git -C "$d" rev-parse HEAD)"
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
  # ASSERT THE IMAGE IS *THIS MARKER'S* BUILD -- not merely that it CHANGED.
  #
  # MEASURED 2026-08-27 (run 8): this used to test `!= $pre_img`, and that is satisfied by ANY image
  # change, including one from an unrelated pipeline. pythonwebapp had TWO PipelineRuns in flight --
  # ci-v8lx9 (14:06:20-14:06:54, triggered BEFORE the marker push at 14:10:00) and ci-5l22n
  # (14:10:02-14:10:28, the marker's own build). The stray earlier run's tag write-back rolled the
  # image before this wait even started, so it was satisfied with 0s delay where every other app
  # took +5s. verify then polled for the marker in the WRONG image for ten minutes and died
  # "end result not observed" -- an error naming the page, about a page that was never going to
  # contain it. The image was real, the rollout was real, the build was somebody else's.
  #
  # A prefix test, not equality: the tag is an abbreviation whose length neither side pins.
  # shellcheck disable=SC2329  # invoked indirectly (wait_for), same as _all_pods_on_img below
  _img_is_marker_build() {
    local cur tag
    cur="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" || return 1
    tag="${cur##*:}"
    # A digest-pinned ref has no usable tag; a bare repo name leaves tag == cur. Both mean "cannot
    # attribute this image to a commit", which must NOT read as success.
    case "$cur" in *@sha256:*) return 1 ;; esac
    [ -n "$tag" ] && [ "$tag" != "$cur" ] || return 1
    # tag must be a PREFIX of the full sha (and non-trivially long, so a stray ":v1" cannot match).
    [ "${#tag}" -ge 7 ] && [ "${marker_sha#"$tag"}" != "$marker_sha" ]
  }
  if ! wait_for "[${app}] ArgoCD rolls THIS marker's build (${marker_sha:0:7}, was ${pre_img:-none})" \
       _img_is_marker_build; then
    log_error "[${app}] ArgoCD did not converge on the build of ${marker_sha:0:7}"
    log_error "  deployed now: $(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    log_error "  If that names a DIFFERENT sha, an unrelated PipelineRun's write-back won the race;"
    log_error "  this app's own build either has not finished or never wrote its tag back."
    kubectl --kubeconfig "${ARGOCD_KUBECONFIG:-$KUBECONFIG}" -n "$ARGOCD_NAMESPACE" \
      get application "$app" -o wide >&2 || true
    die "[${app}] ArgoCD did not converge on the new build"
  fi
  local img; img="$(kubectl -n "$ns" get deploy "$app" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  log_info "[${app}] deployed image now ${img}"

  # ---- THE USER-FACING END RESULT: the running page shows THIS app's marker -------------------
  # ⚠️ THE TUNNEL CAN BIND A DOOMED POD -- a NARROW RACE, not a certainty. `kubectl port-forward
  # svc/X` selects ONE pod and does not follow endpoints; kubectl's own help says "The forwarding
  # session ends when the selected pod terminates". Every app here is `replicas: 2` with NO
  # `strategy:` block (6/6, deploy/*/deployment.yaml:9), so the default RollingUpdate terminates old
  # pods during the rollout `verify` has just triggered -- and if the forward happens to bind one of
  # those, the session ends and every later curl fails.
  # MEASURED over the whole walk archive: 237 app-verify attempts across 49 rows, ONE failure of
  # this shape (0.42%), first seen 2026-08-26. So it binds a survivor ~236 times out of 237; this is
  # a race with a small window, NOT something that happens every rollout. Do not read the numbers as
  # "broken" -- read them as "unbounded exposure that finally hit". Across a 36-app-verify matrix,
  # 1-(1-0.0042)^36 ~= 14% of runs lose a row to it.
  # ⚠️ NOT diagnostic on its own: the `rollout complete -> app HTTP up` gap was <=1s in 94 of those
  # 237 attempts (40%), so an "instant" rollout status is the NORMAL case, not a symptom.
  # It cost row 4 of the 3.7.1 certification, and the harness blamed the PAGE:
  #   00:46:53 FATAL [rustwebapp] end result not observed
  #   00:47:05 OK   rustwebapp.vks.local served the greeting page through the ingress   <- ALIVE
  #
  # 1. The rollout's rc is CHECKED (it was discarded), and we settle until every pod actually runs
  #    the new image -- `rollout status` can return while old pods are still Terminating.
  wait_for "[${app}] new rollout complete" kubectl -n "$ns" rollout status "deploy/${app}" --timeout=30s \
    || die "[${app}] rollout did not converge -- NOT a page problem; the Deployment never settled"
  # shellcheck disable=SC2329  # invoked indirectly (wait_for), same as marker_visible below
  _all_pods_on_img() {
    local got; got="$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=${app}" \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].image}{"\n"}{end}' 2>/dev/null)"
    # -F -x: $img contains dots and a colon; in a regex those are wildcards (over-matches only,
    # but there is no reason to compare an image ref as a pattern).
    [ -n "$got" ] && ! grep -qvFx -- "$img" <<< "$got"
  }
  wait_for "[${app}] every pod running ${img}" _all_pods_on_img \
    || log_warn "[${app}] not every pod reports ${img} — the marker check below may sample an old pod"

  # 2. Bind a NAMED POD that is Ready and already on the new image, not `svc/`. A death is then
  #    attributable to that pod instead of being invisible.
  _pick_pod() {
    kubectl -n "$ns" get pod -l "app.kubernetes.io/name=${app}" \
      -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{.status.containerStatuses[0].image}{"\n"}{end}' \
      2>/dev/null | awk -v i="$img" '$2==i {print $1; exit}'
  }
  local pf_target; pf_target="$(_pick_pod)"
  # ⚠️ THE REMOTE PORT DEPENDS ON THE TARGET, AND BINDING A POD ON :80 CAN NEVER CONNECT.
  # 80 is the SERVICE port; the Service maps it to targetPort `http` = the container's 8080. When
  # this bound `svc/`, :80 was right. Switching the target to a NAMED POD (so a death is
  # attributable) kept :80 -- and a pod has nothing listening there.
  #
  # MEASURED on a healthy, Ready, 0-restart javawebapp pod:
  #     port-forward <pod> L:80    -> http 000 (connection refused)   <- what shipped
  #     port-forward <pod> L:8080  -> http 200
  #     port-forward svc/<app> L:80-> http 200                        <- the pre-pod behaviour
  # Every run that FOUND a Ready pod on the new image therefore could not connect, ever. It read as
  # 114 "connection refused" tunnel deaths across the generation cap, ~10 minutes AFTER both pods
  # were Ready (6s and 7s after creation) -- so it looked like a flaky tunnel or a slow app, and was
  # neither. The svc/ FALLBACK below still worked, which is why this only bites when the pod lookup
  # SUCCEEDS: the healthier the cluster, the more certain the failure.
  # ⚠️ THE PORT IS A FUNCTION OF THE TARGET, SO IT MUST BE RE-DERIVED EVERY TIME THE TARGET MOVES.
  # This used to be resolved ONCE, in the initial bind, while the tunnel-rebuild sites reassigned
  # pf_target and inherited the stale port. MEASURED across all six apps: every Service exposes
  # ONLY 80 and every containerPort is 8080, so BOTH transitions were broken --
  #     pod  -> svc/   inherited 8080, and no Service has a port 8080     -> bind fails
  #     svc/ -> pod    inherited 80,   and nothing listens on 80          -> the bug above, again
  # Either one killed the tunnel permanently for the rest of the run. That is the real mechanism of
  # the run-8 failure: generations 4 and 5 fell back to svc/ carrying pf_port=8080 from a pod bind,
  # after which no fetch ever succeeded and the PRODUCT verdict was rendered from a CACHED pre-roll
  # body -- so the page was blamed for a tunnel that could not connect. Adversary-caught; the $img
  # snapshot merely triggered the fallback, it did not cause the failure.
  local pf_port=80
  # shellcheck disable=SC2329  # invoked indirectly below and at every rebuild site
  _resolve_pf_port() {
    case "$pf_target" in
      ""|svc/*) pf_port=80; return 0 ;;
    esac
    pf_port="$(kubectl -n "$ns" get pod "$pf_target" \
                 -o jsonpath='{.spec.containers[0].ports[0].containerPort}' 2>/dev/null || true)"
    if [ -z "$pf_port" ]; then
      # A pod that declares no containerPort gives us nothing to bind. svc/ resolves the name for
      # us, so fall back rather than guess a number.
      #
      # ⚠️ FALL BACK TO svc/ HERE, not to "". An earlier version of this helper blanked pf_target
      # and relied on the caller re-checking for empty. That is true at the INITIAL bind (which has
      # an `if [ -z "$pf_target" ]` follow-up) and FALSE at both REBUILD sites, which call _start_pf
      # immediately -- MEASURED: `kubectl port-forward "" 18099:80` -> "error: resource name may not
      # be empty", i.e. a permanently dead tunnel. Resolving it inside the helper covers every
      # caller by construction instead of requiring each one to remember.
      log_warn "[${app}] pod ${pf_target} declares no containerPort — binding svc/ instead"
      pf_target="svc/${app}"; pf_port=80
    fi
  }
  _resolve_pf_port
  if [ -z "$pf_target" ]; then
    # F5: falling back silently means a degraded run is indistinguishable from a fixed one.
    pf_target="svc/${app}"; pf_port=80
    log_warn "[${app}] no Ready pod reports ${img} — binding svc/, which is the PRE-FIX behaviour this fix exists to remove"
  fi
  log_info "[${app}] tunnel target ${pf_target} remote port ${pf_port}"
  _start_pf() {
    [ -n "${PF_PID:-}" ] && { kill "$PF_PID" 2>/dev/null || true; }
    kubectl -n "$ns" port-forward "$pf_target" "${app_local_port}:${pf_port}" >/dev/null 2>&1 &
    PF_PID=$!
    PF_GEN=$((${PF_GEN:-0} + 1))
  }
  # An explicit APP_LOCAL_PORT wins (single-app debugging); otherwise a fresh port PER APP.
  app_local_port="${APP_LOCAL_PORT:-$(pick_port)}"
  PF_GEN=0; _start_pf
  local url="http://localhost:${app_local_port}"
  # 3. BOUND EVERY CURL. `wait_for` only tests its deadline BETWEEN attempts, so one hanging attempt
  #    makes READY_TIMEOUT_SECONDS not a bound at all. Measured: a bare `curl -fsS` against an
  #    accept-then-hang peer was still running at 8s. The sibling 98-verify-ingress.sh already
  #    passes --max-time for exactly this reason.
  local CT="--connect-timeout ${VERIFY_CURL_CONNECT_TIMEOUT_SECONDS:-5} --max-time ${VERIFY_CURL_MAX_TIME_SECONDS:-10}"

  # ── B497 RESIDUAL, MEASURED 2026-08-27 ─────────────────────────────────────────────────────────
  # The tunnel-death classifier used to live ONLY inside marker_visible(), which runs AFTER this
  # readiness wait. So a port-forward that died during the READINESS wait was never detected and
  # never rebuilt: the wait burned its full VERIFY_READY_TIMEOUT_SECONDS and then blamed the APP.
  # Measured on a KinD e2e:
  #   04:10:09 FATAL [javawebapp] app not serving /healthz (tunnel to javawebapp-...-cxhjq, generation 1)
  # `generation 1` is the tell -- the tunnel was NEVER rebuilt. At that same moment the app served
  # HTTP 200 through the ingress, both pods were 1/1 Running, and NO kubectl port-forward process
  # existed. That is verbatim the mis-attribution B497 exists to remove, one step earlier in the
  # same function: the fix covered the marker check and not the wait above it.
  PF_LAST_BODY=""; PF_DEATHS=0; PF_POLL_FAILS=0; PF_RESTARTS_BLOCKED=""; PF_UNKNOWN=""; PF_EVENTS=""
  # ⚠️ EVENTS GO IN A VARIABLE, NOT log_warn: `wait_for` invokes its predicate as `"$@" >/dev/null
  # 2>&1`, so anything _log writes from in here is DISCARDED. Collected, printed in the arms below.
  # shellcheck disable=SC2329  # invoked indirectly (from the predicates below)
  _pf_ev() { PF_EVENTS="${PF_EVENTS}
  - $*"; }

  # SHARED classifier: given a FAILING curl rc, decide tunnel-vs-app and rebuild when it is the
  # tunnel. EXTRACTED rather than duplicated -- two copies would drift, and the entire point is that
  # both waits agree on what a dead tunnel looks like.
  # shellcheck disable=SC2329  # invoked indirectly (from the predicates below)
  _pf_classify() {
    local rc="$1" ready restarts krc
    # 22 IS A SUCCESSFUL ROUND TRIP: `curl -f` exits 22 on an HTTP error STATUS, so the tunnel
    # carried the request and the app answered 4xx/5xx. Never a tunnel death.
    if [ "$rc" -eq 22 ]; then
      PF_POLL_FAILS=$((PF_POLL_FAILS + 1))
      _pf_ev "the app answered with an HTTP ERROR STATUS ($(_curl_rc_label "$rc")) — the tunnel worked"
      return 1
    fi
    # Ask the CLUSTER, not curl's exit code: rc=7 is only ONE death shape (56 = accept-then-RST,
    # 28 = accept-then-hang). Capture kubectl's OWN rc -- an empty answer means "not Ready" only if
    # the query SUCCEEDED; folding them together reports a PRODUCT verdict for "I could not ask".
    ready="$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=${app}" \
               -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{" "}{end}' 2>/dev/null)" && krc=0 || krc=$?
    if [ "$krc" -ne 0 ]; then
      PF_UNKNOWN="kubectl could not be queried (rc=${krc}) — cannot tell the app from the tunnel"
      PF_DEATHS=$((PF_DEATHS + 1))
      _pf_ev "curl failed ($(_curl_rc_label "$rc")) AND kubectl rc=${krc}; rebuilding the tunnel anyway"
      if [ "$PF_GEN" -lt "${VERIFY_PF_MAX_GENERATIONS:-5}" ]; then
        pf_target="$(_pick_pod)"; [ -n "$pf_target" ] || { pf_target="svc/${app}"; _pf_ev "no Ready pod on ${img} — FALLING BACK TO svc/"; }
        _resolve_pf_port   # the target moved, so the port must move with it
        _start_pf
      fi
      return 1
    fi
    restarts="$(kubectl -n "$ns" get pod -l "app.kubernetes.io/name=${app}" \
                  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"+"}{end}' 2>/dev/null)"
    if grep -q false <<< "$ready" || [ -z "$ready" ]; then
      PF_RESTARTS_BLOCKED="pods not Ready (ready=[${ready}] restarts=[${restarts}])"
      PF_POLL_FAILS=$((PF_POLL_FAILS + 1))
      _pf_ev "curl failed ($(_curl_rc_label "$rc")) and the pods are NOT Ready — this is the APP, not the tunnel"
      return 1     # do NOT paper over an unstable app by rebuilding
    fi
    # Pods Ready and curl cannot reach them: the tunnel. Count a DEATH only here.
    PF_DEATHS=$((PF_DEATHS + 1))
    if [ "$PF_GEN" -lt "${VERIFY_PF_MAX_GENERATIONS:-5}" ]; then
      _pf_ev "the port-forward stopped ($(_curl_rc_label "$rc")); pods are Ready, so this is the TUNNEL — rebuilding (generation $((PF_GEN + 1)))"
      pf_target="$(_pick_pod)"; [ -n "$pf_target" ] || { pf_target="svc/${app}"; _pf_ev "no Ready pod on ${img} — FALLING BACK TO svc/"; }
      _resolve_pf_port   # the target moved, so the port must move with it
      _start_pf
    else
      _pf_ev "the port-forward stopped ($(_curl_rc_label "$rc")) and the generation cap (${VERIFY_PF_MAX_GENERATIONS:-5}) is spent"
    fi
    return 1
  }

  # shellcheck disable=SC2329  # invoked indirectly (wait_for)
  _health_up() {
    local rc
    # shellcheck disable=SC2086
    curl -fsS $CT "${url}${health}" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 0 ] && return 0
    _pf_classify "$rc"
    return 1
  }
  if ! wait_for "[${app}] app HTTP up" _health_up; then
    [ -n "$PF_EVENTS" ] && log_error "[${app}] tunnel events:${PF_EVENTS}"
    if [ "$PF_DEATHS" -gt 0 ] && [ -z "$PF_RESTARTS_BLOCKED" ]; then
      die "HARNESS-TUNNEL [${app}] ${health} was NEVER reached — ${PF_DEATHS} tunnel death(s) across ${PF_GEN} generation(s) to ${pf_target}. The pods were Ready, so this is the PORT-FORWARD, not the app; retry the row."
    fi
    die "PRODUCT [${app}] app not serving ${health} (tunnel to ${pf_target}, generation ${PF_GEN}${PF_RESTARTS_BLOCKED:+, ${PF_RESTARTS_BLOCKED}})"
  fi

  # Capture the page, THEN grep the variable: `curl | grep -q` lets grep close the pipe on its
  # first match and SIGPIPE curl (141), which under `set -o pipefail` reads as "marker absent" —
  # a false failure on a page that DID show it.
  # 4. CLASSIFY WITH kubectl, NOT WITH CURL'S EXIT CODE. rc=7 is only ONE tunnel-death shape:
  #    accept-then-RST gives 56 and accept-then-hang gives 28, and those leave no trace at all --
  #    not even the `curl: (7)` line that made this incident diagnosable. So on ANY curl failure we
  #    ask the cluster, which needs no tunnel.
  # 5. CACHE THE LAST NON-EMPTY BODY. The old diagnostic re-fetched down the SAME dead tunnel and
  #    therefore printed nothing, leaving the archive unable to distinguish "the tunnel died" from
  #    "the page never had the marker". This is the change that makes the next occurrence legible.
  # ⚠️ EVENTS GO IN A VARIABLE, NOT log_warn. `wait_for` invokes this predicate as
  # `"$@" >/dev/null 2>&1` and _log writes to STDERR, so every log line emitted from in here is
  # DISCARDED -- including the curl failure-mode label that is the whole point of classifying. A
  # rebuild-heavy row would have been indistinguishable in the archive from a clean one, i.e. the
  # fix would have been unmeasurable. Collected here, printed in BOTH arms below.
  # shellcheck disable=SC2329  # called from marker_visible, which wait_for invokes indirectly
  _pf_ev() { PF_EVENTS="${PF_EVENTS}
    - $*"; }
  # shellcheck disable=SC2329  # invoked indirectly (wait_for)
  marker_visible() {
    local b rc
    # shellcheck disable=SC2086
    b="$(curl -fsS $CT "${url}/" 2>/dev/null)" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      [ -n "$b" ] && PF_LAST_BODY="$b"
      # Capture the page, THEN grep the variable: `curl | grep -q` lets grep close the pipe on its
      # first match and SIGPIPE curl (141), which under pipefail reads as "marker absent".
      grep -q "$marker" <<< "$b"; return $?
    fi
    # CACHE THE LAST NON-EMPTY BODY so a later diagnostic does not re-fetch down a dead tunnel and
    # print nothing -- that is what made the previous incident illegible in the archive.
    [ "$rc" -eq 22 ] && [ -z "$PF_LAST_BODY" ] && PF_LAST_BODY="<HTTP error status; body suppressed by curl -f>"
    _pf_classify "$rc"
    return 1
  }
  if wait_for "[${app}] deployed page shows marker ${marker}" marker_visible; then
    log_info "[${app}] SUCCESS — the deployed page shows '${marker}' (${PF_DEATHS} tunnel death(s), ${PF_GEN} generation(s), ${PF_POLL_FAILS} non-tunnel poll failure(s))"
    [ -n "$PF_EVENTS" ] && log_info "[${app}] tunnel events:${PF_EVENTS}"
  else
    # 6. NAME THE ACTUAL CAUSE. Still FATAL either way -- a certification cannot pass on an
    #    unobserved end result -- but the operator must know whether to retry the row or debug the
    #    product, so the token differs.
    # NAME THE ACTUAL CAUSE. Still FATAL either way -- a certification cannot pass on an unobserved
    # end result -- but the token tells the operator whether to retry the row or debug the app.
    [ -n "$PF_EVENTS" ] && log_error "[${app}] tunnel events:${PF_EVENTS}"
    if [ -n "$PF_UNKNOWN" ]; then
      log_error "UNKNOWN [${app}] ${PF_UNKNOWN}. Do NOT read this as an app failure OR a tunnel failure: the harness could not ask the cluster. Check RBAC (a tenant may hold pods/portforward without pods/list) and the kubeconfig."
    elif [ -n "$PF_RESTARTS_BLOCKED" ]; then
      log_error "PRODUCT [${app}] the app never became stable: ${PF_RESTARTS_BLOCKED} (deployed image: ${img})"
    elif [ -n "$PF_LAST_BODY" ]; then
      log_error "PRODUCT [${app}] the page WAS served and does NOT show '${marker}' (deployed image: ${img}, ${PF_DEATHS} tunnel death(s), ${PF_GEN} generation(s))"
      grep -i 'class="message"' <<< "$PF_LAST_BODY" >&2 || printf '%s\n' "$PF_LAST_BODY" | head -5 >&2
    else
      log_error "HARNESS-TUNNEL [${app}] the page was NEVER successfully fetched — ${PF_DEATHS} tunnel death(s) across ${PF_GEN} generation(s) to ${pf_target}. This is the PORT-FORWARD, not the app; retry the row."
      kubectl -n "$ns" get pod -l "app.kubernetes.io/name=${app}" -o wide >&2 2>/dev/null || true
    fi
    die "[${app}] end result not observed"
  fi
  kill "$PF_PID" 2>/dev/null || true; PF_PID=""
}

for_each_app verify_app

log_info "End-to-end verified for EVERY app ($(app_names | tr '\n' ' ')): git push -> Tekton -> Harbor -> write-back -> ArgoCD -> live page."
