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
# ⚠️ THE STREAMS ARE NOT MERGED (B210). This used to be `2>&1`, which folded kubectl's stderr into
# the VALUE -- exactly what classify_kube_failure's own header (lib/os.sh) forbids in as many words:
# "NEVER MERGE THE STREAMS". With them merged, an error is indistinguishable from an address, and the
# errfile that classify_kube_failure needs does not exist at all.
#
# The failure this fixes: point $KUBECONFIG at a GUEST cluster (which is what it is from scenario-1
# Step 6 onward -- see supervisor_kubeconfig's candidate list) and `-n cicd` does not exist, so kubectl
# exits non-zero, _state says `absent`, and this script WAITS ARGOCD_ADDRESS_WAIT_SECONDS (default
# 900s) printing "the ArgoCD instance is still reconciling". That is a positive claim about a cluster
# we are not even pointed at, and it costs 15 minutes before saying anything true.
_ERRF="$(mktemp)"; trap 'rm -f "$_ERRF"' EXIT
_state() {                       # absent | pending | <ip>
  local out rc=0
  out="$(kubectl --kubeconfig "$SUP" -n "$NS" get svc argocd-server \
           -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>"$_ERRF")" || rc=$?
  [ "$rc" -ne 0 ] && { printf 'absent'; return; }
  # The probe SUCCEEDED, so whatever kubectl wrote to stderr (retry noise, warnings) is not a
  # failure and must not be classified. Without this, rc=0 + empty stdout -- the NORMAL `pending`
  # state -- was classified UNREACHABLE and exited in 0s, aborting the exact state this target
  # exists to wait through. A global cannot escape the $( ) subshell; the FILE can, so truncate it.
  : > "$_ERRF"
  case "$out" in '') printf 'pending' ;; *) printf '%s' "$out" ;; esac
}

# Is `absent` worth WAITING on? Only if the namespace exists and the Service has not appeared yet.
# A missing NAMESPACE, an unusable kubeconfig, a stale CA or a rejected credential are all states
# that waiting cannot fix, and most of them mean this kubeconfig is not the Supervisor. FORBIDDEN and
# UNREACHABLE are classified but judged WAIT-WORTHY (see the arm below). Returns 0 = wait is
# pointless. This CLASSIFIES; it never refuses to run (a real fresh Supervisor whose Service has not
# yet reconciled must keep waiting, which is the whole point of the target).
_wait_is_pointless() {
  local e; e="$(cat "$_ERRF" 2>/dev/null || true)"
  [ -n "$e" ] || return 1
  case "$e" in *namespaces*not\ found*) return 0 ;; esac
  case "$(classify_kube_failure "$_ERRF")" in
    # ⚠️ UNREACHABLE and FORBIDDEN are DELIBERATELY ABSENT (implementation round, 2026-08-22).
    # _wait_is_pointless is evaluated EXACTLY ONCE, before the loop -- i.e. at the single most
    # transient moment, immediately after 08-install-argocd-service.sh requests the CR, at peak
    # Supervisor churn. MEASURED with a fake kubectl emitting ONE `i/o timeout`: at probe 1 it exited
    # 0s; at probe 3 the identical fault was ridden out and the run waited normally. Same fault,
    # opposite handling, decided only by WHEN it lands -- and the printed remedy then blames a GUEST
    # kubeconfig for a 15-second network hiccup. FORBIDDEN is out for the same reason (RBAC
    # propagation). Only states that CANNOT resolve by waiting belong here.
    KUBECONFIG_UNUSABLE|STALE_CA|UNAUTHORIZED|NO_KUBE_TARGET|PLAINTEXT) return 0 ;;
    # HANDLED EXPLICITLY, and the verdict is WAIT (return 1). check-classifier-consumers is right to
    # demand every class appear: letting these fall to `*)` would print "not one we classify", which
    # is false. They ARE classified -- we simply judge that waiting is the correct response, because
    # both resolve on their own: a Supervisor apiserver blips during reconcile, and RBAC propagates.
    FORBIDDEN|UNREACHABLE) return 1 ;;
  esac
  return 1
}

st="$(_state)"
if [ "$st" = absent ] || [ "$st" = pending ]; then
    # B210: do not burn 900s on a state waiting cannot fix. This is a CLASSIFIER, not a gate -- it
    # only skips the WAIT and prints what kubectl actually said; a genuinely reconciling Supervisor
    # whose Service has not appeared yet still waits exactly as before.
    if _wait_is_pointless; then
      log_error "svc/argocd-server is not reachable, and WAITING WILL NOT FIX IT - not waiting."
      log_error "  kubectl said: $(head -2 "$_ERRF" | tr '\n' ' ')"
      log_error "  If that names a missing NAMESPACE, this kubeconfig is almost certainly your GUEST"
      log_error "  cluster, not the Supervisor. ArgoCD is a SUPERVISOR Service, so a guest kubeconfig"
      log_error "  cannot see it. Point VKS_SUPERVISOR_KUBECONFIG at the Supervisor kubeconfig, or run"
      log_error "  'make vks-login'. As a TENANT you may have no Supervisor access at all - ask your"
      log_error "  platform admin for the ArgoCD address instead."
      exit 1
    fi
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
