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
# The version pick below needs jq HERE -- this script's own require_cmd is 60+ lines further down,
# and without an earlier guard a missing jq surfaces as "no such file in $SRC_DIR": the wrong cause.
require_cmd jq
DEF="$(newest_versioned_file "$SRC_DIR" 'supervisor-service-argocd-legacy-*.yml' || true)"
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
# ⚠️ RESOLVE THE SUPERVISOR KUBECONFIG EXPLICITLY -- do NOT read $KUBECONFIG.
# MEASURED 2026-08-10 walking scenario-1 on a rebuilt lab: this read $KUBECONFIG and there is NO
# POINT IN THE DOCUMENTED FLOW WHERE THAT IS THE SUPERVISOR. Step 3 (here) runs before the reader
# is told to set it, and from Step 4 on the doc points it at the GUEST cluster. So `make vks-login`
# wrote secrets/supervisor.kubeconfig, this step looked for './secrets/<cluster>.kubeconfig', found
# nothing, and printed "run 'make vks-login' first" -- to an operator who had just run it
# successfully. The instance CR was then never created, silently, exit 0.
#
# The five sibling scripts that need the Supervisor already resolve it this way
# (25-vks-cluster-create.sh, 26-vks-cluster-status.sh, 27-harbor-ca-from-cluster.sh,
# 31-fetch-argocd-kubeconfig.sh, 98-uninstall-all.sh) -- 25's own comment notes that $KUBECONFIG
# "is routinely the stale one while secrets/supervisor.kubeconfig was just refreshed". This file
# was the odd one out.
SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"   # lib/os.sh: ONE resolver, first that EXISTS
if [ ! -s "$SUP" ]; then
  { supervisor_kubeconfig_hint >&2; log_warn "no Supervisor kubeconfig — skipping the instance CR (search order above)."; }
  log_warn "  run 'make vks-login' first, then: make install-argocd-service"
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
until kubectl --kubeconfig "$SUP" get crd argocds.argocd-service.vsphere.vmware.com >/dev/null 2>"$_crd_err"; do
  case "$(cat "$_crd_err" 2>/dev/null || true)" in
    *NotFound*|*'not found'*) : ;;   # the only reason to keep waiting
    *) _cls="$(classify_kube_failure "$_crd_err" 2>/dev/null || true)"
       log_error "cannot reach the Supervisor to watch for the ArgoCD CRD (${_cls:-unclassified}):"
       sed 's/^/    /' "$_crd_err" >&2
       die "the SERVICE INSTALL SUCCEEDED - this is your kubeconfig, not the install.
  '${SUP}' does not work against this cluster. A REBUILT cluster mints a new CA while the
  address stays the same, so a stale kubeconfig looks valid and is not. Re-issue it, then re-run
  this (it is idempotent and skips straight to the instance CR):
      make vks-login" ;;
  esac
  [ "$SECONDS" -lt "$_end" ] || die "the ArgoCD CRD never appeared within ${ARGOCD_CRD_WAIT_SECONDS:-600}s, though the cluster IS reachable - the service install did not finish publishing it"
  sleep 10
done
log_info "ArgoCD CRD is present"

# RESOLVE THE INSTANCE VERSION, authoritatively. MEASURED on a real 9.1 Supervisor:
#   * the CRD carries NO enum -- only a `pattern` and a description;
#   * `kubectl explain` prints the pattern and a QUOTED EXAMPLE, and a naive scrape returns
#     `3.0.19+vmware.1-vks.1"` -- WITH THE TRAILING QUOTE -- which admission then rejects,
#     naming the version rather than the scrape that produced it;
#   * the real answer is the Carvel PACKAGE the operator publishes: that is what is
#     installable, whereas the description's example is just prose.
VER="${ARGOCD_INSTANCE_VERSION:-}"
CRD=argocds.argocd-service.vsphere.vmware.com
_crd_json="$(kubectl --kubeconfig "$SUP" get crd "$CRD" -o json 2>/dev/null || true)"
_vschema="$(printf '%s' "$_crd_json" | jq -c '.spec.versions[]?.schema.openAPIV3Schema.properties.spec.properties.version // empty' 2>/dev/null | head -1 || true)"
_pattern="$(printf '%s' "$_vschema" | jq -r '.pattern // empty' 2>/dev/null || true)"

