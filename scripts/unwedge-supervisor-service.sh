#!/usr/bin/env bash
# unwedge-supervisor-service.sh <service-id> — break-glass for a Supervisor Service whose
# UNINSTALL is wedged: delete the workload objects the platform is waiting on, so its own
# reconcile can finish.
#
# THE DEFECT THIS EXISTS FOR (measured 2026-08-09, vCenter 9.1.0.0300): an ArgoCD service
# uninstall reported, for over 40 minutes and across three re-issues and a wcp restart:
#
#   kapp: Error: Timed out waiting after 15m0s for resources:
#     - endpointslice/argocd-service-webhook-service-k8tfs ... namespace: svc-argocd-service-yzz24
#
# ...while Kubernetes had NO deletionTimestamp on any of it. The Deployment had been Running for
# 22h. vCenter was waiting for a deletion IT NEVER ISSUED, which is indistinguishable from "slow"
# until you check for a deletionTimestamp. Deleting the objects by hand let its next round finish.
#
# ⚠️ THIS IS NOT PART OF ANY NORMAL FLOW. It deletes platform-managed workload objects. Run it
# only when an uninstall is genuinely stuck, and only after reading what it plans to delete.
#
# NOT the namespace: the Supervisor's own admission webhook
# ("default.validating.namespace.supervisor.vmware.com") refuses to delete an `svc-*` namespace
# for ANY user including vCenter admin -- "Principal administrator ... is not associated with
# namespace". Only the platform may remove it, which it does once its reconcile completes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
load_env

SERVICE="${1:-${SERVICE:-}}"
require_cmd kubectl jq
[ -s "${KUBECONFIG:-/nonexistent}" ] || die "no Supervisor kubeconfig at '${KUBECONFIG:-<unset>}' — run 'make vks-login' first"

trap vc_logout EXIT
vc_login
SUP="$(vc_supervisor_id)"
[ -n "$SUP" ] || die "could not resolve a Supervisor from ${VCENTER_HOST}"

# ── GATE 1: the service must actually be mid-DELETE ───────────────────────────────────────
# Without this the target would happily delete a HEALTHY service's operator. The platform's own
# message is the signal: a stuck uninstall reports a "Deleting" phase with a kapp timeout.
# A gate that refuses must NAME the real choices — the id is vCenter's, derived from the
# service-definition YAML, so an operator cannot reasonably guess it.
_list_and_die() {
  log_error "$1"
  log_error "  registered Supervisor Services on ${VCENTER_HOST}:"
  vc_ss_list | while IFS=$'\t' read -r st id disp; do
    [ -n "${id:-}" ] && log_error "    ${id}   (${st}${disp:+, $disp})"
  done
  die "re-run with SERVICE=<one of the ids above>   (see also: make list-supervisor-services)"
}
[ -n "$SERVICE" ] || _list_and_die "SERVICE is not set."

detail="$(vc_api GET "/api/vcenter/namespace-management/supervisors/${SUP}/supervisor-services/${SERVICE}" || true)"
[ -n "$detail" ] || _list_and_die "vCenter does not know a Supervisor Service '${SERVICE}'."
msgs="$(printf '%s' "$detail" | jq -r '[.messages[]?.details.args[]?] | join(" ")' 2>/dev/null || true)"
case "$msgs" in
  *Deleting*) : ;;
  *) log_error "vCenter does not report ${SERVICE} as mid-delete. Its messages say:"
     printf '%s' "$detail" | jq -r '.messages[]? | "    [\(.severity)] \(.details.args // [] | join(" | ") | .[0:160])"' 2>/dev/null | head -4 >&2
     die "refusing: this deletes the service's workload, which would BREAK a healthy service. Issue the uninstall first (make services-uninstall in the lab repo, or vCenter), and only run this if it then wedges." ;;
esac
log_info "${SERVICE} is mid-delete and stuck:"
printf '%s' "$detail" | jq -r '.messages[]? | "    \(.details.args // [] | join(" | ") | .[0:200])"' 2>/dev/null | head -3

# ── GATE 2: discover the namespace, never accept a pasted one ─────────────────────────────
# The suffix is random per install (svc-argocd-service-yzz24, svc-harbor-1vsxx), so a hardcoded
# name is wrong on the next lab. Derive the prefix from the service id's first label.
prefix="svc-$(printf '%s' "$SERVICE" | cut -d. -f1)-"
mapfile -t nss < <(kubectl get ns -o name 2>/dev/null | sed 's|^namespace/||' | grep -E "^${prefix}" || true)
case "${#nss[@]}" in
  0) log_info "no namespace matching '${prefix}*' — the workload is already gone."
     log_info "next: re-issue the uninstall; the platform's next reconcile should complete it."
     exit 0 ;;
  1) NS="${nss[0]}" ;;
  *) die "AMBIGUOUS: ${#nss[@]} namespaces match '${prefix}*' (${nss[*]}). Refusing to guess which one is this service's." ;;
