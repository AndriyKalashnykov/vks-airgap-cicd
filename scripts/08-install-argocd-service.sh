#!/usr/bin/env bash
# 08-install-argocd-service.sh — install ArgoCD as a Supervisor Service, end to end.
#
# Replaces scenario-1 Step 3's browser work (Add New Service -> upload the .yml) and the
# hand-written instance CR in sub-step 3.5. ArgoCD's service takes no data-values, so this
# is register + install + (optionally) create the ArgoCD instance CR.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
# shellcheck source=scripts/lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"
load_env

SRC_DIR="${VCF_CLI_SRC_DIR:-$HOME/Downloads/vcf}"
DEF="$(find "$SRC_DIR" -maxdepth 1 -name 'supervisor-service-argocd-legacy-*.yml' 2>/dev/null | sort | tail -1)"
[ -n "$DEF" ] || die "no supervisor-service-argocd-legacy-*.yml in $SRC_DIR (see docs/scenario-1.md Step 0)"
log_info "service definition: $(basename "$DEF")"

trap vc_logout EXIT
vc_login
MOID="$(vc_cluster_moid "${VKS_CLUSTER_COMPUTE:-}")"
[ -n "$MOID" ] || die "could not resolve the vSphere cluster moid; set VKS_CLUSTER_COMPUTE when vCenter has more than one cluster"
log_info "cluster: $MOID"

CC="$(vc_ss_check_content "$DEF")"
SVC_TYPE="$(printf '%s' "$CC" | cut -d'|' -f1)"
SVC_ID="$(printf '%s'   "$CC" | cut -d'|' -f2)"
SVC_VER="$(printf '%s'  "$CC" | cut -d'|' -f3)"
SVC_STATUS="$(printf '%s' "$CC" | cut -d'|' -f4)"
# VALID_WITH_WARNINGS is what an ALREADY-REGISTERED service reports - it is not a rejection.
case "$SVC_STATUS" in
  VALID|VALID_WITH_WARNINGS) : ;;
  *) die "vCenter rejected $(basename "$DEF"): status=${SVC_STATUS:-unreadable} ($CC)" ;;
esac
[ "$SVC_TYPE" = CARVEL_APPS_YAML ] || die "vCenter classifies $(basename "$DEF") as ${SVC_TYPE}, not CARVEL_APPS_YAML - it would publish a Package and deploy nothing"
[ -n "$SVC_ID" ] && [ -n "$SVC_VER" ] || die "checkContent returned no id/version ('$CC')"
log_info "service: ${SVC_ID} version ${SVC_VER} (${SVC_TYPE}, ${SVC_STATUS})"

if vc_ss_is_registered "$SVC_ID"; then
  log_info "${SVC_ID} is already registered - skipping register (idempotent)"
else
  vc_ss_register "$DEF"; log_info "registered ${SVC_ID}"
fi

vc_ss_install "$MOID" "$SVC_ID" "$SVC_VER"
log_info "install issued for ${SVC_ID}"
state_set ARGOCD_SERVICE_ID "$SVC_ID"

# ── the instance CR (scenario-1 step 3.5) ────────────────────────────────────────────────
# The SERVICE is the operator; the INSTANCE is the ArgoCD you actually log into, and it
# lands in a vSphere Namespace that is often NOT the one the guest cluster lives in --
# which is why ARGOCD_NAMESPACE is its own key.
NS="${ARGOCD_NAMESPACE:-${VKS_NAMESPACE:-}}"
if [ -z "$NS" ]; then
  log_warn "ARGOCD_NAMESPACE (and VKS_NAMESPACE) unset - skipping the ArgoCD instance CR."
  log_warn "  set ARGOCD_NAMESPACE and re-run, or create the CR yourself (scenario-1 step 3.5)."
  exit 0
fi
if [ ! -s "${KUBECONFIG:-/nonexistent}" ]; then
  log_warn "no Supervisor kubeconfig at '${KUBECONFIG:-<unset>}' - skipping the instance CR."
  log_warn "  run 'make vks-login' first, then: make install-argocd-instance"
  exit 0
fi

