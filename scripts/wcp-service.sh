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
# RETURNS non-zero on timeout — it does NOT die. Two reasons, both measured:
#
#   1. `wait_for ... || true` (the `stop` arm below) CANNOT swallow a `die`. `die` ends in `exit`,
#      and `||` only catches a non-zero RETURN. So a `wcp-stop` that timed out used to terminate
#      the script and suppress the very "next: make wcp-start" recovery line the `|| true` was
#      written to guarantee — the operator was left with Workload Management DOWN and no
#      instruction. The caller must decide fatality, so the caller gets a status to decide on.
#   2. It keeps the two arms honest and DIFFERENT: a failed restart IS fatal, a failed stop is not.
wait_for() {
  local want="$1" budget="${WCP_WAIT_SECONDS:-600}" _end=$((SECONDS + ${WCP_WAIT_SECONDS:-600})) st
  log_info "waiting for ${want} (budget ${budget}s)"
  while :; do
    # The poll cadence is a TUNABLE, not a literal — same rule as every other timing in this repo.
    # It also stops the offline regression test costing 10s per arm just to reach its first probe:
    # test-wcp-service.sh sets it to 1, which is the difference between a 28s case and a 6s one.
    # Default stays 10s: a restarting vCenter is not worth hammering, and each probe re-logs-in.
    sleep "${WCP_POLL_SECONDS:-10}"
    st=""
    # `--soft` IS LOAD-BEARING, and so is dropping `2>/dev/null`.
    #
    # The re-login is deliberate and must STAY: the API disappears during a restart and the session
    # dies with it, so a hoisted token would be invalid for every probe — `st` would be empty for
    # the whole budget and a HEALTHY restart would `die` after the full 600s. (That hoist was
    # proposed and refuted for exactly this reason; do not re-propose it.)
    #
    # What was wrong is that plain `vc_login` DIES on 000/5xx — the transport errors this loop
    # exists to wait through — and an `exit` inside an `if` CONDITION does not stay in the `if`.
    # MEASURED: `f(){ exit 7; }; if f; then ...; fi; echo AFTER` -> rc=7 and AFTER never prints.
    # So one blip during a restart killed the script at ~10s with NO message, while the benign
    # timeout path printed a full diagnosis. 401 is still fatal in soft mode, on the first
    # attempt, which is what keeps this loop's SSO lockout cost at exactly ONE.
    if vc_login --soft; then st="$(wcp_state)"; fi
    [ "$st" = "$want" ] && { log_info "wcp is ${st}"; return 0; }
    if [ "$SECONDS" -ge "$_end" ]; then
      log_error "wcp did not reach ${want} within ${budget}s (last: ${st:-no answer}). It may still be transitioning - re-check with: make wcp-status"
      return 1
    fi
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
  # `|| true` NOW ACTUALLY WORKS — wait_for returns instead of dying (see its header). The
  # recovery line below is the whole point of this arm: the operator has just taken Workload
  # Management DOWN for every tenant, and must not be left without the command that brings it back.
  stop) wait_for "STOPPED/HEALTHY" || true
        log_info "next: make wcp-start   (nothing provisions until you do)" ;;
  # ...and this arm is EXPLICITLY fatal, which the old shared `die` made accidental. A restart that
  # never reached STARTED/HEALTHY must fail the caller: `make wcp-restart` exists to unblock
  # something, and reporting success over a service that never came back is the fake-green.
  *)    wait_for "STARTED/HEALTHY" || die "wcp did not come back — Workload Management may still be transitioning. Re-check with: make wcp-status"
        log_info "next: re-check what you were unblocking. A stuck REMOVING can need another"
        log_info "  reconcile cycle - kapp waits in 15-minute rounds." ;;
esac
