#!/usr/bin/env bash
# scripts/kind-down.sh — tear down the local KinD end-to-end environment.
#
# ORDER MATTERS (known cloud-provider-kind gotcha): the per-Service
# `kindccm-<hash>` envoy sidecars survive `kind delete cluster`, hold LB IPs in
# the kind docker network, and poison the next run's LB assignment. They must be
# pruned BEFORE deleting the cluster.
#
# Idempotent: safe to run when nothing is up.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

CLUSTER_NAME="${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME must be set in .env.example}"
KUBECONFIG_PATH="${KUBECONFIG:-}"
CPK_CONTAINER="cloud-provider-kind"

require_cmd docker

# --- 1. Stop + remove the cloud-provider-kind controller ---------------------
if docker ps -a --format '{{.Names}}' | grep -qxF "$CPK_CONTAINER"; then
  log_info "removing $CPK_CONTAINER container"
  run docker rm -f "$CPK_CONTAINER"
else
  log_info "$CPK_CONTAINER container not present — skipping"
fi

# --- 2. Prune orphaned kindccm-* sidecars BEFORE deleting the cluster --------
kindccm_ids="$(docker ps -aq --filter name=kindccm- 2>/dev/null || true)"
if [ -n "$kindccm_ids" ]; then
  log_info "pruning orphaned kindccm-* sidecar container(s)"
  # Unquoted on purpose: pass each id as a separate arg. Guarded non-empty above.
  # shellcheck disable=SC2086
  run docker rm -f $kindccm_ids
else
  log_info "no kindccm-* sidecars to prune"
fi

# --- 3. Delete the kind cluster ----------------------------------------------
KIND_CLUSTER_REMOVED=0
if have kind && kind get clusters 2>/dev/null | grep -qxF "$CLUSTER_NAME"; then
  log_info "deleting kind cluster '$CLUSTER_NAME'"
  run kind delete cluster --name "$CLUSTER_NAME"
  KIND_CLUSTER_REMOVED=1
else
  log_info "kind cluster '$CLUSTER_NAME' not present (or kind absent) — skipping"
fi

# --- 4. Clean the kind overlay so real-VKS runs aren't polluted --------------
env_kind="${REPO_ROOT}/.env.kind"
if [ -f "$env_kind" ]; then
  log_info "removing kind overlay $env_kind"
  run rm -f "$env_kind"
fi

# Remove ONLY the kubeconfig THIS FLOW WROTE. `05-kind-up.sh` records it as KIND_KUBECONFIG.
#
# It used to delete any kubeconfig living under ./secrets — and the comment claimed that protected a
# real-VKS one. It did the opposite: the DOCUMENTED real-lab default IS `./secrets/vks.kubeconfig`
# (.env.example). So `make kind-down` — which BOTH real-lab runbooks tell you to run at Step 0 to
# clear stale KinD state — DELETED THE OPERATOR'S LAB KUBECONFIG. A teardown must remove what it
# created, and nothing else. If we did not write it, we do not touch it.
if [ -n "${KIND_KUBECONFIG:-}" ] && [ -f "$KIND_KUBECONFIG" ]; then
  log_info "removing the kubeconfig the KinD flow wrote ($KIND_KUBECONFIG)"
  run rm -f "$KIND_KUBECONFIG"
elif [ -n "$KUBECONFIG_PATH" ]; then
  log_info "leaving KUBECONFIG ($KUBECONFIG_PATH) untouched — the KinD flow did not write it"
fi

# --- 5. Remove cluster-specific credentials so the NEXT fresh cluster re-mints
# them. These are bound to the torn-down cluster's Gitea: the CI access token and the webhook shared
# secret. If left behind, seed-gitea "reuses" a stale token against a fresh Gitea that never issued
# it -> HTTP 401.
#
# BUT ONLY IF WE ACTUALLY TORE A KIND CLUSTER DOWN. The old code deleted them unconditionally, on the
# claim that "only the kind flow writes these; real-VKS runs use their own". That is FALSE:
# 50-seed-gitea-repos.sh writes secrets/gitea-ci-token and secrets/webhook-token in EITHER flow. So a
# real-lab operator following Step 0 of their own runbook ("make kind-down — if you ran the local
# flow") destroyed their LAB Gitea credentials.
if [ "${KIND_CLUSTER_REMOVED:-0}" = "1" ]; then
  for stale in "${REPO_ROOT}/secrets/gitea-ci-token" "${REPO_ROOT}/secrets/webhook-token"; do
    if [ -f "$stale" ]; then
      log_info "removing kind-cluster-scoped credential $stale"
      run rm -f "$stale"
    fi
  done
else
  log_info "no kind cluster was torn down — leaving secrets/ untouched (they may be a real lab's)."
fi

log_info "kind teardown complete"
