#!/usr/bin/env bash
# 24-vks-k8s-version.sh — pick the newest Ready+Compatible TKr and publish it as VKS_K8S_VERSION.
#
# WHAT IT REPLACES — an eyeball over ~67 rows
# ------------------------------------------
# scenario-1 Step 6 said: "kubectl get kubernetesreleases -> pick one that is Ready AND Compatible
# and paste its full name." A fresh Supervisor publishes dozens and marks only some usable, so the
# reader is scanning two boolean columns by eye and retyping a string like
# `v1.35.5+vmware.1-vkr.1` -- where a single wrong character is a cluster that never creates.
#
# The repo already knew how: nested-vsphere-lab's walk harness has resolved exactly this for every
# row (`awk '$3=="True" && $4=="True"' | sort -V | tail -1`). The reader was the only one doing it by
# hand.
#
# AND THEY ARE NOT ALL READY AT ONCE. A freshly-enabled Supervisor syncs its TKr content library over
# several minutes: MEASURED 2026-08-12, a lab whose Supervisor had just come up listed 8 releases
# with ZERO Ready, and the newest went Ready+Compatible about a minute later. A point-in-time read
# therefore tells a reader "this lab has nothing usable" about a lab that is merely still starting --
# which is why this waits.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
require_cmd kubectl

SUP="$(supervisor_kubeconfig_or_die 'the TKr list')"

WAIT="${VKS_TKR_WAIT_SECONDS:-900}"
case "$WAIT" in
  ''|*[!0-9]*) die "VKS_TKR_WAIT_SECONDS must be WHOLE SECONDS, got '${WAIT}' (900, not 15m)" ;;
esac

# `sort -V` is NUMERIC-aware, which is the whole point: lexically, v1.9.1 sorts AFTER v1.25.13.
# Verified on this lab's real strings: v1.9.1 < v1.25.13 < v1.33.3 < v1.35.2 < v1.35.5.
# THE READ IS SEPARATE FROM THE FILTER, so kubectl's own rc survives. As one pipeline its status was
# awk's, and `2>/dev/null` threw the reason away — which is how a transport failure became "no
# releases are Ready yet" (B110). SEE _TKR_RC / _TKR_ERR below.
_TKR_ERR="$(mktemp)"; _TKR_OUT="$(mktemp)"; _TKR_OSI="$(mktemp)"
trap 'rm -f "$_TKR_ERR" "$_TKR_OUT" "$_TKR_OSI"' EXIT
_TKR_RC=0
# THE READ RUNS IN THIS SHELL, NOT IN A SUBSTITUTION. A first attempt set _TKR_RC inside a function
# called as `v="$(_newest_ready)"` — a COMMAND SUBSTITUTION IS A SUBSHELL, so the assignment was
# discarded and every classification silently fell through to the wait loop. Measured: the test
# still burned the full budget and still blamed the content library. The fix is to write kubectl's
# output to a FILE and read its rc here, then filter the file — no pipeline, no subshell.
_tkr_read() {
  _TKR_RC=0
  kubectl --kubeconfig "$SUP" --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-15s}" \
    get kubernetesreleases --no-headers >"$_TKR_OUT" 2>"$_TKR_ERR" || _TKR_RC=$?
  # The OS IMAGES are read HERE, in the same function, so the wait loop below re-reads BOTH.
  # A failure is deliberately non-fatal: an empty file makes _newest_ready return nothing, which
  # the existing wait/classify path already handles as "nothing usable yet".
  kubectl --kubeconfig "$SUP" --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-15s}" \
    get osimages -o custom-columns='K8S:.spec.kubernetesVersion,OS:.spec.os.name' --no-headers \
    >"$_TKR_OSI" 2>/dev/null || : >"$_TKR_OSI"
}
# READY + COMPATIBLE IS NOT ENOUGH. The admission webhook resolves a KubernetesRelease AND an
# OSImage, and the two arrive on INDEPENDENT timelines. MEASURED 2026-08-16: this filter picked
# v1.34.2+vmware.2-vkr.2 (Ready+Compatible since 14:29:13); the create at 14:37:26 was REJECTED with
#   admission webhook "tkr-resolver-cluster-webhook.tanzu.vmware.com" denied the request:
#   Could not resolve KR/OSImage ... {k8sVersionPrefix: v1.34.2+vmware.2-vkr.2, osImageSelector: os-name=photon}
# because that release's photon OSImage was not created until 14:40:58 — 3m32s AFTER the rejection.
# Two other releases (v1.34.8, v1.35.5) had theirs and would have worked. So an operator following
# the runbook got an error naming a release that `kubectl get kubernetesreleases` shows as True True:
# an error contradicted by the very command the runbook told them to run.
#
# The join: an OSImage's spec.kubernetesVersion is the KR's version MINUS its `-vkr.N` suffix
# (v1.34.2+vmware.2-vkr.2 -> v1.34.2+vmware.2). VERIFIED on a live Supervisor across all 6 usable
# releases, including the `-fips` shape (v1.33.6+vmware.1-fips-vkr.2 -> v1.33.6+vmware.1-fips).
# os-name=photon is the builtin-generic ClusterClass default, not ours — hence VKS_OS_NAME.
_newest_ready() {   # call _tkr_read FIRST; this only filters what it fetched
  awk -v osi="$_TKR_OSI" -v want_os="${VKS_OS_NAME:-photon}" '
    BEGIN { while ((getline line < osi) > 0) { n=split(line, f, /[ \t]+/); if (n>=2 && f[2]==want_os) have[f[1]]=1 } }
    $3=="True" && $4=="True" {
      base=$2; sub(/-vkr\.[0-9]+$/, "", base)
      if (base in have) print $2
    }' "$_TKR_OUT" 2>/dev/null | sort -V | tail -1
}

