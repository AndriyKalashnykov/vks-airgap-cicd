#!/usr/bin/env bash
# scripts/97-vks-cluster-delete.sh — delete ONE guest VKS cluster and BLOCK until its
# control-plane VIP is actually released.
#
# WHY THIS EXISTS (B524). Before this, the ONLY delete path in the repo was inside
# `make uninstall-all` — a full teardown requiring CONFIRM= that also touches Harbor projects and
# ArgoCD. So anyone deleting a single cluster hand-rolled `kubectl delete cluster`, which is exactly
# how the 2026-09-05 incident happened. RULE ZERO-A0: the missing target IS the finding.
#
# WHY IT WAITS ON THE VirtualMachineService AND NOT THE Cluster — measured, adversary-verified:
#
#   * `scripts/98-uninstall-all.sh` polls until the *Cluster* object disappears. That is NOT
#     sufficient. The control-plane VIP is held by the *VirtualMachineService*, a SEPARATE object
#     with its own deletion path — measured, it is created 14s AFTER the Cluster
#     (12:15:29Z -> 12:15:43Z on this lab). Its owned core Service carries
#     `ownerReferences: [VirtualMachineService]`.
#   * Recreating while the predecessor's VMService still holds the VIP produces a Cluster whose
#     `spec.controlPlaneEndpoint` is a stale PREDICTION (the predecessor's address, read back).
#     That field is immutable and CAPI never revisits it, so the cluster can NEVER converge.
#     Measured: advertised .132 while the VMService got .133; RemoteConnectionProbe failed forever.
#   * `ipaddressallocations.netoperator.vmware.com` is EMPTY (0 items) on this lab despite live LB
#     services — it is NOT the record for LB VIPs. Do not use it.
#   * `IPPool.status.allocated` is a cross-check only: cluster-scoped (a tenant may not read it) and
#     a COUNT, so it races other tenants. Never gate on it.
#
# ⚠️ RESIDUAL, NAMED NOT HIDDEN (B525): the allocator appears to QUARANTINE a just-freed address —
# measured, a new cluster took .134 while the freed .132 sat unused. So absence of the VMService may
# be necessary but not proven sufficient; the quarantine window is UNMEASURED. This script waits for
# the strongest signal it can observe and SAYS SO rather than claiming the VIP is reusable.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
load_env

: "${VKS_NAMESPACE:?VKS_NAMESPACE is not set — see .env.example}"
: "${VKS_CLUSTER_NAME:?VKS_CLUSTER_NAME is not set — see .env.example}"

# Tunables (documented in .env.example).
DELETE_WAIT_SECONDS="${VKS_CLUSTER_DELETE_WAIT_SECONDS:-900}"
POLL_INTERVAL_SECONDS="${VKS_CLUSTER_DELETE_POLL_SECONDS:-10}"

SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"
[ -f "$SUP" ] || die "no Supervisor kubeconfig at ${SUP} — run: make vks-login"
k() { kubectl --kubeconfig "$SUP" --request-timeout=15s "$@" </dev/null; }

# --- DESTRUCTIVE: require an explicit confirmation naming the cluster -----------------------------
# Deleting a guest cluster destroys its VMs and PVCs. `CONFIRM=<name>` and not a bare `yes`, so a
# copy-pasted command cannot delete a cluster the operator did not mean to name.
if [ "${CONFIRM:-}" != "$VKS_CLUSTER_NAME" ]; then
  log_error "REFUSING: this DESTROYS the guest cluster '${VKS_CLUSTER_NAME}' in namespace '${VKS_NAMESPACE}',"
  log_error "  including its node VMs and every PersistentVolume it owns. There is no undo."
  log_error "  Re-run naming the cluster you mean:"
  log_error "      make vks-cluster-delete CONFIRM=${VKS_CLUSTER_NAME}"
  exit 1
fi

# --- OWNERSHIP: never delete a cluster this repo did not create ----------------------------------
# Same guard as 98-uninstall-all.sh:262 and for the same reason: on a real lab this namespace also
# holds the lab's OWN clusters, so "it is in our namespace" is not ownership.
if ! k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >/dev/null 2>&1; then
  log_info "Cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME} is not present — nothing to delete."
  log_info "  (this is NOT proof it never existed: a read can also fail on RBAC or an unreachable"
  log_info "   Supervisor. If you expected it, check: kubectl --kubeconfig ${SUP} -n ${VKS_NAMESPACE} get cluster)"
  exit 0
fi
_own="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
          -o jsonpath='{.metadata.labels.vks-airgap-cicd\.local/owned-by}' 2>/dev/null || true)"
if [ "$_own" != "vks-airgap-cicd" ] && [ "${ALLOW_FOREIGN_CLUSTER_DELETE:-0}" != "1" ]; then
  log_error "REFUSING: ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME} is NOT labelled as created by us"
  log_error "  (owned-by='${_own:-none}'). On a shared Supervisor that label is the only thing"
  log_error "  distinguishing our cluster from the platform team's."
  log_error "  If you are certain, re-run with: ALLOW_FOREIGN_CLUSTER_DELETE=1"
  exit 1
fi

log_info "deleting ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME} (asynchronous — two controllers hold finalizers)"
k -n "$VKS_NAMESPACE" delete cluster "$VKS_CLUSTER_NAME" --wait=false >/dev/null 2>&1 || true

# --- WAIT FOR THE VIP TO BE RELEASED -------------------------------------------------------------
# THREE objects, and the Cluster is the WEAKEST of them. We wait for all three to be NotFound.
# `|| true` on every read: `get` exits non-zero on NotFound, which is the SUCCESS case here, and a
# bare `$(k get ...)` under `set -e` would kill the script at the moment it succeeds.
_gone() { k -n "$VKS_NAMESPACE" get "$1" "$VKS_CLUSTER_NAME" >/dev/null 2>&1 && return 1 || return 0; }

_end=$((SECONDS + DELETE_WAIT_SECONDS))
_last=""
while [ "$SECONDS" -lt "$_end" ]; do
  _still=""
  _gone cluster                || _still="${_still} cluster"
  _gone virtualmachineservice  || _still="${_still} virtualmachineservice"
  _gone svc                    || _still="${_still} svc"
  if [ -z "$_still" ]; then
    log_info "released: cluster, virtualmachineservice and svc are all gone (${SECONDS}s)"
    log_info "  ⚠️ the address may still be QUARANTINED by the platform allocator (B525 — the window"
    log_info "     is UNMEASURED). This waits for the strongest signal observable from a tenant; it"
    log_info "     does NOT prove the VIP is immediately reusable."
    log_info "  next: make vks-cluster-create   (it gates on the endpoint AGREEING within 90s)"
    exit 0
  fi
  if [ "$_still" != "$_last" ]; then
    log_info "  waiting on:${_still}"
    _last="$_still"
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

log_error "still present after ${DELETE_WAIT_SECONDS}s:${_still}"
log_error "  NOT stripping finalizers — that orphans VMs and FCDs."
log_error "  Inspect what is holding it:"
log_error "    kubectl --kubeconfig ${SUP} -n ${VKS_NAMESPACE} get cluster ${VKS_CLUSTER_NAME} -o jsonpath='{.metadata.finalizers}'"
log_error "  Do NOT create a replacement yet: recreating while the VirtualMachineService still holds"
log_error "  the control-plane VIP produces a cluster that can never converge (B523/B524)."
exit 1
