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
    : "${VKS_CONTEXT_NAME:?set VKS_CONTEXT_NAME in .env (the vcf context NAME, passed positionally)}"
    # NOTE: VKS_NAMESPACE is deliberately NOT required here — it is discovered after the context
    # exists (see below). VKS_USERNAME is defaulted, loudly.

    # Username must be 'user@SSO.DOMAIN' — single-sourced with 31-fetch-argocd-kubeconfig.sh via
    # vks_sso_user() (lib/os.sh): idempotent on '@', dies on a bare user with no VKS_SSO_DOMAIN.
    #
    # The default is ANNOUNCED, never silent. configuration.md forbids a silent default for a
    # security-relevant PRINCIPAL: authenticating as a plausible-but-wrong identity is worse than a
    # hard stop, because it fails somewhere else (or, worse, succeeds as the wrong user). The value
    # below is the vCenter SSO admin used by the field labs this repo targets — it is a STARTING
    # GUESS, not a fact about your lab.
    if [ -z "${VKS_USERNAME:-}" ]; then
      VKS_USERNAME="administrator@wld.sso"
      log_warn "VKS_USERNAME is unset — defaulting to '${VKS_USERNAME}' (a vCenter SSO admin)."
      log_warn "  If your lab uses a different SSO domain or a tenant user, set VKS_USERNAME in .env."
    fi
    user="$(vks_sso_user "$VKS_USERNAME")"

    # Build argv WITHOUT any secret (security.md: secrets never in argv). Endpoint + username
    # are non-secret.
    #
    # ✅ SETTLED ON A REAL LAB 2026-07-22 (VCF 9.1 Supervisor). What was previously deferred to
    # docs/lab-validation-plan.md step 3 is now measured, and this argv reflects it:
    #
    #   vcf context create sup --endpoint 10.1.8.132 --insecure-skip-tls-verify --auth-type basic
    #   vcf context use sup:<namespace>            → plain `kubectl` worked immediately
    #
    #   * CONTEXT_NAME is a REQUIRED POSITIONAL — it is not prompted for. The old form passed none
    #     and would have errored `accepts 1 arg(s), received 0`. FIXED below.
    #   * --endpoint takes a BARE host/IP with NO scheme. The old `https://…` form is unverified;
    #     the bare form is what ran, and it is also what a second, independent automation of these
    #     same labs uses. FIXED below.
    #   * --auth-type basic and --insecure-skip-tls-verify are both accepted (do not "fix" them).
    #   * --username was OMITTED in the verified run and login still succeeded, so it is optional.
    #     We still pass it: an explicit principal beats an interactively-resolved one, and the
    #     operator asked for it to come from .env. Broadcom documents --username as applying to the
    #     'kubernetes' context type, and the working third-party automation pairs it with
    #     `-t kubernetes`, so we pair them too rather than sending --username bare.
    #
    # STILL UNVERIFIED: the --username + --type pairing itself was not in the lab-verified run. If
    # this call rejects either flag, the minimal form above is known-good — fall back to it and
    # tell us, per lab-validation-plan step 3.
    create_args=("$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" --username "$user" --type kubernetes --auth-type basic)
    if is_true "${VKS_INSECURE_SKIP_TLS_VERIFY:-}"; then   # one truthiness rule, repo-wide (lib/os.sh)
      create_args+=(--insecure-skip-tls-verify)
    fi

    log_info "creating VCF context '${VKS_CONTEXT_NAME}' for the Supervisor at ${SUPERVISOR_HOST} (user: ${user})"
    log_warn "INTERACTIVE: expect a PASSWORD prompt. To avoid it, export VCF_CLI_VSPHERE_PASSWORD"
    log_warn "  (the only supported mechanism — there is no --password flag and no stdin form)."
    log_warn "  Do NOT use 'vcf config set env.…' — it writes the password in plaintext to disk."
    log_warn "If this call rejects --username or --type, fall back to the LAB-VERIFIED minimal form:"
    log_warn "  vcf context create '${VKS_CONTEXT_NAME}' --endpoint '${SUPERVISOR_HOST}' --insecure-skip-tls-verify --auth-type basic"
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

    # Namespace: pinned in .env, or DISCOVERED from the contexts the create above just produced.
    # Discovery must run AFTER `vcf context create` — there is nothing to list before it.
    #
    # ⚠️ VKS_NAMESPACE has a DYNAMIC FALLBACK now, so it MUST stay COMMENTED in .env.example.
    # load_env sources that file with `set -a`; an uncommented placeholder would be exported and
    # would silently defeat this discovery for every operator. `make check-env-clobber` gates it.
    if [ -z "${VKS_NAMESPACE:-}" ]; then
      log_info "VKS_NAMESPACE is unset — discovering it from 'vcf context list'"
      VKS_NAMESPACE="$(vks_discover_namespace "$VKS_CONTEXT_NAME")"
      log_info "  discovered namespace: ${VKS_NAMESPACE}"
    fi

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