if [ -z "$VER" ]; then   # 1. an enum, if this operator ever grows one
    # `| last` with NO ordering: whichever the CRD happens to list LAST wins. MEASURED over the
    # three versions this lab offers, in three document orders: 3.0.9 / 3.0.2 / 3.0.19 -- two of
    # three pick an OLDER ArgoCD, i.e. strictly worse than the lexicographic sort below it. And this
    # branch runs FIRST, so it wins. Dormant only while the 9.1 CRD carries no enum.
  VER="$(printf '%s' "$_vschema" | jq -r "$(vkey_jq)"' [.enum[]?] | map(select(type=="string")) | sort_by(vkey) | last // empty' 2>/dev/null || true)"
  [ -n "$VER" ] && log_info "version from the CRD schema enum: ${VER}"
fi
if [ -z "$VER" ]; then   # 2. the Carvel Package the operator actually published
  # ⚠️ POLL, do not single-shot. The CRD and the Package are published by the SAME operator but NOT
  # at the same moment, and the gap is long enough to lose a race deterministically on a fresh lab.
  #
  # MEASURED to the second, 2026-08-11, on a lab built ~30 minutes earlier:
  #     20:36:02  the argocds CRD is created
  #     20:36:08  this script logs "ArgoCD CRD is present"
  #     20:36:10  this script died here
  #     20:36:11  the Carvel Package appears        <-- ONE SECOND after we gave up
  # So `make install-argocd-service` failed on a lab where nothing was wrong, and the FATAL sent the
  # operator to run a kubectl query BY HAND and re-invoke with ARGOCD_INSTANCE_VERSION -- for a value
  # that would have been there had we blinked. Waiting for the CRD and not for the Package was the
  # whole bug: the CRD's presence PROVES the operator is mid-publish, so the Package is coming.
  #
  # The `die` below still fires if it genuinely never appears, so this trades a deterministic false
  # failure for a bounded wait, not for a silent guess.
  _pkg_end=$((SECONDS + ${ARGOCD_PACKAGE_WAIT_SECONDS:-180}))
  while :; do
    VER="$(kubectl --kubeconfig "$SUP" get packages.data.packaging.carvel.dev -A -o json 2>/dev/null \
          | jq -r "$(vkey_jq)"' [.items[]? | select(.spec.refName == "argocd.kubernetes.vmware.com") | (.spec.version // "")] | map(select((type=="string") and length>0)) | sort_by(vkey) | last // empty' 2>/dev/null || true)"
    [ -n "$VER" ] && { log_info "version from the published Carvel Package: ${VER}"; break; }
    [ "$SECONDS" -lt "$_pkg_end" ] || break
    log_info "waiting for the ArgoCD Carvel Package to be published (the CRD is already here)..."
    sleep 5
  done
fi
# NO THIRD FALLBACK, deliberately. `kubectl explain` is PROSE formatted for humans: it prints
# the pattern and a QUOTED example, and scraping it returned `3.0.19+vmware.1-vks.1"` -- with the
# quote -- which admission then rejected while naming the VERSION rather than the scrape.
# Its layout and quoting are free to change between kubectl releases. Guessing from prose to
# avoid stopping is how you ship a wrong value; stopping with the two structured queries is
# strictly better for the operator.
[ -n "$VER" ] || die "could not determine which ArgoCD version this operator offers.
  The CRD schema carried no enum, and no Carvel Package appeared in ${ARGOCD_PACKAGE_WAIT_SECONDS:-180}s
  (the CRD IS present, so the operator started publishing and then did not finish). This deliberately
  does NOT guess from 'kubectl explain' (that is prose, and scraping it has already produced an
  invalid value). Set it explicitly:
    kubectl --kubeconfig ${SUP} get packages.data.packaging.carvel.dev -A | grep argocd.kubernetes
    make install-argocd-service ARGOCD_INSTANCE_VERSION=<the VERSION column>"

