#!/usr/bin/env bash
# 04-vsphere-namespace.sh — create the vSphere Namespace (scenario-1 Step 1b) over REST.
#
# Replaces the browser walk: vCenter -> Workload Management -> Namespaces -> New Namespace,
# then attaching a storage policy and a VM class by hand.
#
# IDEMPOTENT: creates when absent; when present it reports and does NOT rewrite. A blind
# PATCH is deliberately avoided -- VMServiceSpec.vmClasses is documented as "if this field
# is empty in an updated specification, all VirtualMachineClasses currently associated with
# the namespace will be disassociated" -- i.e. a careless converge STRIPS a class an admin
# added by hand.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
load_env

NS="${VKS_NAMESPACE:?VKS_NAMESPACE is not set - the vSphere Namespace to create}"
# ⚠️ NOT `:?` HERE. This script has two paths and only ONE uses the policy: if the namespace
# already exists we print what is attached and exit 0 without touching it. Binding with `:?`
# at the top demanded a value on the path documented as scenario-1 1b "If you already have
# one" -- where it is never read. MEASURED 2026-08-10: that is what sent an operator hunting
# through a 12-entry policy list for a value nobody wanted. The requirement now fires on the
# CREATE path only, below.
POLICY_NAME="${VKS_STORAGE_POLICY:-}"
CLASSES="${VKS_VM_CLASSES:-best-effort-small best-effort-medium}"

trap vc_logout EXIT
vc_login

# Already there? Say so and stop -- this is the "existing namespace" branch of Step 1b.
if body="$(vc_api GET "/api/vcenter/namespaces/instances/${NS}")"; then
  st="$(printf '%s' "$body" | jq -r '.config_status // "UNKNOWN"')"
  log_info "vSphere Namespace '${NS}' already exists (config_status=${st}) - not rewriting it."
  printf '%s' "$body" | jq -r '"  vm_classes : " + ([.vm_service_spec.vm_classes[]?]|join(", "))' 2>/dev/null || true
  # ⚠️ .storage_specs[].policy is an ID, not a name (the create spec below is built from
  # /api/vcenter/storage/policies' `.policy` field). Printing the raw UUID made the one place that
  # KNOWS which policies this namespace uses render the answer unusably, so the operator went
  # hunting anyway. Resolve ID -> NAME, PLURAL (the API takes a list; an admin may attach several).
  # vCenter REST only, so this works BEFORE any kubeconfig exists -- the whole point at step 1b.
  _pol_ids="$(printf '%s' "$body" | jq -r '[.storage_specs[]?.policy]|join(" ")' 2>/dev/null || true)"
  if [ -n "$(printf '%s' "$_pol_ids" | tr -d ' ')" ]; then
    _all="$(vc_api GET /api/vcenter/storage/policies 2>/dev/null || true)"
    _names=""
    for _id in $_pol_ids; do
      _n="$(printf '%s' "$_all" | jq -r --arg i "$_id" '.[]|select(.policy==$i)|.name' 2>/dev/null | head -1)"
      _names="${_names}${_names:+, }${_n:-$_id}"
    done
    log_info "  policies   : ${_names}"
    log_info "  -> that is your VKS_STORAGE_POLICY. Do NOT derive it from the storage CLASS name:"
    log_info "     the class is the policy lowercased with spaces as dashes, and that is NOT invertible."
  fi
  exit 0
fi
# vc_last_code(), NOT $VC_LAST_CODE: the GET above ran inside `body="$(...)"` -- a subshell --
# so the variable never made it back here.
code="$(vc_last_code)"
[ "$code" = 404 ] || die "GET namespaces/instances/${NS} -> HTTP ${code:-<none>} (404 means absent; 401 means the session expired, 503 that the vAPI is still warming)"

