#!/usr/bin/env bash
# scripts/25-vks-cluster-create.sh — provision the guest VKS cluster (scenario-1 §4b).
#
# Gives .env.example's six VKS_* topology keys their FIRST reader. Until this script they were
# documented with "DOCUMENTED BUT NOT YET READ by any script (measured: 0 readers each)", so the
# runbook told the operator to set six values that nothing consumed and then to create the cluster
# "by whatever you apply by hand".
#
# ⚠️ THE GATE IS `kubectl apply --dry-run=server`, NOT A HAND-ROLLED CHECK. Measured: it runs the
# real mutating AND validating webhooks and persists nothing, and it rejects a bogus variable name
# ("variable is not defined"), a missing required variable ("Required value"), a VM class that does
# not exist in THIS namespace, a storage class that does not exist, an empty classRef, and a version
# no TKr matches. Nothing hand-written comes close — the ClusterClass's required-variable schema
# lives in status.variables and comes from a runtime extension, so only the server knows it.
#
# ⚠️ AND THE ONE THING THE SERVER DOES NOT CATCH: an EMPTY SCALAR. Measured — `replicas:` rendered
# empty (YAML null) is ACCEPTED by admission with no error and no defaulting, and a cluster with
# null replicas is not the cluster you asked for. envsubst renders an unset variable as EMPTY, and
# three of the six keys are COMMENTED in .env.example by design (uncommenting them would trip
# check-env-clobber). So the defaults MUST live here, in code, and the rendered YAML is checked for
# empty scalars before the server ever sees it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

load_env
require_cmd kubectl
require_cmd envsubst "install gettext (make deps)"

# --- the six topology keys + their code-side defaults ------------------------------------------
# ⚠️ VKS_NODE_COUNT defaults to 2, NOT the 1 shown in .env.example's example line. .env.example
# itself says, four lines under that example: "🔴 AND THE DEFAULT BELOW IS TOO SMALL. MEASURED on a
# real 9.1 lab: ONE best-effort-small worker is 10m SHORT of the platform — allocatable 1930m,
# platform requests 1840m (95%), tekton-pipelines-webhook wants 100m -> FailedScheduling." A default
# that contradicts its own measured warning is a trap, so the code takes the measured floor.
export VKS_CLUSTER_NAME="${VKS_CLUSTER_NAME:?set VKS_CLUSTER_NAME in .env (the guest cluster to create)}"
export VKS_NAMESPACE="${VKS_NAMESPACE:?set VKS_NAMESPACE in .env (the vSphere Namespace it lives in)}"
export VKS_CLUSTERCLASS="${VKS_CLUSTERCLASS:-builtin-generic-v3.6.0}"
export VKS_CLUSTERCLASS_NAMESPACE="${VKS_CLUSTERCLASS_NAMESPACE:-vmware-system-vks-public}"
export VKS_K8S_VERSION="${VKS_K8S_VERSION:?set VKS_K8S_VERSION in .env (a PREFIX; admission resolves it to a TKr)}"
export VKS_VM_CLASS="${VKS_VM_CLASS:-best-effort-small}"
export VKS_STORAGE_CLASS="${VKS_STORAGE_CLASS:-wcp-vmfs}"
export VKS_CONTROL_PLANE_COUNT="${VKS_CONTROL_PLANE_COUNT:-1}"
export VKS_NODE_COUNT="${VKS_NODE_COUNT:-2}"
# Node ephemeral storage. Default 50 GiB each -- NOT copied from a cloud vendor's default, but
# sized from what we measured: six builder images are 4.44 GiB before Kaniko, six app runtimes,
# Tekton, Istio and six builds' writable layers, against a stock 19.3 GiB node whose kubelet evicts
# below ~2.9 GiB free. 50 keeps steady-state well under the 85% image-GC trigger rather than merely
# under the eviction threshold. See the long comment in k8s/vks/cluster.yaml for the failure this
# prevents and for why BOTH volumes must be mounted.
export VKS_NODE_CONTAINERD_GIB="${VKS_NODE_CONTAINERD_GIB:-50}"
export VKS_NODE_KUBELET_GIB="${VKS_NODE_KUBELET_GIB:-50}"
export VKS_POD_CIDR="${VKS_POD_CIDR:-172.20.0.0/16}"
export VKS_SERVICE_CIDR="${VKS_SERVICE_CIDR:-172.21.0.0/16}"

