#!/usr/bin/env bash
# 09-argocd-address.sh — wait for ArgoCD's LoadBalancer address and publish it as ARGOCD_SERVER.
#
# WHAT IT REPLACES — the last hand-copy in the runbook
# ---------------------------------------------------
# scenario-1 Step 5 said, verbatim:
#     kubectl get svc -n "$ARGOCD_NAMESPACE"        # argocd-server -> EXTERNAL-IP
#     argocd login <EXTERNAL-IP>
# `<EXTERNAL-IP>` is a LITERAL placeholder: the reader reads an address off the first command and
# types it into the second. That costs twice.
#   - The reader retypes a value THIS REPO ALREADY KNOWS: 02-env.sh:137 discovers it from the exact
#     same jsonpath, but only inside `make env-populate`, which the document does not reach until
#     Step 11 -- six steps after it is needed.
#   - walk-doc.sh refuses any block carrying an unsubstituted <placeholder> ("a walk must not invent
#     a value"), so `argocd login` has NEVER been executed by any row, in either cell, on either OS.
#     The one command a reader is most likely to get wrong is the one nothing tests.
#
# And the EXTERNAL-IP is `<pending>` for most of the ~10 minutes the same paragraph promises, so the
# raw `kubectl get` is a point-in-time probe for something that is not true yet -- the identical
# defect as `make harbor-reachable` before it was taught to wait.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
require_cmd kubectl

# The SAME chain 08-install-argocd-service.sh uses. ArgoCD is a SUPERVISOR Service, so from Step 6
# onward $KUBECONFIG is the GUEST cluster, which has no argocd-server at all.
SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"   # lib/os.sh: ONE resolver, first that EXISTS
[ -f "$SUP" ] || { supervisor_kubeconfig_hint >&2; die "no Supervisor kubeconfig — see the search order above"; }

NS="${ARGOCD_NAMESPACE:-${VKS_NAMESPACE:-}}"
[ -n "$NS" ] || die "ARGOCD_NAMESPACE is not set (and VKS_NAMESPACE is empty) - scenario-1 Step 5 sets it."

# WHOLE SECONDS. `10m` is the plausible typo because the document speaks in minutes, and an
# unguarded value makes `[ "$W" -gt 0 ]` print `integer expression expected` and SKIP the wait --
# silently restoring the behaviour the wait exists to fix. `set -e` cannot catch it: the `[` is
# inside an `if` condition, where set -e is suspended.
WAIT="${ARGOCD_ADDRESS_WAIT_SECONDS:-900}"
case "$WAIT" in
  ''|*[!0-9]*) die "ARGOCD_ADDRESS_WAIT_SECONDS must be WHOLE SECONDS, got '${WAIT}' (900, not 10m)" ;;
esac

# THREE STATES, THREE MESSAGES. A wait written for "<pending>" is wrong here: MEASURED on two walk
# rows, at this point in the runbook the Service DOES NOT EXIST --
#     $ kubectl get svc -n "$ARGOCD_NAMESPACE"   ->  No resources found in cicd namespace.
# because 08-install-argocd-service.sh ends at REQUESTING the instance CR; the operator then builds
# the Deployment and Service (visible ~5-6 min later: row1 14:32:29 -> 14:37:46, row3 16:01:12 ->
# 16:08:08). So "no LoadBalancer IP" and "no Service yet" are different failures with different
# remedies, and reporting the first for the second names the wrong cause.
_state() {                       # absent | pending | <ip>
  local out
  out="$(kubectl --kubeconfig "$SUP" -n "$NS" get svc argocd-server \
           -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>&1)" || { printf 'absent'; return; }
  case "$out" in ''|*NotFound*|*'no resources'*) printf 'pending' ;; *) printf '%s' "$out" ;; esac
}

st="$(_state)"
if [ "$st" = absent ] || [ "$st" = pending ]; then
  if [ "$WAIT" -gt 0 ]; then
    case "$st" in
      absent)  log_info "svc/argocd-server does not exist in ${NS} yet — the ArgoCD instance is still reconciling (measured: ~5-6 min after the install is issued)." ;;
      pending) log_info "svc/argocd-server exists but has no LoadBalancer address yet." ;;
    esac
    log_info "waiting up to ${WAIT}s ..."
    _w=0
    while [ "$_w" -lt "$WAIT" ]; do
      sleep 15; _w=$((_w + 15))
      st="$(_state)"
      case "$st" in absent|pending) ;; *) break ;; esac
      [ $((_w % 60)) = 0 ] && log_info "  still ${st} (${_w}/${WAIT}s) ..."
    done
  fi
fi

case "$st" in
  absent)
    log_error "svc/argocd-server never appeared in ${NS} (waited ${WAIT}s)."
    log_error "  This is NOT a LoadBalancer problem — the Service does not exist, so the ArgoCD"
    log_error "  INSTANCE has not reconciled. Nothing was written. Check it:"
    log_error "    kubectl --kubeconfig ${SUP} -n ${NS} get argocd,pods"
    exit 1 ;;
  pending)
    log_error "svc/argocd-server exists in ${NS} but never got a LoadBalancer address (waited ${WAIT}s)."
    log_error "  Nothing was written. The Supervisor needs a LoadBalancer provider for this namespace:"
    log_error "    kubectl --kubeconfig ${SUP} -n ${NS} get svc argocd-server -o wide"
    exit 1 ;;
esac
ip="$st"

# NON-DESTRUCTIVE, and it matters on a real lab: a TENANT may have been GRANTED an address for an
# ArgoCD they do not own, and discovering a same-named service on some other cluster must not
# overwrite it. Same rule 02-env.sh:137 already applies -- write only over a placeholder.
if ! is_placeholder "${ARGOCD_SERVER:-}" && [ "${ARGOCD_SERVER}" != "$ip" ]; then
  log_warn "ARGOCD_SERVER is already set to '${ARGOCD_SERVER}' - NOT overwriting it with the discovered ${ip}."
  log_warn "  If ${ip} is the one you want, change it in .env yourself."
else
  set_env_var ARGOCD_SERVER "$ip" "${REPO_ROOT}/.env"
  log_info "wrote ARGOCD_SERVER=${ip} to ./.env"
fi

echo
echo "  ArgoCD:   https://${ARGOCD_SERVER:-$ip}"
echo "  Log in:   argocd login \"\$ARGOCD_SERVER\" --username admin --insecure"
echo "  Password: make argocd-password"
echo
# ⚠️ DO NOT tell the reader to override this with an env PREFIX. .env.example:345 records the
# measured trap: once this value is in .env, `ARGOCD_SERVER=1.2.3.4 make <target>` is IGNORED,
# because GNU make lets a file-defined variable beat an environment one. A command-line
# `make <target> ARGOCD_SERVER=1.2.3.4` still wins.
