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
# ⚠️ SUPERVISOR-ONLY, and the old message did not say so. MEASURED 2026-09-07: a guest kubeconfig
# has NO CAPI and NO VirtualMachineService API at all (`api-resources` returns nothing for either) —
# so a Scenario-2 tenant cannot delete their cluster, and it is not an RBAC gap they can ask to have
# widened. Sending them to `make vks-login` is a dead end: it would fail for a different reason and
# tell them nothing. Name the actual situation instead.
[ -f "$SUP" ] || die "no Supervisor kubeconfig at ${SUP}.

Deleting a guest cluster is a SUPERVISOR-ONLY operation: the guest cluster does not serve the
Cluster or VirtualMachineService APIs at all, so this cannot be done with a guest kubeconfig.

  Scenario 1 (you run the Supervisor): run 'make vks-login' first.
  Scenario 2 (you are a TENANT):       you cannot delete this cluster — ask the platform team."
k() { kubectl --kubeconfig "$SUP" --request-timeout=15s "$@" </dev/null; }

# --- DESTRUCTIVE: require an explicit confirmation naming the cluster -----------------------------
# Deleting a guest cluster destroys its VMs and PVCs. `CONFIRM=<name>` and not a bare `yes`, so a
# copy-pasted command cannot delete a cluster the operator did not mean to name.
# 🔴 SAY WHICH ESTATE — and this script is the SHARPEST case of it. Its whole job is to delete a
# cluster BY NAME, so a same-named cluster on a FOREIGN estate passes CONFIRM and is destroyed. The
# name is typed from memory; the Supervisor comes from a candidate ladder, and a different lab's
# kubeconfig answers and authenticates just as well (B547 mode 2). This was the third destructive
# caller and it got no disclosure when the other two did -- found by a round, not by me.
# Reading the server out of the FILE costs nothing: state_kubeconfig_server PARSES it, no network,
# no RBAC, works on a torn-down cluster. It runs BEFORE the gate so the FIRST, REFUSED run informs.
_sup_srv="$(state_kubeconfig_server "$SUP" 2>/dev/null || true)"

if [ "${CONFIRM:-}" != "$VKS_CLUSTER_NAME" ]; then
  log_error "REFUSING: this DESTROYS the guest cluster '${VKS_CLUSTER_NAME}' in namespace '${VKS_NAMESPACE}',"
  log_error "  including its node VMs and every PersistentVolume it owns. There is no undo."
  log_error "  It would act on the Supervisor resolved from: ${SUP}"
  log_error "                                which points at: ${_sup_srv:-<could not read a server URL from that file>}"
  log_error "  CONFIRM proves you know the cluster NAME, not the ESTATE. If that is not the estate"
  log_error "  you meant, do NOT re-run with the name below."
  log_error "  Otherwise re-run naming the cluster you mean:"
  log_error "      make vks-cluster-delete CONFIRM=${VKS_CLUSTER_NAME}"
  exit 1
fi
log_warn "deleting on the Supervisor resolved from: ${SUP}"
log_warn "  which points at: ${_sup_srv:-<could not read a server URL from that file>}"

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
# The Cluster is the WEAKEST of the objects here — see vks_wait_vip_release / vks_vip_holders in
# lib/os.sh for what is actually waited on and why a two-valued "present or absent" read of any of
# them is unsafe.

# ONE implementation, shared with 98-uninstall-all.sh (see vks_wait_vip_release in lib/os.sh).
# The first fix of this defect landed in only ONE of the two identical loops; hoisting them is what
# stops that recurring.
if vks_wait_vip_release "$SUP" "$VKS_NAMESPACE" "$VKS_CLUSTER_NAME" \
     "$DELETE_WAIT_SECONDS" "$POLL_INTERVAL_SECONDS"; then
  log_info "released: nothing in ${VKS_NAMESPACE} still holds a VIP for ${VKS_CLUSTER_NAME} (${SECONDS}s)"
  log_info "  (its Cluster, the VirtualMachineServices found by exact name / cluster label / an exact"
  log_info "   Cluster ownerReference, and its Service. Anything linked by some OTHER mechanism is"
  log_info "   outside what this can see.)"
  log_info "  ⚠️ the address may still be QUARANTINED by the platform allocator (B525 — the window"
  log_info "     is UNMEASURED). This waits for the strongest signal observable from a tenant; it"
  log_info "     does NOT prove the VIP is immediately reusable."
  log_info "  next: make vks-cluster-create   (it gates on the endpoint AGREEING within 90s)"
  exit 0
fi

_still="${VKS_VIP_STILL:-}"
log_error "still present after ${DELETE_WAIT_SECONDS}s: ${_still:-<the wait never ran: check VKS_CLUSTER_DELETE_WAIT_SECONDS>}"
log_error "  NOT stripping finalizers — that orphans VMs and FCDs."
log_error "  Inspect what is holding it:"
log_error "    kubectl --kubeconfig ${SUP} -n ${VKS_NAMESPACE} get cluster ${VKS_CLUSTER_NAME} -o jsonpath='{.metadata.finalizers}'"
# ⚠️ THE ADVICE DEPENDS ON *WHICH* OBJECT IS LEFT, and the old message did not branch. The
# control-plane VIP is the one whose reuse produces a cluster that can never converge; a leftover
# WORKLOAD VMService is pool hygiene — the CP address is already free and a never-used name is
# unaffected by it. Telling an operator to stop for a hazard that does not apply is the same class
# of defect as an error that names the wrong cause.
case " ${_still} " in
  *" cluster "*|*"virtualmachineservice/${VKS_CLUSTER_NAME}"*|*"QUERY-FAILED"*)
    log_error "  Do NOT create a replacement yet: the control-plane VIP may still be held (or we could"
    log_error "  not ask), and recreating into that produces a cluster that never converges (B523/B524)." ;;
  *)
    log_error "  The CONTROL-PLANE VIP is already released — what remains is a WORKLOAD"
    log_error "  VirtualMachineService (pool hygiene, not a converge hazard). Creating a cluster under a"
    log_error "  name that has never been used is unaffected." ;;
esac
exit 1