# The Cluster lives on the SUPERVISOR, never on the guest. Using the ambient KUBECONFIG here would
# apply it to whatever the guest kubeconfig points at (or, mid-rebuild, to nothing at all).
# ⚠️ Do NOT reach for ARGOCD_KUBECONFIG here even though it also points at a Supervisor. It is a
# SEPARATE artifact with its own lifetime (fetch-argocd-kubeconfig writes it), and on a rebuilt lab
# it is routinely the stale one while secrets/supervisor.kubeconfig was just refreshed by
# `make vks-login`. Preferring it would apply the Cluster through a dead credential and report a
# TLS error that names neither file.
# ⚠️ VKS_SUPERVISOR_KUBECONFIG is the ONLY name — that is what the WRITER (30-vks-login.sh)
# honours. An unprefixed SUPERVISOR_KUBECONFIG alias existed until 2026-08-24. MEASURED against git
# history (2790ef7, #479): these readers accepted BOTH, prefixed first — so the alias was reachable
# only by an operator who explicitly set the UNPREFIXED one, which the writer never wrote. Setting
# the prefixed name always agreed. Collapsed to one name; do not reintroduce a second.
SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"   # lib/os.sh: ONE resolver, first that EXISTS
[ -f "$SUP" ] || { supervisor_kubeconfig_hint >&2; die "no Supervisor kubeconfig — see the search order above"; }
k() { kubectl --kubeconfig "$SUP" "$@"; }

log_info "cluster:      ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}"
# ⚠️ THIS IS WHAT WE ASKED FOR, NOT WHAT YOU WILL GET. MEASURED 2026-08-26 on VKS 3.7.1+v1.36:
# the Supervisor's mutating webhook (capi.mutating.tanzukubernetescluster.run.tanzu.vmware.com)
# REWRITES this to the newest compatible ClusterClass -- and it does so even when the class we asked
# for is already IN RANGE (asked v3.6.0 + v1.35.6, which v3.6.0 supports; stored v3.7.0). So
# VKS_CLUSTERCLASS is INERT, not merely stale, and computing a "better" value here would only
# produce something admission discards. The class is READ BACK after the apply below; that read, not
# this line, is the ground truth -- exactly as k8s/vks/cluster.yaml:21-28 already says for the
# VERSION. Logging only this line is how a green certification records the wrong class. (B490)
log_info "class:        ${VKS_CLUSTERCLASS} (ns ${VKS_CLUSTERCLASS_NAMESPACE}) — REQUESTED; admission may rewrite it"
log_info "version:      ${VKS_K8S_VERSION}   (a PREFIX — admission resolves and REWRITES it)"
log_info "topology:     ${VKS_CONTROL_PLANE_COUNT} control plane + ${VKS_NODE_COUNT} worker(s) of ${VKS_VM_CLASS}"
log_info "storage:      ${VKS_STORAGE_CLASS}"
log_info "supervisor:   ${SUP}"

# --- refuse to clobber -------------------------------------------------------------------------
# `kubectl apply` over an existing Cluster is a successful no-op ("unchanged", exit 0) — which is
# NOT "the cluster I asked for". Report what is actually there and stop.
if k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >/dev/null 2>&1; then
  # ⚠️ SECOND EFFECT, worth naming: this also stops a re-apply from letting the mutating webhook
  # bump a LIVE cluster's ClusterClass and roll its nodes. That is a rebase, not a create, and it is
  # not something a re-run should do by accident. To move onto a newer class deliberately, create a
  # cluster under a NEW name (see the reused-name note below) rather than re-applying over this one.
  log_warn "${VKS_NAMESPACE}/${VKS_CLUSTER_NAME} ALREADY EXISTS — not re-applying."
  k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >&2
  log_info "inspect it with:  make vks-cluster-status"
  exit 0
fi

# --- render ------------------------------------------------------------------------------------
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
envsubst < "${REPO_ROOT}/k8s/vks/cluster.yaml" > "$RENDERED"