# ── resolve the cluster moid ─────────────────────────────────────────────────────────────
CLUSTER_NAME="${VKS_CLUSTER_COMPUTE:-}"
clusters="$(vc_api GET /api/vcenter/cluster || die "cannot list clusters (HTTP $(vc_last_code))")"
if [ -n "$CLUSTER_NAME" ]; then
  MOID="$(printf '%s' "$clusters" | jq -r --arg n "$CLUSTER_NAME" '.[]|select(.name==$n)|.cluster' | head -1)"
  [ -n "$MOID" ] || die "no vSphere cluster named '${CLUSTER_NAME}'. Available: $(printf '%s' "$clusters" | jq -r '[.[].name]|join(", ")')"
else
  n="$(printf '%s' "$clusters" | jq -r 'length')"
  [ "$n" = 1 ] || die "vCenter has ${n} clusters - set VKS_CLUSTER_COMPUTE to the one hosting the Supervisor. Available: $(printf '%s' "$clusters" | jq -r '[.[].name]|join(", ")')"
  MOID="$(printf '%s' "$clusters" | jq -r '.[0].cluster')"
  CLUSTER_NAME="$(printf '%s' "$clusters" | jq -r '.[0].name')"
fi
log_info "cluster: ${CLUSTER_NAME} (${MOID})"

# ── resolve the storage policy id ────────────────────────────────────────────────────────
# The CREATE path is the only one that needs a policy -- demand it HERE, not at the top (see above).
policies="$(vc_api GET /api/vcenter/storage/policies || die "cannot list storage policies (HTTP $(vc_last_code))")"
[ -n "$POLICY_NAME" ] || die "VKS_STORAGE_POLICY is not set - the vCenter storage policy to attach.
  It is a PER-LAB value, not a constant: two real labs measured 'wcp-vmfs' (single-host VMFS) and
  'vsan-default-storage-policy' (vSAN). Yours is one of:
    $(printf '%s' "$policies" | jq -r '[.[].name]|join(", ")')
  If a namespace on this vCenter already uses one, run this against it - it prints the attached
  policy BY NAME."
PID="$(printf '%s' "$policies" | jq -r --arg n "$POLICY_NAME" '.[]|select(.name==$n)|.policy' | head -1)"
[ -n "$PID" ] || die "no storage policy named '${POLICY_NAME}'. Available: $(printf '%s' "$policies" | jq -r '[.[].name]|join(", ")')"
log_info "storage policy: ${POLICY_NAME} (${PID})"

# ── create ───────────────────────────────────────────────────────────────────────────────
# `limit` is OMITTED, never 0: StorageSpec.limit is in MEBIBYTES and "if null, no limits are
# placed" -- sending 0 would create a zero-byte quota in which every PVC fails, which reads
# like a CSI fault rather than a quota.
classes_json="$(printf '%s' "$CLASSES" | tr ' ' '\n' | jq -R -s -c 'split("\n")|map(select(length>0))')"
spec="$(jq -nc --arg ns "$NS" --arg c "$MOID" --arg p "$PID" --argjson vc "$classes_json" \
  '{namespace:$ns, cluster:$c, storage_specs:[{policy:$p}], vm_service_spec:{vm_classes:$vc}}')"
req="$(mktemp)"; chmod 600 "$req"; printf '%s' "$spec" > "$req"
vc_api POST /api/vcenter/namespaces/instances --data-binary "@${req}" >/dev/null \
  || { rm -f "$req"; die "create namespace '${NS}' -> HTTP $(vc_last_code)"; }
rm -f "$req"
log_info "created vSphere Namespace '${NS}' with policy ${POLICY_NAME} and classes: ${CLASSES}"

# ── wait for it to be usable ─────────────────────────────────────────────────────────────
# RUNNING is the readiness signal; the namespace object exists before it can accept work.
_end=$((SECONDS + ${VKS_NAMESPACE_WAIT_SECONDS:-300}))
until st="$(vc_api GET "/api/vcenter/namespaces/instances/${NS}" | jq -r '.config_status // "UNKNOWN"')"; [ "$st" = RUNNING ]; do
  [ "$SECONDS" -lt "$_end" ] || die "namespace '${NS}' did not reach RUNNING within ${VKS_NAMESPACE_WAIT_SECONDS:-300}s (last: ${st:-unknown})"
  sleep 10
done
log_info "namespace '${NS}' is RUNNING"
