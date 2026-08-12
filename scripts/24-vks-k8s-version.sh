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
_newest_ready() {
  kubectl --kubeconfig "$SUP" get kubernetesreleases --no-headers 2>/dev/null \
    | awk '$3=="True" && $4=="True" {print $2}' | sort -V | tail -1
}

v="$(_newest_ready || true)"
if [ -z "$v" ] && [ "$WAIT" -gt 0 ]; then
  total="$(kubectl --kubeconfig "$SUP" get kubernetesreleases --no-headers 2>/dev/null | grep -c . || true)"
  log_info "${total:-0} release(s) published, none Ready+Compatible yet — a freshly-enabled Supervisor syncs them over several minutes."
  log_info "waiting up to ${WAIT}s ..."
  _w=0
  while [ "$_w" -lt "$WAIT" ]; do
    sleep 15; _w=$((_w + 15))
    v="$(_newest_ready || true)"; [ -n "$v" ] && break
    [ $((_w % 60)) = 0 ] && log_info "  still none usable (${_w}/${WAIT}s) ..."
  done
fi

if [ -z "$v" ]; then
  log_error "no Ready AND Compatible TKr on this Supervisor after ${WAIT}s. Nothing was written."
  log_error "  Every release is published but unusable, which is a Supervisor/content-library problem,"
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
