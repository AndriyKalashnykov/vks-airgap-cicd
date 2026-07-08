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
if have kind && kind get clusters 2>/dev/null | grep -qxF "$CLUSTER_NAME"; then
  log_info "deleting kind cluster '$CLUSTER_NAME'"
  run kind delete cluster --name "$CLUSTER_NAME"
else
  log_info "kind cluster '$CLUSTER_NAME' not present (or kind absent) — skipping"
fi

# --- 4. Clean the kind overlay so real-VKS runs aren't polluted --------------
env_kind="${REPO_ROOT}/.env.kind"
if [ -f "$env_kind" ]; then
  log_info "removing kind overlay $env_kind"
  run rm -f "$env_kind"
fi

# Remove the kind kubeconfig only if it lives under ./secrets (don't nuke a
# real-VKS kubeconfig an operator may have pointed KUBECONFIG at).
if [ -n "$KUBECONFIG_PATH" ]; then
  secrets_dir="${REPO_ROOT}/secrets"
  kubeconfig_abs="$(cd "$(dirname "$KUBECONFIG_PATH")" 2>/dev/null && pwd)/$(basename "$KUBECONFIG_PATH")" || kubeconfig_abs=""
  case "$kubeconfig_abs" in
    "${secrets_dir}/"*)
      if [ -f "$kubeconfig_abs" ]; then
        log_info "removing kind kubeconfig $kubeconfig_abs"
        run rm -f "$kubeconfig_abs"
      fi
      ;;
    *)
      [ -n "$kubeconfig_abs" ] && log_info "KUBECONFIG ($KUBECONFIG_PATH) is not under ./secrets — leaving it untouched"
      ;;
  esac
fi

log_info "kind teardown complete"
