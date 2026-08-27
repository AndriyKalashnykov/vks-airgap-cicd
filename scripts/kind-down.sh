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
# The slot the KinD flow OWNS (05-kind-up.sh:35). `kind delete` is pinned to it so kind can never
# open the inherited $KUBECONFIG -- which on a lab box is secrets/vks.kubeconfig or, after
# scenario-1 step "export KUBECONFIG=./secrets/supervisor.kubeconfig", the SUPERVISOR.
KIND_KUBECONFIG_PATH="${REPO_ROOT}/secrets/kind.kubeconfig"
CPK_CONTAINER="cloud-provider-kind"

# NO `require_cmd docker` HERE, DELIBERATELY. It made the FILE half of this script (the overlay, the
# kubeconfig, secrets/ — all pure file operations needing no engine) unreachable on a docker-free box,
# while `docs/scenario-2.md` tells EVERY scenario-2 operator to run `make kind-down` at Step 0c. The
# rc=127 arm of `_dps` below covers an absent docker, so the guard is redundant as well as harmful.
#
# ⚠️ THE THREE-STATE READ IS THE WHOLE POINT. `docker ps` exits 0 on a GENUINELY EMPTY result and
# non-zero on every cannot-ask state (measured: permission-denied 1, socket-absent 1, not-on-PATH 127;
# stdout is EMPTY in all of them). The old code read only stdout, so "no such container" and "I could
# not look" were the same answer — and it then DELETED the state overlay on that basis. Branch on rc.
#
# ⚠️ DO NOT match the stderr TEXT. Measured two different strings for one condition across docker
# versions ("connect to the docker API at …" vs "connect to the Docker daemon socket at unix://…").
# The text is for the human; the rc is for the code.
#
# ⚠️ DO NOT "generalise" this to $(container_engine). podman has a SEPARATE store and CANNOT see
# docker containers: measured `podman ps -aq --filter name=kindccm-` -> rc=0 + EMPTY, an honest-looking
# success that would defeat this entire fix. `kind` makes DOCKER containers; this cleanup is
# docker-specific by construction.
_DPS_ERR="$(mktemp)"; trap 'rm -f "$_DPS_ERR"' EXIT
ENGINE_ASKABLE=1

# _dps FILTER -> prints ids on stdout and returns 0 when the question was ANSWERED (ids may be empty);
# returns 2 when we COULD NOT ASK. rc=127 (docker absent) lands in the cannot-ask arm too.
_dps() {
  local out rc
  out="$(docker ps -aq --filter "name=$1" 2>"$_DPS_ERR")"; rc=$?   # docker-ok: the cleanup target IS docker
  [ "$rc" -eq 0 ] || return 2
  printf '%s' "$out"
}
_cannot_ask() {
  ENGINE_ASKABLE=0
  log_warn "CANNOT ASK docker about $1 — NOT claiming anything was cleaned."
  log_warn "  $(head -1 "$_DPS_ERR" 2>/dev/null || echo 'docker exited non-zero with no message')"
}

# --- 1. Stop + remove the cloud-provider-kind controller ---------------------
if _cpk_ids="$(_dps "^/?${CPK_CONTAINER}\$")"; then
  if [ -n "$_cpk_ids" ]; then
    log_info "removing $CPK_CONTAINER container"
    run docker rm -f "$CPK_CONTAINER"      # docker-ok: removing a container kind/cpk created
  else
    log_info "$CPK_CONTAINER container not present — skipping"
  fi
else
  _cannot_ask "$CPK_CONTAINER"
fi

# --- 2. Prune orphaned kindccm-* sidecars BEFORE deleting the cluster --------
if kindccm_ids="$(_dps kindccm-)"; then
  if [ -n "$kindccm_ids" ]; then
    log_info "pruning orphaned kindccm-* sidecar container(s)"
    # Unquoted on purpose: pass each id as a separate arg. Guarded non-empty above.
    # shellcheck disable=SC2086
    run docker rm -f $kindccm_ids          # docker-ok: removing containers kind/cpk created
  else
    log_info "no kindccm-* sidecars to prune"
  fi
else
  _cannot_ask "kindccm-* sidecars"
fi

# --- 3. Delete the kind cluster ----------------------------------------------
KIND_CLUSTER_REMOVED=0
# `kind get clusters` shells out to docker, so a 2>/dev/null here had the SAME defect: an unusable
# socket made "the cluster is gone" and "I could not ask" identical, and this is the read that decides
# KIND_CLUSTER_REMOVED — which gates the secrets/ removal further down.
_kind_out=""; _kind_rc=0
if have kind; then _kind_out="$(kind get clusters 2>"$_DPS_ERR")" || _kind_rc=$?; else _kind_rc=127; fi
if [ "$_kind_rc" -ne 0 ] && have kind; then _cannot_ask "kind clusters"; fi
if [ "$_kind_rc" -eq 0 ] && printf '%s\n' "$_kind_out" | grep -xF "$CLUSTER_NAME" >/dev/null; then
  log_info "deleting kind cluster '$CLUSTER_NAME'"
  run kind delete cluster --name "$CLUSTER_NAME" --kubeconfig "$KIND_KUBECONFIG_PATH"
  KIND_CLUSTER_REMOVED=1
else
  log_info "kind cluster '$CLUSTER_NAME' not present (or kind absent) — skipping"
fi

# --- 4. Clean the kind overlay so real-VKS runs aren't polluted --------------
# THE DELETE CONTRACT: remove the state overlay ONLY if the KinD flow stamped it as its own.
#
# This used to `rm -f .env.kind` unconditionally. The same sink now carries REAL-LAB discovered state
# (LB IPs, CA paths, the Gitea token) — and BOTH real-lab runbooks tell the operator to run
# `make kind-down` at Step 0 to clear stale KinD state. Unconditional deletion there destroys the
# lab's own discoveries. 05-kind-up.sh writes VKS_STATE_KIND=1; nothing else does.
env_kind="$(state_file)"
if [ -f "$env_kind" ] && [ "$(grep -m1 '^VKS_STATE_KIND=' "$env_kind" 2>/dev/null | cut -d= -f2)" != "1" ]; then
  log_warn "NOT removing $(basename "$env_kind") — it is NOT stamped as KinD state (a real lab wrote it)."
  log_warn "  Inspect it with 'make state-show'."
elif [ -f "$env_kind" ] && [ "$ENGINE_ASKABLE" = 0 ]; then
  # THE DELETE REQUIRES A POSITIVE DETERMINATION THAT NO CLUSTER REMAINS. Measured 2026-08-17: with
  # docker present-but-unusable this script printed three "not present — skipping" lines and then
  # DELETED this file — which `lib/state.sh` states holds the ONLY copy of the generated HARBOR /
  # GITEA / ARGOCD passwords, and which its own doctrine says to ARCHIVE, never `rm`, when ownership
  # cannot be established. rc=0, "kind teardown complete", credentials gone.
  log_warn "leaving $(basename "$env_kind") in place — could not confirm the cluster is gone, and it"
  log_warn "  may hold the ONLY copy of a RUNNING cluster's generated passwords. If you are certain"
  log_warn "  the cluster is gone, remove it by hand:  rm -f $env_kind"
elif [ -f "$env_kind" ]; then
  log_info "removing the KinD state overlay $env_kind"
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