# THE EMPTY-SCALAR CHECK LIVED HERE AND HAS BEEN REMOVED — it was UNREACHABLE, and it cost Photon.
#
# It shelled out to python3 to walk template and render in lockstep looking for a `${VAR}` line that
# rendered empty. Two measurements retired it:
#
#  1. IT COULD NOT FIRE FROM OPERATOR INPUT. Every template variable is bound below with `:?` or
#     `:-`, and BOTH treat an empty value as unset — so `VKS_NODE_COUNT= VKS_VM_CLASS=` still
#     renders the defaults. The only state it could detect was TEMPLATE DRIFT (someone adds a
#     `${VAR}` to k8s/vks/cluster.yaml that this script never binds), which is a commit-time defect,
#     not a runtime one — and its die told the operator to "set the missing VKS_* value in .env",
#     advice for a state that cannot occur.
#  2. python3 IS NOT ON A PHOTON JUMP BOX. MEASURED 2026-08-09 walking scenario-1 on a bare
#     photon:5.0 container against a real 9.1 lab: `make vks-cluster-create` died
#     `line 112: python3: command not found` (rc 127) — seconds after `make check-tools` printed
#     "all REQUIRED tools present." This repo has ALREADY had this incident once (see lib/os.sh's
#     pick_port note) and recorded the resolution then: DEGRADE, and do NOT add python3 to the
#     documented OS floor, because that floor is provisioned BY HAND on a box with no internet.
#
# Drift is now asserted OFFLINE by scripts/check-cluster-template-vars.sh (wired into static-check),
# where it can fail the commit that introduces it instead of a lab run twenty minutes in.
for v in VKS_CLUSTER_NAME VKS_NAMESPACE VKS_CLUSTERCLASS VKS_K8S_VERSION VKS_VM_CLASS \
         VKS_STORAGE_CLASS VKS_CONTROL_PLANE_COUNT VKS_NODE_COUNT; do
  printenv "$v" >/dev/null 2>&1 || die "$v is not EXPORTED — envsubst reads the ENVIRONMENT, so it would render EMPTY."
done

# --- validate against the real server, then apply ----------------------------------------------
log_info "validating against the Supervisor (server-side dry-run — persists nothing)..."
if ! k apply --dry-run=server -f "$RENDERED" >/dev/null 2>"${RENDERED}.err"; then
  log_error "the Supervisor REJECTED this cluster. Its own words (they name the exact field):"
  sed 's/^/    /' "${RENDERED}.err" >&2
  rm -f "${RENDERED}.err"
  die "fix the value it names in .env, then re-run."
fi
# ⚠️ DO NOT rm THIS UNREAD ON SUCCESS. The dry-run's stderr is where the platform says it rewrote
# something -- "Warning: ClusterClass builtin-generic-v3.6.0 updated to the newest compatible
# ClusterClass builtin-generic-v3.7.0" arrives on a run whose rc is 0. Discarding it made the one
# path built to catch surprises silently throw away the only notice of one.
if [ -s "${RENDERED}.err" ]; then
  log_warn "the Supervisor accepted this, WITH remarks (rc=0, so these are not errors):"
  sed 's/^/    /' "${RENDERED}.err" >&2
fi
rm -f "${RENDERED}.err"
log_info "dry-run accepted."

k apply -f "$RENDERED"

# --- READ BACK what the platform actually stored --------------------------------------------------
# The ground truth is the object, never what we rendered. `|| true` because a failed read must not
# kill a successful create: this is a REPORT, and a create that worked stays worked.
_stored_class="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
                   -o jsonpath='{.spec.topology.classRef.name}' 2>/dev/null || true)"
if [ -z "$_stored_class" ]; then
  log_warn "could not read back .spec.topology.classRef.name — the class in effect is UNCONFIRMED."
elif [ "$_stored_class" != "$VKS_CLUSTERCLASS" ]; then
  log_warn "ClusterClass in effect is ${_stored_class}, NOT the ${VKS_CLUSTERCLASS} requested —"
  log_warn "  the Supervisor rewrote it to the newest compatible class. This is normal and is why"
  log_warn "  VKS_CLUSTERCLASS is a seed rather than a setting. Cite ${_stored_class} in any report."
else
  log_info "class in effect: ${_stored_class} (confirmed on the created object)"
fi
log_info "applied. MEASURED 2026-08-08 on a single-host 9.1 lab: all 3 nodes Ready in ~3m45s"
log_info "  (1 CP + 2 best-effort-small workers). Yours varies with host load and image pulls."