_tkr_read
v="$(_newest_ready || true)"

# CLASSIFY BEFORE SPENDING THE BUDGET. This used to enter the wait loop on an empty result whatever
# the reason, burn up to VKS_TKR_WAIT_SECONDS (900s), and then declare "Every release is published
# but unusable, which is a Supervisor/content-library problem" — a confident platform diagnosis
# derived from a connection that never succeeded. Waiting cannot fix a stale CA or a missing grant,
# so it is 15 minutes spent to reach a conclusion that was already wrong.
if [ "$_TKR_RC" -ne 0 ]; then
  _hint="Re-issue it:  make vks-login   (scenario-1 Step 3)"
  case "$(classify_kube_failure "$_TKR_ERR")" in
    STALE_CA)     die "could not LIST the TKr releases: '${SUP}' does not work against this cluster,
  and the server ANSWERED — a REBUILT cluster mints a new CA while the address stays the same. The
  releases were never read, so this says nothing about them, and waiting cannot change it. ${_hint}" ;;
    UNAUTHORIZED) die "the Supervisor REJECTED these credentials, so the TKr list was never read.
  This says nothing about which releases exist. ${_hint}" ;;
    FORBIDDEN)    die "authenticated, but this identity may not LIST kubernetesreleases, so we cannot
  tell which TKr are usable. That is an RBAC GRANT, not a broken kubeconfig — do NOT re-fetch it.
  Ask your platform admin for the TKr version and set VKS_K8S_VERSION in .env." ;;
    UNREACHABLE)  die "could not reach the Supervisor at all, so the TKr list was never read. This is
  NOT evidence your kubeconfig is stale — check the address and the network." ;;
    PLAINTEXT)    die "the Supervisor endpoint answered PLAINTEXT where TLS was expected; the TKr list
  was never read. Check the server URL in '${SUP}'." ;;
    NO_KUBE_TARGET) die "'${SUP}' names no cluster to talk to, so the TKr list was never read. ${_hint}" ;;
    KUBECONFIG_UNUSABLE) die "'${SUP}' is unusable — something it NAMES is missing, unreadable or
  malformed, so the TKr list was never read. ${_hint}" ;;
    *)            log_error "could not list the TKr releases:"
                  sed 's/^/    /' "$_TKR_ERR" >&2
                  die "refusing to wait ${WAIT}s, or to blame the content library, on a probe that did not complete." ;;
  esac
fi

# ONLY NOW is an empty result a fact about the Supervisor's releases.
if [ -z "$v" ] && [ "$WAIT" -gt 0 ]; then
  total="$(kubectl --kubeconfig "$SUP" get kubernetesreleases --no-headers 2>/dev/null | grep -c . || true)"
  log_info "${total:-0} release(s) published, none Ready+Compatible yet — a freshly-enabled Supervisor syncs them over several minutes."
  log_info "waiting up to ${WAIT}s ..."
  _w=0
  while [ "$_w" -lt "$WAIT" ]; do
    sleep 15; _w=$((_w + 15))
    _tkr_read; v="$(_newest_ready || true)"; [ -n "$v" ] && break
    [ $((_w % 60)) = 0 ] && log_info "  still none usable (${_w}/${WAIT}s) ..."
  done
fi

if [ -z "$v" ]; then
  log_error "no Ready AND Compatible TKr on this Supervisor after ${WAIT}s. Nothing was written."
  log_error "  Either every release is published-but-unusable (a Supervisor/content-library problem),"
  log_error "  OR none of the usable ones has a ${VKS_OS_NAME:-photon} OSImage yet — the webhook needs BOTH."
  log_error "  Check the second one with:"
  log_error "    kubectl --kubeconfig ${SUP} get osimages -o custom-columns=K8S:.spec.kubernetesVersion,OS:.spec.os.name"
  log_error "  not something a cluster name can work around. Look at the two boolean columns:"
  log_error "    kubectl --kubeconfig ${SUP} get kubernetesreleases"
  exit 1
fi

# NON-DESTRUCTIVE. VKS_K8S_VERSION is a deliberate PIN: an operator who chose an older release to
# match something else must not have it silently moved forward by a target they ran for information.
if ! is_placeholder "${VKS_K8S_VERSION:-}" && [ "${VKS_K8S_VERSION}" != "$v" ]; then
  log_warn "VKS_K8S_VERSION is already pinned to '${VKS_K8S_VERSION}' - NOT overwriting it with the newest (${v})."
  log_warn "  Change it in .env yourself if you want to move."
else
  set_env_var VKS_K8S_VERSION "$v" "${REPO_ROOT}/.env"
  log_info "wrote VKS_K8S_VERSION=${v} to ./.env  (newest Ready+Compatible)"
fi

# The FULL name, deliberately: it is a PREFIX selector, so a bare `v1.35` is accepted and then
# FLOATS to whatever matches later -- which an air-gap repo must never do.
echo
echo "  VKS_K8S_VERSION: ${VKS_K8S_VERSION:-$v}"
echo