# VALIDATE before applying. The CRD tells us the exact shape it will accept, so a bad value
# becomes a legible error here instead of an admission rejection that blames the version.
# ⚠️ The CRD's pattern is PCRE/ECMA (`\d`), and grep -E is POSIX ERE, which has NO `\d` --
# so validating it verbatim FALSE-REJECTS every correct version. MEASURED: the pattern
# ^(\d+)\.(\d+)\.(\d+)\+vmware\.(\d+)-vks\.(\d+)$ failed to match 3.0.19+vmware.1-vks.1.
# Translate the two classes ERE lacks; if anything else PCRE-only survives, SKIP the check
# rather than block a value the API would have accepted.
if [ -n "$_pattern" ]; then
  _ere="$(printf '%s' "$_pattern" | sed -e 's/\\d/[0-9]/g' -e 's/\\w/[A-Za-z0-9_]/g' -e 's/\\s/[[:space:]]/g')"
  case "$_ere" in
    *\\[A-Za-z]*|*"(?"*)
      log_warn "the CRD's version pattern uses constructs POSIX ERE cannot express - skipping local validation" ;;
    *)
      printf '%s' "$VER" | grep -qE "$_ere" || die "resolved ArgoCD version '${VER}' does not match what the CRD accepts (${_pattern}).
  Set ARGOCD_INSTANCE_VERSION to one of:
    kubectl --kubeconfig ${SUP} get packages.data.packaging.carvel.dev -A | grep argocd.kubernetes" ;;
  esac
fi

# ⚠️ THE CRD IS NOT THE READINESS SIGNAL. The operator publishes the CRD BEFORE its validating
# webhook is serving, so an apply that races it fails with
#   Internal error occurred: failed calling webhook "vargocd-v1alpha1.kb.io": failed to call webhook
# MEASURED 2026-08-10 re-walking scenario-1 from scratch: the CRD wait above passed, this apply then
# failed immediately, twice in a row. Waiting on the CRD is a PROXY; being able to CALL the webhook
# is the real thing, and the only way to test it is to attempt the apply.
_cr="$(mktemp)"; trap 'rm -f "$_crd_err" "$_cr"; vc_logout' EXIT
cat > "$_cr" <<YAML
apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
kind: ArgoCD
metadata:
  name: ${ARGOCD_INSTANCE_NAME:-argocd-1}
  namespace: ${NS}
spec:
  version: ${VER}
YAML
_tries="${ARGOCD_CR_APPLY_RETRIES:-30}"; _i=1; _aerr="$(mktemp)"
while :; do
  if kubectl --kubeconfig "$SUP" apply -f "$_cr" 2>"$_aerr"; then rm -f "$_aerr"; break; fi
  case "$(cat "$_aerr" 2>/dev/null || true)" in
    *"failed calling webhook"*|*"failed to call webhook"*|*"connection refused"*|*"no endpoints available"*)
      [ "$_i" -lt "$_tries" ] || { cat "$_aerr" >&2; rm -f "$_aerr"; die "the ArgoCD operator webhook was still not answering after ${_tries} attempts - the CRD is published but the operator is not serving"; }
      [ "$_i" = 1 ] && log_info "the ArgoCD operator webhook is not answering yet (it publishes the CRD first) - retrying (up to ${_tries}x)"
      _i=$((_i + 1)); sleep "${ARGOCD_CR_APPLY_INTERVAL:-10}" ;;
    *) cat "$_aerr" >&2; rm -f "$_aerr"; die "could not create the ArgoCD instance CR (see the error above)" ;;
  esac
done
log_info "ArgoCD instance ${ARGOCD_INSTANCE_NAME:-argocd-1} requested in namespace ${NS} (version ${VER})"
log_info "next: make argocd-preflight   (reports CLI vs RUNNING server vs supported versions)"