esac
log_info "namespace: ${NS}"

# ── show, then confirm ────────────────────────────────────────────────────────────────────
# B112: this listing is what the operator CONFIRMS against. `2>/dev/null` made a transport failure
# render as an EMPTY list, so they would confirm the deletion of a namespace we could not read — and
# the loop below would then delete nothing and report success. Read the rc; refuse before asking.
_uw_err="$(mktemp)"; _uw_out="$(mktemp)"
# `cmd; rc=$?` is WRONG here: this script runs under `set -euo pipefail`, so a failing kubectl
# exits at the kubectl and the whole refusal block below never runs — the operator gets a silent
# non-zero exit with no diagnostic at all, which is worse than the bug being fixed. `|| rc=$?`
# puts it in a condition context. (Caught by the test, not by reading it.)
_uw_rc=0
kubectl -n "$NS" get deploy,statefulset,daemonset,svc,pod > "$_uw_out" 2> "$_uw_err" || _uw_rc=$?
if [ "$_uw_rc" -ne 0 ]; then
  _uw_class="$(classify_kube_failure "$_uw_err")"
  log_error "cannot READ ${NS} — refusing to ask you to confirm a deletion against a list we could not build."
  case "$_uw_class" in
    KUBECONFIG_UNUSABLE) log_error "  the kube config names something missing/unreadable: \$KUBECONFIG=${KUBECONFIG:-<unset>}" ;;
    STALE_CA)            log_error "  the endpoint's certificate did not verify — the trust anchor is stale." ;;
    PLAINTEXT)           log_error "  the endpoint is not speaking TLS (wrong scheme or port)." ;;
    UNAUTHORIZED)        log_error "  the Supervisor token is EXPIRED/invalid. Renew it, then re-run." ;;
    FORBIDDEN)           log_error "  authenticated, but RBAC denies reading ${NS}. This break-glass needs admin." ;;
    UNREACHABLE)         log_error "  the Supervisor did not answer (DNS/route/endpoint)." ;;
    NO_KUBE_TARGET)      log_error "  no cluster is configured for kubectl to talk to." ;;
    *)                   log_error "  unclassified kubectl failure." ;;
  esac
  sed 's/^/    /' < "$_uw_err" >&2
  rm -f "$_uw_err" "$_uw_out"
  exit 1
fi
sed 's/^/    /' < "$_uw_out"
rm -f "$_uw_err" "$_uw_out"
log_info "these objects would be DELETED (listed above):"

[ "${CONFIRM:-}" = yes ] || die "refusing without CONFIRM=yes. Re-run: make unwedge-supervisor-service SERVICE='${SERVICE}' CONFIRM=yes"

# The NAMESPACE is deliberately not deleted (the webhook forbids it; the platform removes it).
# Workload kinds only: leaving ConfigMaps/Secrets alone costs nothing and keeps the blast radius
# to what kapp actually waits on -- Services own the endpointslices, workloads own the pods.
# B112: `2>/dev/null || true` made "the kind has no objects" and "we could not ask" the SAME empty
# string, so a transport failure skipped every kind and the script still said "deleted." — a success
# claim over a no-op, in a script whose whole purpose is to delete. A mutating script refuses louder
# than a reporting one: it DIES rather than continuing to the next kind.
_uw_deleted=0
for kind in deployment statefulset daemonset service; do
  _uw_err="$(mktemp)"
  names="$(kubectl -n "$NS" get "$kind" -o name 2> "$_uw_err")" || {
    log_error "cannot list ${kind} in ${NS} — $(classify_kube_failure "$_uw_err"). NOTHING further will be deleted."
    log_error "  Partial progress: ${_uw_deleted} object(s) already deleted. Fix the cause and re-run."
    sed 's/^/    /' < "$_uw_err" >&2; rm -f "$_uw_err"; exit 1
  }
  rm -f "$_uw_err"
  [ -n "$names" ] || continue
  # NOT `printf | while read` — that is a SUBSHELL, so _uw_deleted would never survive the loop and
  # the count would always print 0. A herestring keeps the loop in the current shell.
  while read -r obj; do
    [ -n "$obj" ] || continue
    kubectl -n "$NS" delete "$obj" --wait=false 2>&1 | sed 's/^/    /' || true
    _uw_deleted=$((_uw_deleted + 1))
  done <<< "$names"
done

if [ "$_uw_deleted" -eq 0 ]; then
  log_warn "nothing was deleted — every workload kind in ${NS} was already empty."
  log_warn "  If the uninstall is still wedged, it is NOT waiting on these kinds; re-check with:"
  log_warn "      kubectl -n ${NS} get all"
else
  log_info "deleted ${_uw_deleted} object(s). Remaining in ${NS}:"
fi
kubectl -n "$NS" get deploy,svc,endpointslice,pod 2>&1 | sed 's/^/    /' | head -5
log_info "next: re-issue the uninstall. kapp retries in 15-minute rounds, so give it that long."
