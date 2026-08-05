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

    # vks_username() (lib/os.sh) resolves the effective SSO principal: it applies the shared default,
    # ANNOUNCES it, honours VKS_SSO_DOMAIN, and normalises through vks_sso_user (idempotent on '@',
    # dies on a bare user with no domain — the C10 guard).
    #
    # SHARED with 31-fetch-argocd-kubeconfig.sh on purpose. The default first lived here as a local
    # assignment, so it reached nothing else while that script kept an unconditional `:?` — which made
    # .env.example's "OPTIONAL" claim true for `make vks-login` and FALSE for
    # `make fetch-argocd-kubeconfig`. A default not shared by every consumer is not a default.
    #
    # The announce is required, not decorative: configuration.md forbids a SILENT default for a
    # security-relevant PRINCIPAL — a plausible-but-wrong identity fails somewhere else, or succeeds
    # as the wrong user. The value is a STARTING GUESS for the field labs this repo targets, never a
    # fact about your lab. Covered by `make test-vks-username`.
    user="$(vks_username)"

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
    # TLS: prefer a VERIFIED CA over skipping verification. MEASURED 2026-08-04 —
    # `vcf context create --help` documents BOTH:
    #     --ca-certificate string     Path to the endpoint public certificate file
    #     --insecure-skip-tls-verify  Skip TLS certificate verification for endpoint
    # The old code offered only the second, so the only documented path in scenario-1 §3
    # turned verification OFF — against a Supervisor whose CA this repo already knows how to
    # fetch and pin (VKS_CA_CERT_FILE, and the same VERIFIED pattern as fetch-harbor-ca).
    # A sibling automation of these same labs passes --ca-certificate with the VMCA root.
    #
    # The elif is REQUIRED, not merely tidy: MEASURED 2026-08-04, the CLI enforces these as an
    # EXCLUSIVE flag group — passing both fails with
    #   [x] : … [ca-certificate insecure-skip-tls-verify] were all set
    # Order is deliberate: an explicitly-set CA WINS, so setting both cannot silently downgrade
    # you to unverified TLS.
    if [ -n "${VKS_CA_CERT_FILE:-}" ] && [ -s "${VKS_CA_CERT_FILE}" ]; then
      create_args+=(--ca-certificate "$VKS_CA_CERT_FILE")
      log_info "TLS: verifying the Supervisor against ${VKS_CA_CERT_FILE}"
    elif is_true "${VKS_INSECURE_SKIP_TLS_VERIFY:-}"; then   # one truthiness rule, repo-wide (lib/os.sh)
      create_args+=(--insecure-skip-tls-verify)
      log_warn "TLS: verification is OFF (VKS_INSECURE_SKIP_TLS_VERIFY). Prefer VKS_CA_CERT_FILE —"
      log_warn "  a credential is submitted over this connection."
    elif [ -n "${VKS_CA_CERT_FILE:-}" ]; then
      die "VKS_CA_CERT_FILE='${VKS_CA_CERT_FILE}' is set but missing or empty. Refusing to fall
