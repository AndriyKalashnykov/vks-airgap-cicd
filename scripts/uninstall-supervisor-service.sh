#!/usr/bin/env bash
# uninstall-supervisor-service.sh <service-id> — remove a Supervisor Service this repo installed.
#
# SYMMETRY: scenario-1 installs Harbor and ArgoCD as Supervisor Services, and until now nothing
# here could remove them -- `make uninstall-all` removes only what we deploy INTO a cluster.
#
# ⚠️ THIS DESTROYS THE SERVICE'S DATA. For Harbor that is every project and every image; for
# ArgoCD every Application and its instance. Requires CONFIRM=yes.
#
# ⚠️ IT IS ALSO SHARED. A Supervisor Service belongs to the whole Supervisor, not to your
# namespace: removing Harbor removes it for every tenant on it. Do not run this on a lab you do
# not own.
#
# WAIT BUDGET: default 1800s, deliberately. MEASURED -- the platform's uninstall is driven by
# Carvel `kapp`, which retries in 15-MINUTE (900s) rounds, so a 600s budget ALWAYS expires
# mid-round and reports failure whether or not anything is progressing. Anything shorter than
# two rounds cannot tell "stuck" from "working".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
load_env

SERVICE="${1:-${SERVICE:-}}"
trap vc_logout EXIT
vc_login
SUP="$(vc_supervisor_id)"
[ -n "$SUP" ] || die "could not resolve a Supervisor from ${VCENTER_HOST}"

_list_and_die() {
  log_error "$1"
  log_error "  registered Supervisor Services on ${VCENTER_HOST}:"
  vc_ss_list | while IFS=$'\t' read -r st id disp; do
    [ -n "${id:-}" ] && log_error "    ${id}   (${st}${disp:+, $disp})"
  done
  die "re-run with SERVICE=<one of the ids above>   (see also: make list-supervisor-services)"
}
[ -n "$SERVICE" ] || _list_and_die "SERVICE is not set."
vc_ss_is_registered "$SERVICE" || _list_and_die "vCenter does not know a Supervisor Service '${SERVICE}'."

state="$(vc_ss_state "$SUP" "$SERVICE")"
log_info "${SERVICE}: ${state:-not installed on this supervisor}"
[ "${CONFIRM:-}" = yes ] || die "refusing without CONFIRM=yes.
  This DESTROYS ${SERVICE}'s data for EVERY tenant on ${VCENTER_HOST} - for Harbor that is every
  project and image; for ArgoCD every Application. Re-run:
      make uninstall-supervisor-service SERVICE='${SERVICE}' CONFIRM=yes"

log_warn "uninstalling ${SERVICE} - this destroys its data"
out="$(vc_api DELETE "/api/vcenter/namespace-management/supervisors/${SUP}/supervisor-services/${SERVICE}" || true)"
code="$(vc_last_code)"
case "$code" in
  2*) log_info "uninstall issued (HTTP ${code})" ;;
  404) log_info "${SERVICE} is not installed on this supervisor - nothing to uninstall"; exit 0 ;;
  *)  die "uninstall refused (HTTP ${code:-<none>}): $(printf '%s' "$out" | head -c 300)" ;;
esac

# Poll to GONE. Report the platform's own message when it changes: that is the only signal that
# distinguishes "grinding forward" from "wedged" (measured: endpoints -> endpointslice).
budget="${UNINSTALL_SERVICE_WAIT_SECONDS:-1800}"
_end=$((SECONDS + budget)); last=""
log_info "waiting for it to disappear (budget ${budget}s = 2 kapp rounds)"
while :; do
  sleep 20
  if ! vc_ss_state "$SUP" "$SERVICE" >/dev/null 2>&1 || [ -z "$(vc_ss_state "$SUP" "$SERVICE")" ]; then
    log_info "${SERVICE} is GONE from this supervisor after $((budget - (_end - SECONDS)))s"
    log_info "next: 'make list-supervisor-services' to confirm, and it stays REGISTERED until deregistered"
    exit 0
  fi
  msg="$(vc_api GET "/api/vcenter/namespace-management/supervisors/${SUP}/supervisor-services/${SERVICE}" 2>/dev/null \
        | jq -r '[.messages[]?.details.args[]?] | join(" ") | .[0:120]' 2>/dev/null || true)"
  [ -n "$msg" ] && [ "$msg" != "$last" ] && { log_info "  platform: ${msg}"; last="$msg"; }
  [ "$SECONDS" -lt "$_end" ] || die "still present after ${budget}s. NOT reporting success.
  If the platform's message has not CHANGED across rounds it is wedged, not slow - see
  docs/scenario-1-notes.md, and 'make unwedge-supervisor-service SERVICE=${SERVICE}'."
done
