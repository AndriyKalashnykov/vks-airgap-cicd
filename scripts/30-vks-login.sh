#!/usr/bin/env bash
# 30-vks-login.sh — authenticate to the VKS workload cluster (VCF 9 + Supervisor).
#
# This is the SINGLE auth-aware step. Everything downstream consumes only the
# resulting KUBECONFIG + context, so the exact login mechanism is swappable here.
#
# The exact command for the target environment is being confirmed (VCF 9 unifies
# the kubectl-vsphere plugin + tanzu CLI into the token-based VCF CLI). Until then
# this supports three methods, selected by VKS_AUTH_METHOD in .env:
#
#   kubeconfig  (default) : you already have a working kubeconfig at $KUBECONFIG.
#   vcf                   : log in with the VCF CLI (sketched — finalize command).
#   vsphere               : legacy kubectl-vsphere plugin (pre-9 clusters).
#
# In all cases the script ENDS by proving the context actually reaches the cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${KUBECONFIG:?KUBECONFIG must be set in .env (path to write/read the kubeconfig)}"
export KUBECONFIG
mkdir -p "$(dirname "$KUBECONFIG")"
require_cmd kubectl

METHOD="${VKS_AUTH_METHOD:-kubeconfig}"
log_info "VKS auth method: $METHOD (KUBECONFIG=$KUBECONFIG)"

case "$METHOD" in
  kubeconfig)
    [ -s "$KUBECONFIG" ] || die "VKS_AUTH_METHOD=kubeconfig but $KUBECONFIG is empty. \
Place your VKS workload-cluster kubeconfig there (e.g. exported from VCF Automation), or set VKS_AUTH_METHOD=vcf."
    ;;

  vcf)
    # ---- VCF Consumption CLI (vSphere 9 + Supervisor) ----
    # Verified command SHAPE (primary sources: ogelbric/LAB VCF-CLI transcript;
    # Broadcom "Install the Argo CD Service" techdoc). The CLI authenticates to the
    # Supervisor and manages contexts; the two-step flow is:
    #   1. `vcf context create` — creates a Supervisor context (INTERACTIVE: prompts
    #      for a context NAME and the password).
    #   2. `vcf context use <name>:<vsphere-namespace>` — activates it at the namespace.
    #
    # NOT end-to-end validated against a real VKS lab in this repo — the shape is from
    # primary sources; confirm on a lab before relying on it (see the TODO below).
    require_cmd vcf "install the VCF CLI (make install-vcf-clis) on this jump box"
    : "${SUPERVISOR_HOST:?set SUPERVISOR_HOST in .env (Supervisor endpoint, host/IP, no scheme)}"
    : "${VKS_NAMESPACE:?set VKS_NAMESPACE (vSphere namespace) in .env}"
    : "${VKS_USERNAME:?set VKS_USERNAME in .env (user@SSO.DOMAIN, or set VKS_SSO_DOMAIN)}"
    : "${VKS_CONTEXT_NAME:?set VKS_CONTEXT_NAME in .env (the vcf context NAME to type at the prompt)}"

    # Username must be 'user@SSO.DOMAIN'. Append VKS_SSO_DOMAIN if the bare form was given.
    user="$VKS_USERNAME"
    case "$user" in
      *@*) : ;;
      *)
        if [ -n "${VKS_SSO_DOMAIN:-}" ]; then
          user="${VKS_USERNAME}@${VKS_SSO_DOMAIN}"
        else
          die "VKS_USERNAME must be 'user@SSO.DOMAIN' (e.g. administrator@WLD.SSO), or set VKS_SSO_DOMAIN in .env"
        fi
        ;;
    esac

    # Build argv WITHOUT any secret. `vcf context create` prompts interactively for the
    # context name AND the password, so neither ever touches argv/procfs (security.md:
    # secrets never in argv). The endpoint + username are non-secret.
    create_args=(--endpoint "https://${SUPERVISOR_HOST}" --username "$user" --auth-type basic)
    if is_true "${VKS_INSECURE_SKIP_TLS_VERIFY:-}"; then   # one truthiness rule, repo-wide (lib/os.sh)
      create_args+=(--insecure-skip-tls-verify)
    fi

    log_info "creating a VCF context for the Supervisor at https://${SUPERVISOR_HOST} (user: ${user})"
    log_warn "INTERACTIVE: at the prompt, enter the context name '${VKS_CONTEXT_NAME}' (must match VKS_CONTEXT_NAME) and your password."
    # TODO(verify on a real VKS lab): confirm `vcf context create --help` for a
    # non-interactive / stdin password mechanism before automating further. No such
    # flag is confirmed in any primary source, so this runs interactively today; do
    # NOT add a --password flag (a password on argv is forbidden — security.md).
    vcf context create "${create_args[@]}"

    log_info "activating context '${VKS_CONTEXT_NAME}' at namespace '${VKS_NAMESPACE}'"
    vcf context use "${VKS_CONTEXT_NAME}:${VKS_NAMESPACE}"

    # The kubectl-vsphere plugin (for `kubectl vsphere`-style access, if the workload
    # cluster needs it) is fetched from the Supervisor at:
    #   wget --no-check-certificate https://${SUPERVISOR_HOST}/wcp/plugin/linux-amd64/vsphere-plugin.zip
    # It is a separate download, not part of this login step; see the README.
    ;;

  vsphere)
    # ---- Legacy kubectl-vsphere plugin (pre-9 Supervisor) ----
    require_cmd kubectl-vsphere "install the kubectl-vsphere plugin"
    : "${SUPERVISOR_HOST:?set SUPERVISOR_HOST in .env}"
    : "${VKS_NAMESPACE:?set VKS_NAMESPACE in .env}"
    : "${VKS_CLUSTER_NAME:?set VKS_CLUSTER_NAME in .env}"
    : "${VKS_USERNAME:?set VKS_USERNAME in .env}"
    : "${VKS_PASSWORD:?set VKS_PASSWORD in .env}"
    # Password via env var read by the plugin — never on argv.
    KUBECTL_VSPHERE_PASSWORD="$VKS_PASSWORD" kubectl vsphere login \
      --server "$SUPERVISOR_HOST" \
      --tanzu-kubernetes-cluster-namespace "$VKS_NAMESPACE" \
      --tanzu-kubernetes-cluster-name "$VKS_CLUSTER_NAME" \
      --vsphere-username "$VKS_USERNAME" \
      --insecure-skip-tls-verify="$(bool_word "${VKS_INSECURE_SKIP_TLS_VERIFY:-}")"
    ;;

  *)
    die "unknown VKS_AUTH_METHOD='$METHOD' (expected: kubeconfig | vcf | vsphere)"
    ;;
esac

# ---- Select the context if named, then PROVE connectivity -----------------
if [ -n "${VKS_CONTEXT:-}" ]; then
  kubectl config use-context "$VKS_CONTEXT" >/dev/null 2>&1 \
    || log_warn "context '$VKS_CONTEXT' not found in $KUBECONFIG; using current context"
fi

log_info "verifying cluster reachability..."
if kubectl cluster-info >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
  log_info "connected. Current context: $(kubectl config current-context)"
  kubectl get nodes -o wide >&2
else
  die "cannot reach the VKS cluster with the current kubeconfig/context — check network + auth"
fi