require_cmd kubectl jq   # the CR path needs both; vc_require only covers the REST side

# The operator publishes the CRD only after its own reconcile; wait rather than race it.
#
# DISTINGUISH "the CRD is not there yet" FROM "we cannot talk to this cluster". MEASURED on a
# REBUILT lab: KUBECONFIG still pointed at the destroyed lab's file, so every probe failed with
#   x509: certificate signed by unknown authority
# and the loop would have spent its whole budget and then blamed the SERVICE INSTALL -- which had
# in fact succeeded. A rebuilt cluster mints a new CA while the address stays the same, so a stale
# kubeconfig looks valid and is not. Only a genuine NotFound is worth waiting on.
_crd_err="$(mktemp)"; trap 'rm -f "$_crd_err"; vc_logout' EXIT
_end=$((SECONDS + ${ARGOCD_CRD_WAIT_SECONDS:-600}))
until kubectl get crd argocds.argocd-service.vsphere.vmware.com >/dev/null 2>"$_crd_err"; do
  case "$(cat "$_crd_err" 2>/dev/null || true)" in
    *NotFound*|*'not found'*) : ;;   # the only reason to keep waiting
    *) _cls="$(classify_kube_failure "$_crd_err" 2>/dev/null || true)"
       log_error "cannot reach the Supervisor to watch for the ArgoCD CRD (${_cls:-unclassified}):"
       sed 's/^/    /' "$_crd_err" >&2
       die "the SERVICE INSTALL SUCCEEDED - this is your kubeconfig, not the install.
  '${KUBECONFIG}' does not work against this cluster. A REBUILT cluster mints a new CA while the
  address stays the same, so a stale kubeconfig looks valid and is not. Re-issue it, then re-run
  this (it is idempotent and skips straight to the instance CR):
      make vks-login" ;;
  esac
  [ "$SECONDS" -lt "$_end" ] || die "the ArgoCD CRD never appeared within ${ARGOCD_CRD_WAIT_SECONDS:-600}s, though the cluster IS reachable - the service install did not finish publishing it"
  sleep 10
done
log_info "ArgoCD CRD is present"

# Ask the OPERATOR what it supports rather than hardcoding a version that rots. Prefer the
# CRD's own schema enum -- structured and unambiguous. `kubectl explain` is PROSE: its output
# also carries the apiVersion and free text, so a "first number-like token" scrape can pick up
# something that is not a version at all, and the CR then fails admission for a reason that
# names the version rather than the scrape that produced it.
VER="${ARGOCD_INSTANCE_VERSION:-}"
CRD=argocds.argocd-service.vsphere.vmware.com
if [ -z "$VER" ]; then
  VER="$(kubectl get crd "$CRD" -o json 2>/dev/null \
        | jq -r '[.spec.versions[]?.schema.openAPIV3Schema.properties.spec.properties.version.enum[]?] | last // empty' 2>/dev/null || true)"
  [ -n "$VER" ] && log_info "version from the CRD schema enum: ${VER}"
fi
if [ -z "$VER" ]; then
  VER="$(kubectl explain "argocd.spec.version" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -1 || true)"
  [ -n "$VER" ] && log_warn "no enum in the CRD schema; scraped '${VER}' from kubectl explain - verify it is a real version"
fi
[ -n "$VER" ] || die "could not determine a supported ArgoCD version.
  Set ARGOCD_INSTANCE_VERSION explicitly. What the operator supports:
    kubectl get crd ${CRD} -o json | jq '.spec.versions[].schema.openAPIV3Schema.properties.spec.properties.version'
    kubectl explain argocd.spec.version"

kubectl apply -f - <<YAML
apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
kind: ArgoCD
metadata:
  name: ${ARGOCD_INSTANCE_NAME:-argocd-1}
  namespace: ${NS}
spec:
  version: ${VER}
YAML
log_info "ArgoCD instance ${ARGOCD_INSTANCE_NAME:-argocd-1} requested in namespace ${NS} (version ${VER})"
log_info "next: make argocd-preflight   (reports CLI vs RUNNING server vs supported versions)"
