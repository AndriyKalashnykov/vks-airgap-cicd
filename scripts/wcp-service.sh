#!/usr/bin/env bash
# wcp-service.sh <status|start|stop|restart> — control vCenter's Workload Management service.
#
# WHEN YOU NEED restart: a Supervisor Service stuck in REMOVING/CONFIGURING that no amount of
# re-issuing clears. MEASURED on this lab: ArgoCD's uninstall left kapp waiting on
# `endpoints/...` in a namespace Kubernetes had ALREADY deleted, so vCenter's record never
# reached "removed" -- and it then refused both delete-version and deregister with 400
# "still installed". Kubernetes was clean; only vCenter's record was stuck.
#
# BLAST RADIUS, said out loud: this is Workload Management for the WHOLE vCenter, so every
# Supervisor and every tenant on it is affected. RUNNING workloads are not -- guest clusters,
# pods and LoadBalancers keep serving; what stops is provisioning, service install/uninstall
# and namespace management.
#
# GUARDS: `stop` requires CONFIRM=yes because it leaves the management plane DOWN until
# somebody starts it again. `restart` does not: it is disruptive but self-healing, and it
# already requires vCenter admin credentials. The repo reserves CONFIRM for what does not
# come back by itself.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
load_env

ACTION="${1:-status}"
case "$ACTION" in status|start|stop|restart) : ;; *) die "usage: wcp-service.sh <status|start|stop|restart>" ;; esac

trap vc_logout EXIT
vc_login

wcp_state() { vc_api GET /api/vcenter/services/wcp 2>/dev/null | jq -r '"\(.state)/\(.health)"' 2>/dev/null || true; }

before="$(wcp_state)"
log_info "wcp: ${before:-unknown}"
[ "$ACTION" = status ] && exit 0

# WAIT for a target state. "Action accepted" is not "usable": the API disappears during a
# restart, so a bare exit would hand back a service that cannot yet be used -- and the session
# dies with it, which is why each probe re-logs-in.
wait_for() {
  local want="$1" budget="${WCP_WAIT_SECONDS:-600}" _end=$((SECONDS + ${WCP_WAIT_SECONDS:-600})) st
  log_info "waiting for ${want} (budget ${budget}s)"
  while :; do
    sleep 10
    st=""
    if vc_login >/dev/null 2>&1; then st="$(wcp_state)"; fi
    [ "$st" = "$want" ] && { log_info "wcp is ${st}"; return 0; }
    [ "$SECONDS" -lt "$_end" ] || die "wcp did not reach ${want} within ${budget}s (last: ${st:-no answer}). It may still be transitioning - re-check with: make wcp-status"
  done
}

case "$ACTION" in
  stop)
    [ "${CONFIRM:-}" = yes ] || die "refusing: 'stop' leaves Workload Management DOWN for every tenant on ${VCENTER_HOST} until someone starts it. Re-run with CONFIRM=yes (or use 'make wcp-restart', which comes back on its own)."
    log_warn "stopping Workload Management on ${VCENTER_HOST} - it will STAY down until 'make wcp-start'."
    vc_api POST '/api/vcenter/services/wcp?action=stop' >/dev/null || true
    ;;
  start)   vc_api POST '/api/vcenter/services/wcp?action=start'   >/dev/null || true ;;
  restart)
    log_warn "restarting Workload Management on ${VCENTER_HOST} for ALL Supervisors."
    log_warn "  running workloads keep serving; provisioning and service install/uninstall pause."
    vc_api POST '/api/vcenter/services/wcp?action=restart' >/dev/null || true
    ;;
esac

code="$(vc_last_code)"
case "$code" in
  2*) log_info "${ACTION} accepted (HTTP ${code})" ;;
  *)  die "${ACTION} refused (HTTP ${code:-<none>}) - are these credentials a vCenter admin?" ;;
esac

case "$ACTION" in
  stop) wait_for "STOPPED/HEALTHY" || true
        log_info "next: make wcp-start   (nothing provisions until you do)" ;;
  *)    wait_for "STARTED/HEALTHY"
        log_info "next: re-check what you were unblocking. A stuck REMOVING can need another"
        log_info "  reconcile cycle - kapp waits in 15-minute rounds." ;;
esac
