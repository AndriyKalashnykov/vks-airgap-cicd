#!/usr/bin/env bash
# deregister-supervisor-service.sh <service-id> — remove a Supervisor Service from vCenter's
# CATALOGUE, completing the lifecycle that install/uninstall leaves half-done.
#
# THE TWO ARE DIFFERENT, and the difference confuses everyone once:
#   uninstall   removes the WORKLOAD and its data from a supervisor. The service stays
#               REGISTERED and still shows as ACTIVATED in `make list-supervisor-services`.
#   deregister  removes the service DEFINITION from vCenter entirely. To install it again you
#               must upload the .yml again (scenario-1 Step 2/3, or `make install-*-service`,
#               which re-registers from the file for you).
#
# The platform ENFORCES the order: deactivate -> delete every version -> deregister. MEASURED,
# deregistering while a workload is still installed is refused with
#   400 "Cannot delete the Supervisor Service ... because it has ..."
# so this checks first and says so, rather than issuing a call that cannot succeed.
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
vc_ss_is_registered "$SERVICE" || { log_info "${SERVICE} is not registered - nothing to deregister"; exit 0; }

# PRECONDITION: still installed anywhere? Say so instead of issuing a doomed call.
state="$(vc_ss_state "$SUP" "$SERVICE")"
if [ -n "$state" ]; then
  die "${SERVICE} is still INSTALLED on this supervisor (${state}).
  The platform refuses to deregister a service that has a workload. Remove it first:
      make uninstall-supervisor-service SERVICE='${SERVICE}' CONFIRM=yes"
fi

[ "${CONFIRM:-}" = yes ] || die "refusing without CONFIRM=yes.
  This removes ${SERVICE}'s DEFINITION from ${VCENTER_HOST}. Installing it again then needs the
  .yml uploaded again (make install-harbor-service / install-argocd-service do that for you).
  Re-run:
      make deregister-supervisor-service SERVICE='${SERVICE}' CONFIRM=yes"

# 1. deactivate — reversible, blocks new installs while we take the versions away.
vc_api PATCH "/api/vcenter/namespace-management/supervisor-services/${SERVICE}?action=deactivate" >/dev/null || true
case "$(vc_last_code)" in
  2*) log_info "deactivated (reversible: ?action=activate)" ;;
  *)  log_warn "deactivate returned HTTP $(vc_last_code) - continuing; the delete below is the gate that matters" ;;
esac

# 2. every version must go before the service can.
vers="$(vc_api GET "/api/vcenter/namespace-management/supervisor-services/${SERVICE}/versions" 2>/dev/null \
       | jq -r '.[]?.version // empty' 2>/dev/null || true)"
if [ -n "$vers" ]; then
  printf '%s\n' "$vers" | while read -r v; do
    [ -n "$v" ] || continue
    vc_api DELETE "/api/vcenter/namespace-management/supervisor-services/${SERVICE}/versions/${v}" >/dev/null || true
    log_info "  removed version ${v} (HTTP $(vc_last_code))"
  done
else
  log_info "no versions listed"
fi

# 3. the service itself.
out="$(vc_api DELETE "/api/vcenter/namespace-management/supervisor-services/${SERVICE}" || true)"
code="$(vc_last_code)"
case "$code" in
  2*) : ;;
  *)  die "deregister refused (HTTP ${code}): $(printf '%s' "$out" | head -c 300)" ;;
esac

# VERIFY the end state rather than trusting the status code.
if vc_ss_is_registered "$SERVICE"; then
  die "vCenter accepted the delete (HTTP ${code}) but ${SERVICE} is STILL REGISTERED. Not reporting success.
  Re-check with: make list-supervisor-services"
fi
log_info "${SERVICE} is DEREGISTERED - gone from vCenter's catalogue"
log_info "next: 'make install-harbor-service' / 'install-argocd-service' re-register from the .yml when you want it back"
