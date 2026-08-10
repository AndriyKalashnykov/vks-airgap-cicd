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
POLICY_NAME="${VKS_STORAGE_POLICY:?VKS_STORAGE_POLICY is not set - the storage policy to attach (vCenter name, e.g. 'vmfs-storage-policy')}"
CLASSES="${VKS_VM_CLASSES:-best-effort-small best-effort-medium}"

trap vc_logout EXIT
vc_login

# Already there? Say so and stop -- this is the "existing namespace" branch of Step 1b.
if body="$(vc_api GET "/api/vcenter/namespaces/instances/${NS}")"; then
  st="$(printf '%s' "$body" | jq -r '.config_status // "UNKNOWN"')"
  log_info "vSphere Namespace '${NS}' already exists (config_status=${st}) - not rewriting it."
  printf '%s' "$body" | jq -r '"  vm_classes : " + ([.vm_service_spec.vm_classes[]?]|join(", "))' 2>/dev/null || true
  printf '%s' "$body" | jq -r '"  policies   : " + ([.storage_specs[]?.policy]|join(", "))'    2>/dev/null || true
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
policies="$(vc_api GET /api/vcenter/storage/policies || die "cannot list storage policies (HTTP $(vc_last_code))")"
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
