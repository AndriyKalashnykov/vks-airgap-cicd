#!/usr/bin/env bash
# scripts/05-kind-up.sh — bring up a local KinD cluster with a working
# LoadBalancer (via cloud-provider-kind), so an in-cluster Harbor is reachable
# by the SAME IP from host, pods, and containerd. This simulates the
# "VKS-provided" Harbor + ArgoCD locally for `make e2e-kind`.
#
# It publishes the discovered kubeconfig + context to a gitignored .env.kind
# overlay (via set_env_var) so `make vks-login` and every downstream script
# target the kind cluster unchanged.
#
# Idempotent: safe to re-run. Teardown is scripts/kind-down.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# --- Tunables (read from .env* after load_env; never hardcode) ---------------
CLUSTER_NAME="${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME must be set in .env.example}"
NODE_IMAGE="${KIND_NODE_IMAGE:-}"
CPK_VERSION="${CLOUD_PROVIDER_KIND_VERSION:?CLOUD_PROVIDER_KIND_VERSION must be set in .env.example}"
KUBECONFIG_PATH="${KUBECONFIG:?KUBECONFIG must be set in .env.example}"
READY_TIMEOUT="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL_SECONDS:-5}"
KIND_CONFIG="${REPO_ROOT}/kind/kind-config.yaml"
CPK_CONTAINER="cloud-provider-kind"
CPK_IMAGE="registry.k8s.io/cloud-provider-kind/cloud-provider-kind:${CPK_VERSION}"

require_cmd kind
require_cmd docker
require_cmd kubectl

[ -f "$KIND_CONFIG" ] || die "kind config not found at $KIND_CONFIG"

# --- 1. Create the cluster (idempotent) --------------------------------------
if kind get clusters 2>/dev/null | grep -qxF "$CLUSTER_NAME"; then
  log_info "kind cluster '$CLUSTER_NAME' already exists — skipping create"
else
  log_info "creating kind cluster '$CLUSTER_NAME' from $KIND_CONFIG"
  # Assemble args in an array so the optional --image is added only when set.
  create_args=(create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG")
  if [ -n "$NODE_IMAGE" ]; then
    log_info "using pinned node image: $NODE_IMAGE"
    create_args+=(--image "$NODE_IMAGE")
  else
    log_info "KIND_NODE_IMAGE empty — using kind's built-in default node image"
  fi
  run kind "${create_args[@]}"
fi

# --- 2. Export the kubeconfig + publish context to downstream scripts --------
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
log_info "writing kubeconfig -> $KUBECONFIG_PATH"
kind get kubeconfig --name "$CLUSTER_NAME" > "$KUBECONFIG_PATH"

# Absolute path so the value works regardless of the caller's CWD.
KUBECONFIG_ABS="$(cd "$(dirname "$KUBECONFIG_PATH")" && pwd)/$(basename "$KUBECONFIG_PATH")"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
set_env_var KUBECONFIG "$KUBECONFIG_ABS"
set_env_var VKS_AUTH_METHOD kubeconfig
set_env_var VKS_CONTEXT "$KIND_CONTEXT"
log_info "published KUBECONFIG/VKS_AUTH_METHOD/VKS_CONTEXT to ${REPO_ROOT}/.env.kind"

# Point subsequent kubectl calls at the kind cluster.
export KUBECONFIG="$KUBECONFIG_ABS"

# --- 3. Start cloud-provider-kind (detached) for LoadBalancer IPs ------------
# It watches the `kind` docker network and assigns external IPs to LB Services.
if docker ps -a --format '{{.Names}}' | grep -qxF "$CPK_CONTAINER"; then
  log_info "removing existing '$CPK_CONTAINER' container before (re)start"
  run docker rm -f "$CPK_CONTAINER"
fi
log_info "starting $CPK_CONTAINER ($CPK_IMAGE) on the kind docker network"
run docker run -d \
  --name "$CPK_CONTAINER" \
  --network kind \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "$CPK_IMAGE"

# --- 4. Readiness: poll until all nodes are Ready (bounded, with delay) -------
log_info "waiting for all nodes to become Ready (timeout ${READY_TIMEOUT}s, poll ${POLL_INTERVAL}s)"
deadline=$(( SECONDS + READY_TIMEOUT ))
until kubectl wait --for=condition=Ready nodes --all \
        --timeout="${POLL_INTERVAL}s" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    log_error "nodes did not become Ready within ${READY_TIMEOUT}s; current state:"
    kubectl get nodes >&2 || true
    die "kind cluster '$CLUSTER_NAME' failed readiness"
  fi
  log_info "nodes not Ready yet — retrying in ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
log_info "all nodes Ready"

# --- 5. Summary --------------------------------------------------------------
kubectl get nodes >&2 || true
log_info "kind cluster '$CLUSTER_NAME' is up (context: $KIND_CONTEXT)"
log_info "next step: make install-harbor"
