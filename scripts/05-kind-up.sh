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
# The KinD flow writes its OWN kubeconfig, at its OWN path — NEVER to whatever $KUBECONFIG points at.
#
# It used to do `KUBECONFIG_PATH="${KUBECONFIG:?}"` and then `kind get kubeconfig > "$KUBECONFIG_PATH"`,
# i.e. it wrote to a CALLER-CONTROLLED path. Anyone who set KUBECONFIG in .env (which .env.example
# invites) already had that file truncated; the uncommented .env.example pin was only an ACCIDENTAL
# SHIELD redirecting it to ./secrets/vks.kubeconfig. Once load_env began honouring the caller's
# KUBECONFIG (so a two-cluster test could be driven at all), the shield came off — a developer with an
# ordinary `export KUBECONFIG=~/.kube/config` would have had it OVERWRITTEN, and then DELETED by
# `make kind-down`, which removes the kubeconfig this flow recorded.
#
# A flow writes only what it owns, and destroys only what it created.
# Not an env var: this path is OWNED by the KinD flow, not an operator knob. (Making it settable
# would just re-open the hole from the other side.)
KUBECONFIG_PATH="${REPO_ROOT}/secrets/kind.kubeconfig"
READY_TIMEOUT="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL_SECONDS:-5}"
KIND_CONFIG="${REPO_ROOT}/kind/kind-config.yaml"
CPK_CONTAINER="cloud-provider-kind"
CPK_IMAGE="registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CPK_VERSION}"

require_cmd kind
require_cmd docker
require_cmd kubectl

[ -f "$KIND_CONFIG" ] || die "kind config not found at $KIND_CONFIG"

# --- 1. Create the cluster (idempotent + health-checked) ---------------------
# A cluster with this name may be listed yet BROKEN — an interrupted `kind create`
# (Ctrl+C mid-create) leaves a partial cluster that `kind get clusters` still lists.
# A name-only guard would then skip create and proceed on a dead cluster. So when the
# name exists, health-check the control-plane and only skip create if a node is
# actually Ready; otherwise delete + recreate.
need_create=1
if kind get clusters 2>/dev/null | grep -qxF "$CLUSTER_NAME"; then
  kc="$(mktemp)"
  # Capture the node list first, THEN grep the variable: piping `kubectl … | grep -q` directly
  # lets `grep -q` close the pipe on its first match, SIGPIPE-killing `kubectl` (exit 141), which
  # under `set -o pipefail` reads as "not Ready" → we would DELETE a HEALTHY cluster. `grep` on a
  # small captured string never SIGPIPEs its source.
  nodes=""
  if kind get kubeconfig --name "$CLUSTER_NAME" >"$kc" 2>/dev/null; then
    nodes="$(kubectl --kubeconfig "$kc" get nodes 2>/dev/null || true)"
  fi
  if [ -n "$nodes" ] && printf '%s\n' "$nodes" | grep -q ' Ready'; then
    log_info "kind cluster '$CLUSTER_NAME' already exists and is healthy — skipping create"
    need_create=0
  else
    log_warn "kind cluster '$CLUSTER_NAME' exists but is NOT healthy (partial/interrupted create?) — deleting + recreating"
    run kind delete cluster --name "$CLUSTER_NAME" || true
  fi
  rm -f "$kc"
fi
if [ "$need_create" = 1 ]; then
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
state_set KUBECONFIG "$KUBECONFIG_ABS"
# Record it separately: `make kind-down` must delete ONLY the kubeconfig THIS flow wrote. It used to
# delete any kubeconfig under ./secrets — which is where the DOCUMENTED real-lab default lives
# (secrets/vks.kubeconfig), so a lab operator following Step 0 of their own runbook lost it.
state_set KIND_KUBECONFIG "$KUBECONFIG_ABS"
state_set VKS_AUTH_METHOD kubeconfig
state_set VKS_CONTEXT "$KIND_CONTEXT"
# Zero-config KinD: generate THROWAWAY test passwords for the local Harbor + Gitea admin
# (this cluster is destroyed at teardown) so `make e2e-kind` needs NO manual .env. Written
# only when unset — a real `.env` value still wins (.env.kind is sourced AFTER .env). NOT
# used by the real lab (no .env.kind there). Revealed via `make creds`. gen_password is a
# random, complexity-valid, NON-hardcoded value (lib/os.sh). ArgoCD's admin password stays
# auto-generated when blank. NOTE: task #13 (env-init/env-populate) will move this into an
# explicit `.env` populate step; kept here as the validated interim that unblocks #98's smoke.
[ -n "${HARBOR_PASSWORD:-}" ]      || state_set HARBOR_PASSWORD "$(gen_password)"
[ -n "${GITEA_ADMIN_PASSWORD:-}" ] || state_set GITEA_ADMIN_PASSWORD "$(gen_password)"
# ArgoCD too — and it MUST be generated HERE, into .env.kind, not left to `.env`.
#
# `make e2e-kind` runs with SKIP_DOTENV=1 (it stands in for a fresh operator / a CI runner, neither
# of which has a .env). So an ARGOCD_ADMIN_PASSWORD sitting in `.env` is NOT seen by
# 07-install-argocd.sh and is NEVER APPLIED — ArgoCD keeps its auto-generated password. But
# `make argocd-password` does NOT skip .env, so it would happily print the .env value: a password
# that does not work. The user is told a password and cannot log in.
#
# .env.kind IS sourced under SKIP_DOTENV, so generating it here means 07 applies it and
# `make creds-show` prints the password that actually works.
[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ] || state_set ARGOCD_ADMIN_PASSWORD "$(gen_password)"
log_info "published KUBECONFIG/VKS_AUTH_METHOD/VKS_CONTEXT (+ generated KinD Harbor/Gitea/ArgoCD creds; see 'make creds-show') to $(state_file)"

# Point subsequent kubectl calls at the kind cluster.
export KUBECONFIG="$KUBECONFIG_ABS"

# STAMP ONLY NOW — AFTER KUBECONFIG points at the cluster we just created.
#
# state_stamp reads the AMBIENT $KUBECONFIG. Stamping earlier recorded whatever load_env had defaulted
# to — `secrets/vks.kubeconfig`. On THIS box that happened to be a stale KinD file, so the stamp looked
# right. ON A LAB BOX secrets/vks.kubeconfig IS THE LAB: `make e2e-kind` would have stamped the KinD
# sink with the LAB's API server, and then either ARCHIVED the live KinD sink away (destroying the only
# copy of the generated passwords) or let a LAB run source KinD's LB IPs and CA — the exact
# cross-cluster contamination the stamp exists to prevent, wearing a green stamp.
state_stamp --kind

# --- 3. Start cloud-provider-kind (detached) for LoadBalancer IPs ------------
# It watches the `kind` docker network and assigns external IPs to LB Services.
if docker ps -a --format '{{.Names}}' | grep -qxF "$CPK_CONTAINER"; then
  log_info "removing existing '$CPK_CONTAINER' container before (re)start"
  run docker rm -f "$CPK_CONTAINER"
fi
log_info "starting $CPK_CONTAINER ($CPK_IMAGE) — manages LB via the docker socket"
# Per the cloud-provider-kind README: run with --network host + the docker socket;
# it creates the per-Service envoy sidecars on the kind network itself via the API.
run docker run -d \
  --name "$CPK_CONTAINER" \
  --network host \
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
