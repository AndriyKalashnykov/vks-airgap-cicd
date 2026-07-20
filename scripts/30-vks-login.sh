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

    # Username must be 'user@SSO.DOMAIN' — single-sourced with 31-fetch-argocd-kubeconfig.sh via
    # vks_sso_user() (lib/os.sh): idempotent on '@', dies on a bare user with no VKS_SSO_DOMAIN.
    user="$(vks_sso_user "$VKS_USERNAME")"

    # Build argv WITHOUT any secret (security.md: secrets never in argv). Endpoint + username
    # are non-secret.
    #
    # 🔴 THE "it prompts for the context name" CLAIM IS REFUTED [9.0-doc]. Broadcom's command
    # reference gives the synopsis `vcf context create CONTEXT_NAME [flags]` — CONTEXT_NAME is a
    # REQUIRED POSITIONAL, there is no --name flag, and all four documented examples pass it
    # positionally. Nothing documents a name prompt. So this call is missing a required argument
    # and most likely errors `accepts 1 arg(s), received 0`.
    # Our OWN sibling gets it right: 31-fetch-argocd-kubeconfig.sh:77 is
    #   `vcf context create "$CTX" --endpoint … --type k8s`
    # — positional AND `--type k8s` (--username is documented "only applicable for 'kubernetes'
    # context type"). This file has neither. The two forms contradict each other and NEITHER HAS
    # EVER RUN, which is exactly what docs/lab-validation-plan.md step 3 exists to settle — so the
    # argv is deliberately NOT changed here on doc evidence alone. Fix both scripts together from
    # the real `--help`, per that step.
    # `--auth-type basic` IS valid (the reference lists 'oidc'|'basic'|empty) — do not "fix" it.
    create_args=(--endpoint "https://${SUPERVISOR_HOST}" --username "$user" --auth-type basic)
    if is_true "${VKS_INSECURE_SKIP_TLS_VERIFY:-}"; then   # one truthiness rule, repo-wide (lib/os.sh)
      create_args+=(--insecure-skip-tls-verify)
    fi

    log_info "creating a VCF context for the Supervisor at https://${SUPERVISOR_HOST} (user: ${user})"
    log_warn "INTERACTIVE: expect a PASSWORD prompt. To avoid it, export VCF_CLI_VSPHERE_PASSWORD"
    log_warn "  (the only supported mechanism — there is no --password flag and no stdin form)."
    log_warn "  Do NOT use 'vcf config set env.…' — it writes the password in plaintext to disk."
    log_warn "UNVERIFIED: this call passes NO context-name positional, but Broadcom documents"
    log_warn "  'vcf context create CONTEXT_NAME [flags]' as required. If it errors with"
    log_warn "  'accepts 1 arg(s), received 0', that is the known bug — see lab-validation-plan step 3,"
    log_warn "  and re-run with: vcf context create '${VKS_CONTEXT_NAME}' --endpoint https://${SUPERVISOR_HOST} --username '${user}' --auth-type basic"
    # THE PASSWORD MECHANISM IS NOW ESTABLISHED [9.0-doc] — the old TODO here is answered:
    #   * There is NO --password flag. Confirmed by the command reference and by a practitioner
    #     ("The vcf CLI doesn't include a way to provide this password through parameters").
    #     Do not add one — a password on argv is forbidden (security.md).
    #   * There is NO documented STDIN mechanism. NOT STATED anywhere reachable; do not invent one.
    #   * The ONE supported way is the env var `VCF_CLI_VSPHERE_PASSWORD`. Verbatim: "You can also
    #     set an environment variable VCF_CLI_VSPHERE_PASSWORD with the password value." It reaches
    #     the CLI through execve's envp, never argv, so it satisfies security.md.
    #
    # 🔴 NEVER run `vcf config set env.VCF_CLI_VSPHERE_PASSWORD <value>`. The same page documents it,
    # and it writes the password IN PLAINTEXT to $HOME/.config/vcf/config.yaml where it "persists
    # until you unset" it — outside the repo, invisible to gitleaks and to check-secrets-untracked
    # (which only sees tracked paths), and surviving every teardown. Same residue class as the
    # /etc/docker/certs.d incident. Export it for the session, or inject it from a secret manager
    # (`op run -- …`, `vault exec -- …`); do not persist it to disk.
    #
    # NOT WIRED HERE, DELIBERATELY. The correct wiring is a COMMAND-SCOPED prefix reusing the
    # VKS_PASSWORD that already exists (.env.example:805), mirroring line ~92 below:
    #     [ -n "${VKS_PASSWORD:-}" ] && pw=(VCF_CLI_VSPHERE_PASSWORD="$VKS_PASSWORD")
    #     env "${pw[@]}" vcf context create "$VKS_CONTEXT_NAME" …
    # Command-scoped, not exported: a bare `export` would put a vCenter SSO admin password in the
    # environment of every kubectl/helm/crane/git this script later spawns, readable in each
    # /proc/<pid>/environ. The non-empty guard is NOT optional — an unguarded empty assignment
    # CLOBBERS an operator who exported the var themselves, turning a working non-interactive
    # login into an auth failure. It lands together with the positional-name fix above, after lab
    # step 3, because wiring a password into a call that is missing a required argument would only
    # make a broken path LOOK automated.
    # Note also: the prompt recurs at token refresh [community], so a long `make install-all` can
    # block mid-run; that is the case for exporting it for the session, deliberately.
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