back to skipping TLS verification: that would silently downgrade a connection you asked to verify."
    fi
    # Neither set: the CLI verifies against the system trust store and fails closed with
    # 'x509: certificate signed by unknown authority' — the correct outcome, and it costs NO
    # auth attempt (it fails before authenticating). MEASURED 2026-08-04.

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
    # --- IDEMPOTENCE: `vcf context create` REFUSES a duplicate name -------------------
    # Measured (nested-vsphere-lab B209): a second run dies with `context "<name>" already
    # exists`, and the error text talks about CREDENTIALS — it sent an operator to check a
    # password that was fine. The context store is ~/.config/vcf/config.yaml: OUTSIDE this
    # repo and outside any teardown, so it survives every destroy and blocks every rebuild.
    #
    # Delete-then-create, NOT reuse. Reuse was designed and REFUTED: the obvious probe
    # (`kubectl get ns`) reads $KUBECONFIG — the GUEST cluster — while `vcf context use`
    # acts on the context's OWN kubeconfigpath. A reuse predicate built on that reports
    # "healthy, no password needed" while pointing at the wrong cluster. Do not add it back
    # without a probe that reads the context's OWN kubeconfig. ⚠️ The field is
    # `.clusterOpts.path` (+ `.clusterOpts.context`) — MEASURED: `vcf context get` and
    # `vcf context list` return DIFFERENT SCHEMAS, and `get` has no `.kubeconfigpath` key at
    # all, so a `jq .kubeconfigpath` probe returns null forever and reads as "no kubeconfig".
    #
    # We only ever delete OUR OWN $VKS_CONTEXT_NAME — "delete only what you created".
    #   -y                            : else it PROMPTS (hangs a tty run, errors in CI)
    #   --skip-delete-kubeconfig-context : -y otherwise also mutates the caller's kubeconfig
    # An unconditional delete needs no existence check, so it cannot get one wrong: a
    # substring `case` matches `vks-cicd` inside `vks-cicd-old`, and a `$(…)` capture of
    # `vcf context list` trips `set -e` when no context exists.
    log_info "removing any pre-existing vcf context named '${VKS_CONTEXT_NAME}' (create refuses duplicates)"
    vcf context delete "$VKS_CONTEXT_NAME" -y --skip-delete-kubeconfig-context >/dev/null 2>&1 || true

    # --- PASSWORD: presence only, never the value (security.md) ------------------------
    # VCF_CLI_VSPHERE_PASSWORD is the ONLY supported mechanism (no --password flag, no stdin
    # form) and it reaches the CLI through execve's envp, never argv — so an already-exported
    # value needs NO wiring here. Do NOT read it from .env: docs/scenario-1.md §1 forbids the
    # Supervisor password in .env, and .env.example scopes VKS_PASSWORD to the legacy
    # `vsphere` method only.
    if [ -z "${VCF_CLI_VSPHERE_PASSWORD:-}" ]; then
      log_warn "VCF_CLI_VSPHERE_PASSWORD is not exported — this run will PROMPT, and will FAIL in CI."
      log_warn "  export it for the session (docs/scenario-1.md §1). NEVER 'vcf config set env.…',"
      log_warn "  which writes it in plaintext to ~/.config/vcf/config.yaml, outside every teardown."
    fi

    # VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=1: create otherwise tries to
    # DOWNLOAD recommended plugins. On the air-gapped jump box this repo exists for, that is
    # a hang or a confusing failure AT THE AUTH STEP, which reads as a credential fault.
    # </dev/null: a non-tty then gets a deterministic error instead of blocking on the prompt.
    # --- ISOLATION: do NOT let the vcf CLI write into the GUEST kubeconfig -------------
    # MEASURED 2026-08-04: `vcf context create` snapshots $KUBECONFIG, writes its Supervisor
    # contexts INTO that file, and repoints its current-context at the Supervisor:
    #     secrets/vks.kubeconfig  current-context: lab-gc1 (guest, :6443)
    #                         ->  current-context: vks-cicd:lab (SUPERVISOR, :443)
    # Nothing in this repo passes `--context` (0 hits), so every later kubectl — and
    # `make platform` / `make gitops` — would silently target vSphere's CONTROL PLANE
    # instead of the workload cluster. Give the CLI its own file.
    #
    # COMMAND-SCOPED, not a subshell: matches 31-fetch-argocd-kubeconfig.sh's idiom, cannot
    # leak, and keeps the create's own exit status (a subshell would merge create+use).
    # `--kubeconfig` is NOT an option here — MEASURED, the CLI enforces
    # [endpoint kubeconfig] as an exclusive group, so the env var is the only route.
    # ABSOLUTE path on purpose: the chosen path is PERSISTED into ~/.config/vcf/config.yaml
    # and resolved at USE time, so a relative one breaks from any other cwd.
    SUP_KUBECONFIG="${VKS_SUPERVISOR_KUBECONFIG:-${REPO_ROOT}/secrets/supervisor.kubeconfig}"
    mkdir -p "$(dirname "$SUP_KUBECONFIG")"
    log_info "vcf contexts -> ${SUP_KUBECONFIG} (KUBECONFIG=${KUBECONFIG} is left untouched)"

    KUBECONFIG="$SUP_KUBECONFIG" VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=1 \
      vcf context create "${create_args[@]}" </dev/null

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
    # ⚠️ `vcf context use` EXITS NON-ZERO AFTER SUCCEEDING. MEASURED 2026-08-04 on a live 9.1
    # Supervisor — it activates the context and THEN fails a post-activation step:
    #   [i] Successfully activated context 'vks-cicd:lab' (Type: kubernetes)
    #   [x] : failed to discover plugin sources from the system Harbor registry: the system
    #         Harbor registry could not be discovered from the Supervisor cluster.
    # A Supervisor only has a "system Harbor registry" if one is registered AS SUCH; installing
    # Harbor as a Supervisor Service does NOT make it that. So this fails on a perfectly good
    # lab, and on an air-gapped one it reaches for a registry that is not there at all.
    #
    # ⚠️ VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=1 DOES **NOT** SUPPRESS IT — that
    # was tried and MEASURED not to work, and `vcf context use --help` has no skip flag. It is
    # set below only for symmetry with `create`; do not read it as the fix.
    #
    # So the status cannot be the verdict. Tolerate it and VERIFY THE END RESULT below.
    # ⚠️ Do NOT verify via `vcf context list`'s `.iscurrent`: that lives in
    # ~/.config/vcf/config.yaml, a DIFFERENT state store from the kubeconfig, and the two were
    # measured DISAGREEING — `iscurrent=true` for a kubecontext absent from the very file the
    # same record names. Only the artifact settles it.
    KUBECONFIG="$SUP_KUBECONFIG" VCF_CLI_SKIP_CONTEXT_RECOMMENDED_PLUGIN_INSTALLATION=1 \
      vcf context use "${VKS_CONTEXT_NAME}:${VKS_NAMESPACE}" </dev/null \
      || log_warn "'vcf context use' exited non-zero — verifying the end result before judging it"

    # VERIFY THE ARTIFACT, because the status above cannot be trusted and neither can
    # `vcf context list`'s `.iscurrent`: that lives in ~/.config/vcf/config.yaml, a DIFFERENT
    # store from the kubeconfig, and the two were MEASURED disagreeing — `iscurrent=true` for a
    # kubecontext absent from the very file the same record names. Only a read settles it.
    kubectl --kubeconfig "$SUP_KUBECONFIG" -n "$VKS_NAMESPACE" get ns >/dev/null 2>&1 \
      || die "the Supervisor context did not come up: ${SUP_KUBECONFIG} cannot list namespaces in
'${VKS_NAMESPACE}'. Inspect: KUBECONFIG='${SUP_KUBECONFIG}' vcf context list"
    log_info "Supervisor context verified via ${SUP_KUBECONFIG}"

    # PUBLISH IT — this pairing is MANDATORY, not a nicety. 70-configure-argocd.sh does
    # `ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-$KUBECONFIG}"`, and `install-all` does NOT run
    # `fetch-argocd-kubeconfig`. Until now ArgoCD ops reached the Supervisor BY ACCIDENT — via
    # the very pollution isolated above. Remove the pollution without publishing this and the
    # fallback lands on the GUEST, where argocd-server does not exist.
    if [ -z "${ARGOCD_KUBECONFIG:-}" ]; then
      state_set ARGOCD_KUBECONFIG "$SUP_KUBECONFIG"
      log_info "published ARGOCD_KUBECONFIG=${SUP_KUBECONFIG} (ArgoCD runs on the SUPERVISOR;"
      log_info "  without this 'make gitops' would fall back to the GUEST kubeconfig)"
    fi

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
