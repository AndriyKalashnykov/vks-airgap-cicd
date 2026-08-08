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
export VKS_POD_CIDR="${VKS_POD_CIDR:-172.20.0.0/16}"
export VKS_SERVICE_CIDR="${VKS_SERVICE_CIDR:-172.21.0.0/16}"

# The Cluster lives on the SUPERVISOR, never on the guest. Using the ambient KUBECONFIG here would
# apply it to whatever the guest kubeconfig points at (or, mid-rebuild, to nothing at all).
# ⚠️ Do NOT reach for ARGOCD_KUBECONFIG here even though it also points at a Supervisor. It is a
# SEPARATE artifact with its own lifetime (fetch-argocd-kubeconfig writes it), and on a rebuilt lab
# it is routinely the stale one while secrets/supervisor.kubeconfig was just refreshed by
# `make vks-login`. Preferring it would apply the Cluster through a dead credential and report a
# TLS error that names neither file.
# ⚠️ VKS_SUPERVISOR_KUBECONFIG FIRST — that is the name the WRITER (30-vks-login.sh)
# honours. These readers used only SUPERVISOR_KUBECONFIG; the defaults coincide, so the
# split was invisible on the box that measured it and would have split the moment an
# operator set either one.
SUP="${VKS_SUPERVISOR_KUBECONFIG:-${SUPERVISOR_KUBECONFIG:-${REPO_ROOT}/secrets/supervisor.kubeconfig}}"
[ -f "$SUP" ] || die "no Supervisor kubeconfig at '$SUP' — run 'make vks-login' first (it writes one)."
k() { kubectl --kubeconfig "$SUP" "$@"; }

log_info "cluster:      ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}"
log_info "class:        ${VKS_CLUSTERCLASS} (ns ${VKS_CLUSTERCLASS_NAMESPACE})"
log_info "version:      ${VKS_K8S_VERSION}   (a PREFIX — admission resolves and REWRITES it)"
log_info "topology:     ${VKS_CONTROL_PLANE_COUNT} control plane + ${VKS_NODE_COUNT} worker(s) of ${VKS_VM_CLASS}"
log_info "storage:      ${VKS_STORAGE_CLASS}"
log_info "supervisor:   ${SUP}"

# --- refuse to clobber -------------------------------------------------------------------------
# `kubectl apply` over an existing Cluster is a successful no-op ("unchanged", exit 0) — which is
# NOT "the cluster I asked for". Report what is actually there and stop.
if k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >/dev/null 2>&1; then
  log_warn "${VKS_NAMESPACE}/${VKS_CLUSTER_NAME} ALREADY EXISTS — not re-applying."
  k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" >&2
  log_info "inspect it with:  make vks-cluster-status"
  exit 0
fi

# --- render ------------------------------------------------------------------------------------
RENDERED="$(mktemp)"; trap 'rm -f "$RENDERED"' EXIT
envsubst < "${REPO_ROOT}/k8s/vks/cluster.yaml" > "$RENDERED"

# THE EMPTY-SCALAR CHECK — the one thing the server does not do for us (see the header).
#
# ⚠️ Compare ONLY the lines that CARRIED a substitution. A naive "flag any line ending in ':'"
# flags every legitimate parent key (spec:, metadata:, topology:) and every comment, so it fires on
# a perfectly good render and teaches the operator to ignore it. Walking template and output in
# lockstep is exact: a line that held `${VAR}` and now holds nothing after the colon is the defect,
# and nothing else is.
_empties="$(python3 - "$RENDERED" "${REPO_ROOT}/k8s/vks/cluster.yaml" <<'PY'
import sys
rendered = open(sys.argv[1]).read().splitlines()
template = open(sys.argv[2]).read().splitlines()
bad = []
for i, (t, r) in enumerate(zip(template, rendered), 1):
    ts = t.lstrip()
    if ts.startswith('#') or '${' not in t:
        continue                      # only lines that actually had a substitution
    # the value is whatever follows the first ':' (or '- ' for a list item)
    if ':' in r:
        val = r.split(':', 1)[1].strip()
    elif r.lstrip().startswith('-'):
        val = r.lstrip()[1:].strip()
    else:
        val = r.strip()
    if val == '':
        bad.append('%d: %s' % (i, t.strip()))
print('\n'.join(bad))
PY
)"
if [ -n "$_empties" ]; then
  log_error "the rendered manifest has an EMPTY value where a variable should be — envsubst renders"
  log_error "an unset variable as empty, and admission ACCEPTS an empty replicas without complaint:"
  printf '%s\n' "$_empties" | sed 's/^/    /' >&2
  die "set the missing VKS_* value in .env, or let this script default it."
fi
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
rm -f "${RENDERED}.err"
log_info "dry-run accepted."

k apply -f "$RENDERED"
log_info "applied. MEASURED 2026-08-08 on a single-host 9.1 lab: all 3 nodes Ready in ~3m45s"
log_info "  (1 CP + 2 best-effort-small workers). Yours varies with host load and image pulls."
log_info "next: make vks-cluster-status   (it gates on the CONDITIONS, not on phase=Provisioned)"
