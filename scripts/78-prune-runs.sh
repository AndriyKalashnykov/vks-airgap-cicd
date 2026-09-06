#!/usr/bin/env bash
# Prune completed Tekton PipelineRuns, keeping the N most recent PER APP.
#
# WHY THIS EXISTS — MEASURED on a real lab, one day of use:
#   118 PipelineRuns / 466 TaskRuns retained, and 118 PVCs at 2Gi each = 236 GiB PROVISIONED.
#   118 of the cluster's 119 PersistentVolumes were abandoned Tekton workspaces. Every `make verify`
#   costs 12 GiB (6 apps x 2Gi) permanently. Nothing reclaimed it: the Tekton controller has no
#   --prune flags, there is no pruner CronJob, and nothing in this repo cleaned up.
#   The PVCs carry `ownerReferences: PipelineRun/<name>`, so deleting the run reaps its PVC.
#
# WHY FROM THE JUMP BOX AND NOT A CronJob. An in-cluster job needs an image with `kubectl` or `tkn`,
# and NONE of the 17 mirrored images has either — busybox, the only plausible host, has GET/POST
# wget with NO --method, so it cannot issue a DELETE (measured). A CronJob would therefore cost a
# new row in images/images.txt, a re-mirror, check-image-alignment, bundle size, and a new thing the
# air-gap box must carry. The jump box already has `tkn` (00-install-prereqs.sh installs it), and
# uses the operator's OWN kubeconfig — so it needs no new image and no new RBAC.
#
# TENANT-SAFE: a scenario-2 tenant may not have delete on pipelineruns in the CI namespace. This
# WARNS and returns 0 in that case — a lab you do not own is not a failure of your pipeline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

KEEP="${PRUNE_KEEP:-3}"
NS="${CI_NAMESPACE:-ci}"

case "$KEEP" in ''|*[!0-9]*) die "PRUNE_KEEP must be a non-negative integer, got '${KEEP}'" ;; esac
[ "$KEEP" -ge 1 ] || die "PRUNE_KEEP must be >= 1 — keeping ZERO runs would delete the run you are looking at"

have tkn || { log_warn "tkn is not installed — skipping the prune (run 'make deps')"; exit 0; }
[ -n "${KUBECONFIG:-}" ] || { log_warn "no KUBECONFIG — skipping the prune"; exit 0; }

# Count BEFORE, so the report is the end state and not the delete counter. A bulk delete's own
# tally counts what it TRIED; only a re-list says what remains.
before_pr="$(kubectl -n "$NS" get pipelinerun --no-headers 2>/dev/null | wc -l | tr -d ' ')"
before_pvc="$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${before_pr:-0}" -eq 0 ]; then
  log_info "prune-runs: nothing to prune (0 PipelineRuns in ${NS})"
  exit 0
fi
log_info "prune-runs: ${before_pr} PipelineRun(s), ${before_pvc} PVC(s) in ${NS}; keeping the newest ${KEEP} per app"

# Per PIPELINE, not per namespace: `--keep N` against the whole namespace would keep N runs TOTAL
# and wipe five of the six apps' history. `-p <app>-ci` scopes it so each app keeps its own N.
# `--ignore-running` defaults true, so an in-flight run is never touched — that matters because
# this runs at the START of `make verify`, while nothing of ours is running yet but a webhook-driven
# build might be.
forbidden=0
prune_app() {
  local app="$1" out rc=0
  out="$(tkn pipelinerun delete -n "$NS" -p "${app}-ci" --keep "$KEEP" -f --ignore-running 2>&1)" || rc=$?
  case "$out" in
    *orbidden*|*nauthorized*) forbidden=1; return 0 ;;
  esac
  [ "$rc" -eq 0 ] || log_warn "[${app}] prune returned rc=${rc}: $(printf '%s' "$out" | tail -1)"
}
for_each_app prune_app

if [ "$forbidden" -eq 1 ]; then
  log_warn "prune-runs: the cluster REFUSED the delete (Forbidden). A scenario-2 tenant often cannot"
  log_warn "  delete pipelineruns in ${NS}; ask the platform team, or run this where you can. Not fatal."
  exit 0
fi

# RE-LIST. The delete counter reports what it tried; this reports what is actually left.
after_pr="$(kubectl -n "$NS" get pipelinerun --no-headers 2>/dev/null | wc -l | tr -d ' ')"
after_pvc="$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
log_info "prune-runs: PipelineRuns ${before_pr} -> ${after_pr}; PVCs ${before_pvc} -> ${after_pvc} (~$(( (before_pvc - after_pvc) * 2 )) GiB reclaimed)"