# --- FAIL FAST on a stale control-plane endpoint ------------------------------------------------
# THE FAILURE THIS CATCHES, and why it is worth 90 seconds here: the platform writes
# spec.controlPlaneEndpoint BEFORE the VirtualMachineService that owns the control-plane LB exists
# (MEASURED: endpoint at 04:32:17, VMService at 04:32:21 — a 4-second lead), so the value is a
# PREDICTION. When it predicts wrong, CAPI never revisits it — spec.controlPlaneEndpoint does not
# self-heal — so the cluster advertises an address nothing serves, the remote-connection probe fails
# forever. `make vks-cluster-status` used to burn its FULL wait (measured: 1807s) before saying so;
# since B92 its waiting form reads the endpoint ONCE up front and refuses in 0s instead.
#
# THE CAUSE IS A REUSED NAME, and that is measured, not inferred. Five incarnations of the SAME name
# in the same vSphere Namespace: #1 (on a lab where the name was new) agreed and went Ready in
# 3m45s; #2..#5 each advertised the PREVIOUS incarnation's LB IP and never converged. Then the
# discriminating experiment, on the SAME already-used lab with NO rebuild: a cluster created under a
# NEVER-USED name agreed on its first read (adv .142 == svc .142) and the reused name beside it was
# still diverged. So the fix is the NAME, not lab freshness — which matters because "rebuild the
# lab" costs 25-45 minutes and is not available to a tenant on someone else's Supervisor.
#
# This gate does NOT try to repair it (the field is immutable) and does NOT delete anything: it
# reports, with the one remedy that is measured to work. It only ever fires on a divergence it can
# actually see — an unreadable Service list or an unidentifiable LB DECLINES to judge, exactly as
# endpoint_report does, because a diagnostic that can false-RED gets ignored.
_cp_endpoint_check() {
  local i adv lb budget="${VKS_CP_ENDPOINT_WAIT_SECONDS:-90}" _end
  _end=$((SECONDS + budget))
  while [ "$SECONDS" -lt "$_end" ]; do
    adv="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
             -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null || true)"
    # The VirtualMachineService named for the cluster is what OWNS the control-plane LB. Reading it
    # directly (rather than scanning Services) keeps this independent of how many other LoadBalancers
    # the namespace holds. A tenant who cannot read it gets the DECLINE path below, not a false RED.
    lb="$(k -n "$VKS_NAMESPACE" get virtualmachineservice "$VKS_CLUSTER_NAME" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ -n "$adv" ] && [ -n "$lb" ]; then
      if [ "$adv" = "$lb" ]; then
        log_info "control-plane endpoint: AGREE (${adv}) — this cluster can converge."
        return 0
      fi
      log_error "control-plane endpoint is STALE: the Cluster advertises ${adv} but its"
      log_error "  LoadBalancer holds ${lb}. spec.controlPlaneEndpoint is set by the platform and is"
      log_error "  NOT revisited, so this cluster will NEVER become Ready — it would fail the full"
      log_error "  wait (~30 min) instead of failing here."
      log_error "  CAUSE (measured): the name '${VKS_CLUSTER_NAME}' has been used in namespace"
      log_error "  '${VKS_NAMESPACE}' before. The advertised address is the PREVIOUS incarnation's."
      log_error "  FIX: create it under a NAME THAT HAS NEVER BEEN USED here — measured to agree on"
      log_error "  the first read, on an already-used lab, with no rebuild:"
      log_error "      make vks-cluster-create VKS_CLUSTER_NAME=<a-new-name>"
      log_error "  Do NOT delete and recreate under the same name: that reproduced it 4 times running."
      log_error "  CAPTURE FIRST if you want the platform team to see it (deleting destroys it):"
      log_error "      kubectl -n ${VKS_NAMESPACE} get cluster ${VKS_CLUSTER_NAME} -o yaml > /tmp/diverged-cluster.yaml"
      return 1
    fi
    sleep 5
  done
  log_warn "control-plane endpoint: NOT YET KNOWABLE after ${budget}s (advertised='${adv:--}'"
  log_warn "  vmservice='${lb:--}') — DECLINING to judge rather than guess. 'make vks-cluster-status'"
  log_warn "  reports the same comparison, and will say DIVERGENT if it becomes visible."
  return 0
}
_cp_endpoint_check || die "refusing to wait on a cluster that cannot converge (see above)."

log_info "next: make vks-cluster-status   (it gates on the CONDITIONS, not on phase=Provisioned)"
