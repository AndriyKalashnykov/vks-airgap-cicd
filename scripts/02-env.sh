#!/usr/bin/env bash
# scripts/02-env.sh — operator-facing .env lifecycle: init | populate | check | validate.
#
# One coherent UX so nobody hand-copies .env.example or guesses which values to set.
# Values fall into THREE sources (see .env.example stage: comments):
#   GENERATE     — secrets for the components WE install (Gitea admin/CI; a throwaway
#                  Harbor/ArgoCD password for the local KinD stand-in). env-populate mints them.
#   DISCOVER     — only knowable AFTER install (Harbor/ArgoCD LB IPs, workload kubeconfig).
#                  env-populate reads them from a reachable cluster; the KinD flow also
#                  auto-writes them to .env.state. Real lab: kubectl/vcf per the how: comments.
#   user-PROVIDE — only the operator knows (vCenter/SSO specifics, the real Harbor admin/robot
#                  secret, where the licensed VCF CLIs were dropped). env-populate PRINTS these.
#
# Subcommands:
#   init      backup an existing .env → .env.bak, then cp .env.example → .env
#   populate  GENERATE the secrets we can + DISCOVER cluster values (best-effort) → .env,
#             then PRINT the user-PROVIDE list still to set
#   check     presence: fail if a required value is missing/placeholder (fast, no network)
#   validate  validity: format + KUBECONFIG/Harbor connectivity+auth (fail fast; secrets
#             never touch argv — Harbor auth goes through a umask-077 `curl -K` config file)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# ⚠️ REQUIRED for ca_verifies_endpoint in the Harbor TLS arm below — os.sh does NOT pull tls.sh in, and
# without this the call is `command not found` (rc 127), which would turn a diagnostic into a crash on the
# exact path an operator hits after a rebuild. tls.sh has an idempotent load guard and no side effects.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

ENV_FILE="${REPO_ROOT}/.env"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"

# A value is "unset" for our purposes if empty OR still a committed placeholder.
# is_placeholder now lives in lib/os.sh (sourced above): lib/harbor.sh's auth probe needs it too,
# and 24-lab-preflight.sh sources lib/os.sh but not this file. One definition, both consumers.

# HARBOR_URL is COMMENTED in .env.example (B13), so it is UNSET by default — is_placeholder catches
# that (empty). But an operator may still type `harbor.vks.local` (this repo's own `.vks.local`
# convention) as a "not configured yet" value; the real value is the discovered LB IP (KinD) or the
# lab's Harbor host. That sentinel is neither empty nor a <SET-*> token, so env_check AND env_validate
# test BOTH cases via this helper. The sentinel literal lives ONCE, inside this function body: a
# function def is immune to load_env's `set -a; . .env` (a top-level var would be clobbered by it).
harbor_url_is_placeholder() { case "${1:-}" in ''|harbor.vks.local) return 0 ;; *) return 1 ;; esac; }

# Upsert KEY=VALUE into .env (idempotent — replaces an existing line, else appends).
env_set() { set_env_var "$1" "$2" "$ENV_FILE"; }

# ---------------------------------------------------------------------------
# init — fresh .env from the committed source of truth (old one saved to .env.bak)
# ---------------------------------------------------------------------------
env_init() {
  [ -f "$EXAMPLE_FILE" ] || die ".env.example missing at $EXAMPLE_FILE (the committed source of truth)"
  # ⚠️ THIS is where .env's mode is really decided, and it was 0664. `.env.example` is committed 0644
  # and `cp` to a non-existent target yields source-mode & ~umask, so at this box's umask 002 the file
  # is BORN world-readable — measured: `.env.example 664 -> .env 664 -> still 664 after a
  # HARBOR_PASSWORD publish`. Hardening set_env_var alone does NOT close it, because the single most
  # sensitive credential never passes through set_env_var at all: `docs/scenario-1.md` tells the
  # operator to HAND-EDIT VCENTER_PASSWORD (the vSphere SSO administrator) into this file at Step 2,
  # and the first hardening writer does not run until Step ~5 — permanently if the walk diverges.
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    chmod 600 "${ENV_FILE}.bak" 2>/dev/null || true   # a FULL credential copy; it inherits cp's mode
    log_warn "existing .env backed up to .env.bak (your previous overrides are preserved there)"
  fi
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  log_info "wrote a fresh .env from .env.example"
  echo
  echo "Next:"
  echo "  make env-populate   # generate the secrets we can + print what only you can provide"
  echo "  make env-check      # confirm the required values are set"
}

# ---------------------------------------------------------------------------
# populate — GENERATE ours + DISCOVER (best-effort) + PRINT user-PROVIDE
# ---------------------------------------------------------------------------
env_populate() {
  [ -f "$ENV_FILE" ] || die "no .env yet — run 'make env-init' first"
  load_env   # so we can see which values are already set (and honor the .env.state overlay)

  echo "== GENERATE (secrets for the components we install — minted only if unset) =="
  # Gitea is ALWAYS ours → always safe to generate.
  local g_admin g_ci h_pw a_pw made=0
  if is_placeholder "${GITEA_ADMIN_PASSWORD:-}"; then g_admin="$(gen_password)"; env_set GITEA_ADMIN_PASSWORD "$g_admin"; echo "  + GITEA_ADMIN_PASSWORD  (generated)"; made=1; fi
  if is_placeholder "${GITEA_CI_PASSWORD:-}";    then g_ci="$(gen_password)";    env_set GITEA_CI_PASSWORD    "$g_ci";    echo "  + GITEA_CI_PASSWORD     (generated)"; made=1; fi
  # Harbor/ArgoCD passwords: a throwaway default that works out-of-the-box for the local
  # KinD stand-in / a self-hosted Harbor. On a REAL lab these are given to you — OVERRIDE
  # HARBOR_PASSWORD with the admin/robot secret (env-populate never clobbers a value you set).
  if is_placeholder "${HARBOR_PASSWORD:-}";        then h_pw="$(gen_password)"; env_set HARBOR_PASSWORD        "$h_pw"; echo "  + HARBOR_PASSWORD       (generated — OVERRIDE for a real lab)"; made=1; fi
  # ⚠️ AND ON A REAL LAB IT MUST NOT BE GENERATED AT ALL. This line said "KinD only; real lab sets
  # its own" and then generated it on a real lab anyway — nothing enforced the comment. MEASURED,
  # walk row 1 (2026-08-12): minted here at 20:03:46Z, and at 20:16:17Z scenario-1's PAYOFF step
  # printed `ArgoCD  https://192.168.101.131  admin  Hn2Hnb25luInR4fT` and exited 0. That string was
  # never set on anything: ArgoCD is a SUPERVISOR Service and the context in that same render is the
  # GUEST cluster, which has no `cicd` namespace at all — so the live-read path could not have
  # answered, and argocd-password.sh's fallback presented the invention as ArgoCD's password.
  # A fabricated credential is indistinguishable from a real one, which is why nobody caught it.
  # VKS_NAMESPACE is the discriminator: `.env.example:1027` ships it COMMENTED, so it is empty on
  # KinD (generate, as before) and set from Step 2 on a real lab (never invent).
  if is_placeholder "${ARGOCD_ADMIN_PASSWORD:-}"; then
    if [ -n "${VKS_NAMESPACE:-}" ]; then
      echo "  - ARGOCD_ADMIN_PASSWORD (NOT generated: VKS_NAMESPACE is set, so ArgoCD is lab-provided —"
      echo "                           inventing one here would be printed as fact by 'make creds-show')"
    else
      a_pw="$(gen_password)"; env_set ARGOCD_ADMIN_PASSWORD "$a_pw"
      echo "  + ARGOCD_ADMIN_PASSWORD (generated — KinD only; real lab reads it with 'make argocd-password')"; made=1
    fi
  fi
  [ "$made" = 1 ] || echo "  (all already set — nothing generated)"

  echo
  echo "== DISCOVER (values only knowable after install — read from a reachable cluster) =="
  # ⚠️ FOUR CONDITIONS, FOUR ANSWERS. This was one `&&` chain with a single `else`, so "kubectl is
  # not installed", "there is no kubeconfig yet", "no context is selected" and "the kubeconfig is
  # from a lab that was destroyed" all printed the identical "(no reachable cluster — skipping)".
  # They need different remedies, and `2>&1` on the probe threw away the only evidence separating
  # the last two. The no-context case is not hypothetical: with no current-context kubectl silently
  # targets http://localhost:8080 and "fails to reach the cluster" while never dialling the lab.
  local _disc=0
  if ! have kubectl; then
    echo "  (kubectl is not on PATH — skipping discovery. Install the toolchain:)"
    echo "     make deps"
  elif [ ! -s "${KUBECONFIG:-/nonexistent}" ]; then
    echo "  (no kubeconfig at '${KUBECONFIG:-unset}' — skipping discovery. Get one:)"
    echo "     make vks-login    # real lab — authenticates and writes KUBECONFIG"
    echo "     make kind-up      # the local KinD stand-in"
  elif ! kubectl config current-context >/dev/null 2>&1; then
    echo "  (the kubeconfig at '${KUBECONFIG}' has NO CURRENT CONTEXT — skipping discovery."
    echo "   Nothing was probed: with no context kubectl targets http://localhost:8080, so any"
    echo "   verdict here would describe this machine, not the lab. Select one:)"
    echo "     kubectl config use-context <name>   # $(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ' || true)"
  else
    local _perr; _perr="$(mktemp)"
    if kubectl cluster-info >/dev/null 2>"$_perr"; then
      _disc=1
    elif [ "$(classify_kube_failure "$_perr")" = STALE_CA ]; then
      # The case an operator cannot diagnose unaided: right address, dead credentials.
      echo "  (the kubeconfig at '${KUBECONFIG}' does NOT match the cluster it points at — skipping"
      echo "   discovery. The server ANSWERED, so this is not a network fault: a REBUILT cluster mints"
      echo "   a new CA while the address stays the same. Re-export it, then re-run this:)"
      echo "     make vks-login"
    else
      echo "  (no reachable cluster — skipping. The KinD flow auto-writes these to .env.state;"
      echo "   on a real lab, re-authenticate or discover them after install:)"
      echo "     make vks-login"
      echo "     HARBOR_URL:    kubectl -n <harbor-ns>  get svc -o jsonpath='{...loadBalancer.ingress[0].ip}'"
      echo "     ARGOCD_SERVER: kubectl -n <argocd-ns>  get svc argocd-server -o jsonpath='{...loadBalancer.ingress[0].ip}'"
      echo "     KUBECONFIG:    vcf cluster kubeconfig get <cluster> --export-file ./secrets/vks.kubeconfig"
    fi
    # `rm` precedes all die-capable code in this function; if the discovery block below is ever
    # moved INSIDE this else, env_set can die and this leaks — use a RETURN trap then.
    rm -f "$_perr"
  fi
  if [ "$_disc" = 1 ]; then
    local hip aip
    hip="$(kubectl -n "${HARBOR_NAMESPACE:-harbor}" get svc -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep -m1 -E '^[0-9]' || true)"
    aip="$(kubectl -n "${ARGOCD_NAMESPACE:-argocd}" get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    # Only WRITE a discovered value over a PLACEHOLDER — never clobber a tenant's GRANTED HARBOR_URL /
    # ARGOCD_SERVER with a guest LB IP that happens to match the query (e.g. a guest svc named 'harbor').
    if   [ -n "$hip" ] && harbor_url_is_placeholder "${HARBOR_URL:-}"; then env_set HARBOR_URL "$hip"; echo "  + HARBOR_URL  = $hip  (discovered)";
    elif [ -n "$hip" ]; then echo "  = HARBOR_URL  already set (${HARBOR_URL}) — not overwriting with discovered $hip";
    else echo "  - HARBOR_URL  not discovered (Harbor LB not up yet)"; fi
    if   [ -n "$aip" ] && is_placeholder "${ARGOCD_SERVER:-}"; then env_set ARGOCD_SERVER "$aip"; echo "  + ARGOCD_SERVER = $aip  (discovered)";
    elif [ -n "$aip" ]; then echo "  = ARGOCD_SERVER already set (${ARGOCD_SERVER}) — not overwriting with discovered $aip";
    else echo "  - ARGOCD_SERVER not discovered (ArgoCD LB not up yet)"; fi
  fi

  echo
  echo "== user-PROVIDE (only YOU know — set these in .env by hand) =="
  echo "  Real VKS lab (skip for the local KinD flow):"
  echo "    SUPERVISOR_HOST      vCenter → Workload Management → Supervisors → Control Plane IP"
  echo "    VKS_NAMESPACE        OPTIONAL on the vcf path — discovered from 'vcf context list'; set it only to PIN one"
  echo "    VKS_USERNAME         OPTIONAL (defaults, announced) — REQUIRED only for VKS_AUTH_METHOD=vsphere; set it if your SSO domain differs"
  echo "    VKS_CLUSTER_NAME     the VKS workload cluster name"
  echo "    HARBOR_USERNAME      'admin' if you installed Harbor (Scenario 1); the robot login robot\$<name> for a tenant (Scenario 2) — the local KinD flow sets this itself"
  echo "    HARBOR_PASSWORD      OVERRIDE the generated value with the lab's admin/robot secret"
  echo "    VCF_CLI_SRC_DIR      folder holding the licensed VCF/argocd-vcf CLI archives (make install-vcf-clis)"
      # 4 KEYS WERE MISSING HERE UNTIL 2026-08-25, AND THE OMISSION STRANDED THE OPERATOR.
      # MEASURED: scenario-1.md Step 1 lists 9 keys; this block carried only 5 of them.
      # VKS_AUTH_METHOD is the KEYSTONE, and env_check could NOT save you -- it is guarded by
      #   vcf) required+=(SUPERVISOR_HOST VKS_CONTEXT_NAME) ;;    <- see env_check, below
      # so an operator who never sets VKS_AUTH_METHOD gets the `kubeconfig` default, that branch
      # never runs, and env_check passes GREEN on a real-lab .env missing both. They then reach
      # `make vks-login`, which HARD-DIES on VKS_CONTEXT_NAME (30-vks-login.sh's :? die-set), and
      # fixing that alone drops them onto the interactive password path against an account that
      # locks out PERMANENTLY after 3 attempts.
      # THE DOC WAS RIGHT; THIS TOOL WAS WRONG. Root cause: this block (last touched 2026-07-11)
      # and the doc table (2026-08-13) are two HAND-TYPED lists with nothing linking them.
      echo "    VKS_AUTH_METHOD      set it to vcf for a REAL LAB (Step 1). It defaults to kubeconfig, which is right for the local"
      echo "                         KinD flow (05-kind-up.sh writes it) and makes Step 3 fail looking for a cluster you have not"
                                   # ^ nuance the doc carries too: Step 6 flips it back to kubeconfig once the guest cluster exists.
      echo "                         created yet. Step 6 changes it back for you."
      echo "    VKS_CONTEXT_NAME     you invent this - a short label for the vcf login context. REQUIRED: make vks-login dies without it"
      echo "    VKS_SSO_DOMAIN       vCenter > Administration > Single Sign On > Users and Groups > Domain (needed only if VKS_USERNAME is bare, with no @)"
      echo "    VCF_CLI_VSPHERE_PASSWORD  your vCenter SSO password. Put it in .env IN SINGLE QUOTES. Unquoted it is SILENTLY MANGLED - a"
      echo "                              doubled dollar becomes the shell PID, so the value DIFFERS EVERY RUN with no error, and each retry"
      echo "                              spends a fresh attempt on an account that LOCKS OUT PERMANENTLY after 3. See scenario-1.md Step 1."
  echo
  log_info "populate done — run 'make env-check' then 'make env-validate'"
}

# ---------------------------------------------------------------------------
# check — presence only (fast, no network)
# ---------------------------------------------------------------------------
env_check() {
  # WARN, not die, on an ABSENT .env. This gate's very next line is `load_env`, which under
  # SKIP_DOTENV=1 is CONTRACTUALLY OBLIGED TO IGNORE the file (lib/os.sh logs "IGNORING .env") --
  # so demanding the file's PRESENCE here is incoherent, and it made the documented KinD quickstart
  # impossible on a clean clone (B478): `make e2e-kind` -> install-all -> preflight -> here -> rc=2
  # "no .env yet", while README/kind-local/Makefile:201 all promise "zero .env" and call it ENFORCED.
  #
  # The VALUE checks below stay, and they are the teeth: on the KinD path every required value comes
  # from `.env.state` (published by kind-up/install-harbor/install-argocd), so an absent .env is fine
  # while a BLANK generated secret still fails -- which is the regression this gate exists for
  # (lib/os.sh:610 records a CI run that FATAL'd on an empty HARBOR_PASSWORD while local was green).
  # Making this a NO-OP under SKIP_DOTENV would have disabled exactly that; measured, and refuted.
  #
  # NOT gated on SKIP_DOTENV, deliberately: it needs no variable threaded through two sub-makes to
  # be correct, and on a real-lab FIRST run "5 required values missing, here they are" beats "no
  # .env yet", which names a FILE when the reader's problem is VALUES.
  #
  # ⚠️ NOT "strictly dominates" -- that claim was measured FALSE and is corrected here. On a box
  # with NO .env but a STALE .env.state (any dev box that ran the KinD e2e and never `kind-down`ed,
  # since that only removes a KIND-STAMPED sink), this now returns rc=0 where it used to hard-stop:
  # measured rc=1 -> rc=0. preflight has no env-validate backstop, so install-all would then mirror
  # to the OVERLAY's HARBOR_URL. The codebase already accepts that hazard -- with a real .env plus
  # the same stale overlay, the PRE-FIX gate is ALSO rc=0 and the overlay's HARBOR_URL still wins --
  # so this WIDENS an accepted hazard rather than creating one. Named, not hidden; state_stamp and
  # its "does not record which cluster it belongs to" warning are the existing mitigation.
  # env_populate and env_validate keep their `die`: the file is a write target / a read source there.
  [ -f "$ENV_FILE" ] || log_warn "no .env file — checking the values that ARE set (state overlays, environment). 'make env-init' creates one."
  load_env
  # HARBOR_URL + KUBECONFIG are checked explicitly below (sentinel / file-existence), not in this
  # generic placeholder loop — so they are intentionally absent here.
  local missing=() required=(HARBOR_USERNAME HARBOR_PASSWORD GITEA_ADMIN_PASSWORD)
  # method-specific requirements
  case "${VKS_AUTH_METHOD:-kubeconfig}" in
    # VKS_USERNAME and VKS_NAMESPACE are NOT required on the `vcf` path: 30-vks-login.sh defaults the
    # first (announced) and DISCOVERS the second from `vcf context list` after the context exists.
    # Requiring them here would do worse than nag — the operator's obvious remedy (set VKS_NAMESPACE)
    # takes the `if [ -z … ]` branch and permanently disables discovery for anyone who follows the
    # runbook. They stay required on the `vsphere` path, which has neither mechanism.
    vcf)     required+=(SUPERVISOR_HOST VKS_CONTEXT_NAME) ;;
    vsphere) required+=(SUPERVISOR_HOST VKS_USERNAME VKS_NAMESPACE VKS_CLUSTER_NAME VKS_PASSWORD) ;;
  esac
  local k v
  for k in "${required[@]}"; do
    v="$(eval "printf '%s' \"\${$k:-}\"")"
    is_placeholder "$v" && missing+=("$k")
  done
  # HARBOR_URL: commented in .env.example (B13) so unset by default; and an operator may still type the
  # `harbor.vks.local` sentinel, which is_placeholder catches (env_validate uses the same helper).
  harbor_url_is_placeholder "${HARBOR_URL:-}" && missing+=("HARBOR_URL (unset or still the harbor.vks.local placeholder — set your real Harbor host; the KinD path fills it via .env.state)")
  # KUBECONFIG: load_env DEFAULTS it to secrets/vks.kubeconfig, so "set" != "the file exists". env-check
  # is deliberately the STRICTER PRESENCE gate — the kubeconfig FILE must be here. env-validate is the
  # REACHABILITY gate; it assumes presence and only WARNs when the file is absent, so it can be run
  # standalone before you have fetched the workload kubeconfig.
  # ...but ONLY when the operator is the one supplying it. With VKS_AUTH_METHOD=vcf it is
  # `make vks-login` that FETCHES the kubeconfig, and install-all runs `preflight` BEFORE
  # `vks-login` — so requiring the file unconditionally would FALSE-BLOCK the vcf flow on a
  # first run, before the step that creates the thing being demanded. Gate it on the method.
  if [ "${VKS_AUTH_METHOD:-kubeconfig}" = kubeconfig ]; then
    # -f, not -e/-s: a DIRECTORY at this path satisfies -e and -s but is not a kubeconfig, and
    # kubectl then fails with `error loading config file ...: is a directory` far downstream.
    case "${KUBECONFIG:-}" in
      # kubectl accepts a colon-separated LIST of files; treat that as the operator's business
      # rather than reporting a legitimate multi-file config as "not found".
      *:*) : ;;
      *) [ -s "${KUBECONFIG:-/nonexistent}" ] || missing+=("KUBECONFIG (file missing or EMPTY: '${KUBECONFIG:-}' — fetch the workload kubeconfig first; a cluster you just created writes ./secrets/\${VKS_CLUSTER_NAME}.kubeconfig)") ;;
    esac
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    # The remedy must be runnable FROM THE STATE THAT PRODUCED THIS ERROR. With no .env,
  # `make env-populate` itself FATALs ("no .env yet") -- measured -- so telling the reader to run
  # it bounces them through a dead command. env-init has to come first, and this block is what a
  # reader scrolls to; the WARN six lines up is not where they look.
  local _env_remedy="Set them in .env (run 'make env-populate' to mint the ones we can), then re-check."
  [ -f "$ENV_FILE" ] || _env_remedy="No .env exists yet: run 'make env-init', then 'make env-populate' to mint the ones we can, then re-check."
  log_error "env-check: ${#missing[@]} required value(s) missing/placeholder:"
    printf '  - %s\n' "${missing[@]}"
    echo "${_env_remedy}"
    exit 1
  fi
  log_info "env-check: all required values present (auth method: ${VKS_AUTH_METHOD:-kubeconfig})"
}

# ---------------------------------------------------------------------------
# validate — format + connectivity/auth (fail fast; secrets never on argv)
# ---------------------------------------------------------------------------
# Complexity check mirrors gen_password's guarantee: >=8 chars, upper+lower+digit.
pw_weak() {
  local p="$1"
  [ "${#p}" -ge 8 ] || return 0
  printf '%s' "$p" | grep -q '[A-Z]' || return 0
  printf '%s' "$p" | grep -q '[a-z]' || return 0
  printf '%s' "$p" | grep -q '[0-9]' || return 0
  return 1
}

env_validate() {
  [ -f "$ENV_FILE" ] || die "no .env yet — run 'make env-init' first"
  load_env
  local errs=0

  # --- format ---------------------------------------------------------------
  # Empty is a WARN-skip, not an error: HARBOR_URL is commented in .env.example (B13), so it is unset
  # until discovery/the operator sets it. env-check ENFORCES its presence; env-validate is the
  # REACHABILITY gate and is standalone-runnable on a partial .env — same warn-skip as KUBECONFIG below
  # and the Harbor-reachability block (an empty value hard-erroring here contradicted that WARN).
  case "${HARBOR_URL:-}" in
    '')        log_warn  "HARBOR_URL not set yet — skipping format+reachability (env-check enforces presence; set it after Harbor install)" ;;
    *://*)     log_error "HARBOR_URL must be a host or host:port with NO scheme (got '$HARBOR_URL')"; errs=$((errs+1)) ;;
    *)         log_info  "HARBOR_URL format ok ($HARBOR_URL)" ;;
  esac
  if pw_weak "${HARBOR_PASSWORD:-}";        then log_error "HARBOR_PASSWORD is weak/unset (need >=8 with upper+lower+digit)"; errs=$((errs+1)); fi
  if pw_weak "${GITEA_ADMIN_PASSWORD:-}";   then log_error "GITEA_ADMIN_PASSWORD is weak/unset (need >=8 with upper+lower+digit)"; errs=$((errs+1)); fi

  # --- KUBECONFIG connectivity (only if the file is configured & present) ---
  # ⚠️ CAPTURE stderr to its OWN FILE — do NOT `2>&1` and do NOT `2>/dev/null`.
  #   * `2>/dev/null` is what this block used to do, and it threw away the ONLY evidence that
  #     distinguishes a REBUILT lab from a down one. Every failure read "unreachable" — the wrong
  #     cause, with no remedy — for the case docs/scenario-1.md §9 promises we separate.
  #   * merging with `2>&1` makes the capture non-empty even on success and inverts emptiness tests
  #     downstream; 30-vks-login.sh:415 records that this repo has measured that turning a WARN into
  #     a BLOCK asserting the opposite.
  # The classifier + these arms mirror 30-vks-login.sh:417-448 deliberately: same evidence, same
  # vocabulary, so an operator who has seen one recognises the other.
  if [ -n "${KUBECONFIG:-}" ] && [ -s "${KUBECONFIG}" ]; then
    local _kerr; _kerr="$(mktemp)"
    # ⚠️ A FOURTH STATE, AND IT MISFIRED IN THE FIRST VERSION OF THIS BLOCK. With no current-context
    # set, `kubectl cluster-info` does NOT fail against the configured cluster — it falls back to
    # http://localhost:8080 and reports "connection refused", which classifies UNREACHABLE and made
    # this arm ask "Is the lab up, and is it routable from this jump box?". The endpoint that never
    # answered was LOCALHOST; the lab was irrelevant and the real fault was an unset context.
    # `config view --minify` also returns rc 1 + EMPTY here ("current-context must exist in order to
    # minify"), so the server line would have been blank too. Check it BEFORE probing anything.
    if ! kubectl config current-context >/dev/null 2>&1; then
      log_error "KUBECONFIG='$KUBECONFIG' exists and parses, but has NO CURRENT CONTEXT set.
  Nothing was probed: with no context, kubectl silently targets http://localhost:8080, so any
  reachability verdict here would describe your own machine rather than the lab.
    contexts in that file: $(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ' || true)
  Select one, or re-export the kubeconfig:
    kubectl config use-context <one of the above>
    make vks-login"; errs=$((errs+1))
    elif kubectl cluster-info >/dev/null 2>"$_kerr"; then
      log_info "KUBECONFIG reachable ($(kubectl config current-context 2>/dev/null || echo '?'))"
    else
      local _kctx _ksrv
      _kctx="$(kubectl config current-context 2>/dev/null || echo '<none>')"
      # ⚠️ `--minify` IS LOAD-BEARING. Without it `.clusters[0]` is the FIRST cluster in the FILE,
      # not the one the current context uses — and a real VKS kubeconfig always holds several
      # (Supervisor + guest). MEASURED on this lab: context `lab-gc1` resolves to
      # https://192.168.101.132:6443, while `.clusters[0]` reports the SUPERVISOR at
      # https://192.168.101.128:443. An error that names the wrong server is worse than one that
      # names none — it sends the operator to debug a healthy endpoint.
      _ksrv="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
      case "$(classify_kube_failure "$_kerr")" in
        STALE_CA)
          log_error "the CA embedded in KUBECONFIG='$KUBECONFIG' does not match what ${_ksrv:-that server} presents.
  The server ANSWERED, so this is NOT a network or auth problem. A REBUILT cluster mints a new CA and
  the ADDRESS usually stays the same, so a dead kubeconfig looks correctly configured.
    context: ${_kctx}
    server:  ${_ksrv:-<unknown>}
  Re-export it from the cluster that is actually running:  make vks-login"; errs=$((errs+1)) ;;
        UNAUTHORIZED)
          log_error "${_ksrv:-the cluster} rejected this kubeconfig's credentials (they expired, or the account changed).
  This is NOT a stale CA — the TLS chain verified. Re-authenticate:  make vks-login"; errs=$((errs+1)) ;;
        FORBIDDEN)
          log_error "authenticated to ${_ksrv:-the cluster}, but this identity may not read it.
  That is an RBAC GRANT, not a broken kubeconfig — do NOT re-fetch it. Ask your platform team for
  cluster-admin on '${_kctx}' (we create namespaces and install CRDs)."; errs=$((errs+1)) ;;
        PLAINTEXT)
          log_error "${_ksrv:-the server} is not speaking TLS on that port — every CA remedy is wrong here.
  Check the scheme/port in KUBECONFIG='$KUBECONFIG'."; errs=$((errs+1)) ;;
        UNREACHABLE)
          log_error "could not reach ${_ksrv:-the cluster} (KUBECONFIG='$KUBECONFIG').
  This is NOT evidence the kubeconfig is stale — the endpoint never answered. Is the lab up, and is
  it routable from this jump box? Retry before re-fetching anything."; errs=$((errs+1)) ;;
        KUBECONFIG_UNUSABLE)
          # ⚠️ WORDED FOR THIS SITE. The two shapes you might expect CANNOT reach here: the guard
          # above already proved $KUBECONFIG exists, and a MALFORMED file is caught earlier by the
          # current-context check. What is left is a file the kubeconfig POINTS AT — its CA, a
          # client cert/key, or an exec credential-plugin binary.
          log_error "a file your kubeconfig POINTS AT is missing or unreadable, so NOTHING WAS DIALLED —
  this says nothing about whether ${_ksrv:-the cluster} is up. KUBECONFIG='$KUBECONFIG' itself exists.
  kubectl names the file:"
          sed 's/^/    /' "$_kerr" >&2; errs=$((errs+1)) ;;
        NO_KUBE_TARGET)
          log_error "kubectl had NO TARGET — it fell back to localhost:8080, which is never your lab.
  Either KUBECONFIG names a file that does not exist, or that file sets no current-context.
    KUBECONFIG='$KUBECONFIG'
  Fix the path or select a context; nothing was dialled at ${_ksrv:-the cluster}."; errs=$((errs+1)) ;;
        *)
          # Do NOT guess. Print kubectl's own words — they beat any advice we could invent.
          log_error "KUBECONFIG='$KUBECONFIG' did not work, and the error is one we do not classify:"
          sed 's/^/    /' "$_kerr" >&2; errs=$((errs+1)) ;;
      esac
    fi
    rm -f "$_kerr"
  else
    log_warn "KUBECONFIG not present yet (${KUBECONFIG:-unset}) — skipping cluster reachability (set it after you get the workload kubeconfig)"
  fi

  # --- Harbor reachability + auth (secret via umask-077 curl -K, never argv) -
  if harbor_url_is_placeholder "${HARBOR_URL:-}"; then
    log_warn "HARBOR_URL is unset or the placeholder — skipping Harbor reachability (real value comes from discovery/.env.state or your .env)"
  else
      # Single-sourced with the productized probe: lib/harbor.sh's harbor_scheme. The two used to
      # derive this independently, and the OTHER one hardcoded https — which made harbor_auth_verdict
      # permanently `unchecked` in the insecure leg. One rule, one place.
      local scheme; scheme="$(harbor_scheme)"
      local cafg=(); [ "$scheme" = https ] && [ -n "${HARBOR_CA_FILE:-}" ] && [ -s "${HARBOR_CA_FILE}" ] && cafg=(--cacert "${HARBOR_CA_FILE}")
      # NO -k fallback: over https with no CA file, use curl's DEFAULT system trust (correct for a
      # publicly-trusted Harbor). A self-signed Harbor with no HARBOR_CA_FILE then FAILS honestly on
      # TLS (curl exit 60) instead of a silent skip-verify that proved nothing about the trust anchor.
      # `local` MUST be on its own line: `local x=$(...)` makes the exit status local's (always 0),
      # masking curl's real exit — the classic local-masks-substitution trap.
      local code rc=0
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${CURL_MAX_TIME_SECONDS:-10}" "${cafg[@]}" "$scheme://$HARBOR_URL/api/v2.0/systeminfo" 2>/dev/null)" || rc=$?
      if [ "$code" = 200 ]; then
        log_info "Harbor reachable ($scheme://$HARBOR_URL)"
        # auth probe: password goes into a 0600 curl config file, NOT argv
        if ! is_placeholder "${HARBOR_PASSWORD:-}"; then
          # esc_curlk (lib/os.sh): a bare `"` in the password truncates it, a `\` is eaten, a
          # newline injects a curl directive. Without it this probe reports a FALSE 401 on a
          # perfectly good password — the exact wrong answer for a gate whose job is to tell the
          # operator whether their credentials work.
          local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
          printf 'user = "%s:%s"\n' "$(esc_curlk "${HARBOR_USERNAME:-admin}")" "$(esc_curlk "${HARBOR_PASSWORD}")" > "$cfg"
          local acode
          acode="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "${CURL_MAX_TIME_SECONDS:-10}" "${cafg[@]}" -K "$cfg" "$scheme://$HARBOR_URL/api/v2.0/users/current" 2>/dev/null || echo 000)"
          rm -f "$cfg"
          case "$acode" in
            200|403) log_info "Harbor credentials accepted (HTTP $acode)" ;;   # 403 = robot lacks /users/current but auth passed
            401)     log_error "Harbor rejected HARBOR_USERNAME/HARBOR_PASSWORD (HTTP 401)"
                     # Until 2026-08-22 this arm named NO remedy, so env-validate told the operator they
                     # were broken and stopped there. It is the DIAGNOSE half of the pair. (B209)
                     harbor_settle_note "         "
                     errs=$((errs+1)) ;;
            *)       log_warn "Harbor auth probe inconclusive (HTTP $acode) — verify at mirror time" ;;
          esac
        fi
      # ⚠️ 77 IS REQUIRED, and without it the arms below are DEAD CODE. MEASURED against a healthy
      # TLS oracle: curl handed an EMPTY (or unparseable) --cacert returns **77**
      # (CURLE_SSL_CACERT_BADFILE), not 60. 77 was absent from this set, so the whole block was
      # skipped and execution fell through to the outer else — reporting "Harbor unreachable
      # (HTTP 000, curl exit 77)" for a purely LOCAL anchor problem, against a Harbor that was
      # answering. An anchor fault reported as a reachability fault is the exact class this
      # function exists to delete, committed by the function itself.
      elif [ "$scheme" = https ] && { [ "$rc" = 60 ] || [ "$rc" = 35 ] || [ "$rc" = 51 ] || [ "$rc" = 77 ] || [ "$rc" = 83 ]; }; then
        # ⚠️ THIS USED TO CONFLATE THREE CAUSES AND NAME ONLY ONE OF THEM. The message was "set
        # HARBOR_CA_FILE for a self-signed Harbor, or the cert is not publicly trusted" — which is right
        # when the variable is UNSET, and actively misleading in the case that actually happens most: the
        # variable IS set, to a CA from a lab that no longer exists. MEASURED elsewhere in this repo
        # (30-vks-login.sh:115-120) for the Supervisor's VMCA — after a rebuild the stored anchor was the
        # DESTROYED lab's, and every consumer failed with `x509: certificate signed by unknown authority`,
        # a message naming TLS, so the operator hunts a certificate or network fault while the real cause
        # is a rebuild. That script already distinguishes the cases with ca_verifies_endpoint; this one
        # did not, so the SAME rebuild produced a good diagnosis for the Supervisor and a wrong one for
        # Harbor. An error that names the wrong cause sends the operator to fix something that is not broken.
        local _ca_verdict _h _p          # these three leaked to GLOBAL scope until 2026-08-08
        _ca_verdict=0
        if [ -n "${HARBOR_CA_FILE:-}" ] && [ -s "${HARBOR_CA_FILE}" ]; then
          # ⚠️ Strip an IPv6 bracket form BEFORE splitting on ':', or `%%:*` cuts "[fd00" out of
          # "[fd00::1]:443" and ca_verifies_endpoint returns 2 ("could not reach") — a wrong cause
          # for a perfectly good anchor.
          _h="${HARBOR_URL%%/*}"
          case "$_h" in
            \[*\]:*) _p="${_h##*]:}"; _h="${_h%%]*}"; _h="${_h#\[}" ;;
            \[*\])   _p=443;          _h="${_h%%]*}"; _h="${_h#\[}" ;;
            *)       _p="${_h##*:}"; [ "$_p" = "$_h" ] && _p=443;  _h="${_h%%:*}" ;;
          esac
          ca_verifies_endpoint "$_h" "$_p" "$HARBOR_CA_FILE" >/dev/null 2>&1 || _ca_verdict=$?
        else
          _ca_verdict=9   # not set at all — the original message IS the right one
        fi
        case "$_ca_verdict" in
          # 0 = the anchor VERIFIES this endpoint (chain AND name), yet curl still failed. Until
          # 2026-08-08 this fell through to `*)`, which told the operator to "set HARBOR_CA_FILE" —
          # advice for an UNSET variable, printed to someone whose variable is set and CORRECT.
          #
          # ⚠️ NO RED WAS CONSTRUCTED FOR THIS ARM, and that is recorded deliberately so nobody
          # "fixes" it by widening the elif set above. MEASURED against a local TLS oracle: a DEAD
          # proxy yields curl rc 7, which is NOT in {60,35,51,77,83} and so never reaches this block
          # at all. The two mechanisms that DO reach it are a TLS-INTERCEPTING proxy (curl honours
          # https_proxy and sees the interceptor's cert -> 60, while ca_verifies_endpoint's
          # openssl s_client ignores the proxy and reaches the origin -> 0) and a certificate
          # rotated between the two sequential probes.
          0) log_error "HARBOR_CA_FILE='${HARBOR_CA_FILE}' VERIFIES ${_h}:${_p} correctly — chain and name both.
  So this is NOT a certificate problem: do NOT re-fetch the CA and do NOT set HARBOR_CA_FILE.
  curl failed (exit $rc) where a direct TLS check succeeded. Two things do that:
    - a TLS-INTERCEPTING proxy — curl honours https_proxy/HTTPS_PROXY, the direct check does not.
      Check:  env | grep -i _proxy      (and whether ${_h} belongs in NO_PROXY)
    - the certificate was rotated between the two probes — simply retry."; errs=$((errs+1)) ;;
          1) log_error "the CA at ${HARBOR_CA_FILE} does NOT verify the certificate ${HARBOR_URL} presents.
  The endpoint ANSWERED, so this is not a reachability problem — the anchor is for a DIFFERENT (usually a
  destroyed and rebuilt) Harbor. A rebuild mints a new CA, and nothing in this repo re-fetches it for you.
    your anchor is:            $(openssl x509 -in "$HARBOR_CA_FILE" -noout -subject 2>/dev/null | sed 's/^subject=//')
    the endpoint's cert issuer: $(printf '' | timeout 15 openssl s_client -connect "${_h}:${_p}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  Re-fetch it from the lab that is actually running:  make fetch-harbor-ca
  (⚠️ SUBJECT vs ISSUER on purpose — comparing a stored CA's fingerprint to a live LEAF's is the mistake
   30-vks-login.sh records; they are different objects and can never match even when the anchor is right.)"
             errs=$((errs+1)) ;;
          2) log_error "could not reach ${_h}:${_p} to check HARBOR_CA_FILE — this is NOT evidence the anchor is wrong.
  Harbor is unreachable or still starting; retry before touching the certificate."; errs=$((errs+1)) ;;
          # 3 = right anchor, wrong NAME. Opposite remedy to staleness, so it must not share that arm —
          # `make fetch-harbor-ca` cannot fix a SAN mismatch and would send the operator in a circle.
          3) log_error "the CA at ${HARBOR_CA_FILE} is the RIGHT anchor, but Harbor's certificate is NOT
  VALID FOR '${_h}'. Do NOT re-fetch the CA — it is correct.
    the cert names: $(printf '' | timeout 15 openssl s_client -connect "${_h}:${_p}" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')
  Address Harbor by a name the certificate carries (HARBOR_URL), or reissue the cert with a SAN for
  the address you use. A self-signed Harbor minted for an IP will not validate by FQDN, and vice versa."
             errs=$((errs+1)) ;;
          # 4 = the endpoint served NO CERTIFICATE. Its own arm because every CA remedy is wrong:
          # there is nothing for an anchor to verify. MEASURED — this used to return 0, so a
          # plaintext endpoint read as "the CA verifies it".
          4) log_error "${_h}:${_p} answered but served NO TLS CERTIFICATE — it is not speaking TLS.
  Do NOT re-fetch the CA; there is nothing for it to verify. Check HARBOR_URL: this is usually a
  plain-HTTP endpoint or the wrong port. If this Harbor is deliberately HTTP, it must not be
  addressed as https."; errs=$((errs+1)) ;;
          # 5 = HARBOR_CA_FILE exists but is EMPTY (the `-f` guard above passed, `-s` did not).
          # Distinct from 9 (not configured at all) and from 1 (configured and wrong).
          5) log_error "HARBOR_CA_FILE='${HARBOR_CA_FILE}' exists but is EMPTY, so nothing can be
  verified. This is NOT a stale anchor — re-fetch it:  make fetch-harbor-ca"; errs=$((errs+1)) ;;
          *) log_error "Harbor TLS not trusted at $scheme://$HARBOR_URL (curl exit $rc) — set HARBOR_CA_FILE for a self-signed Harbor, or the cert is not publicly trusted"; errs=$((errs+1)) ;;
        esac
      else
        log_error "Harbor unreachable at $scheme://$HARBOR_URL/api/v2.0/systeminfo (HTTP $code, curl exit $rc)"; errs=$((errs+1))
      fi
  fi

  if [ "$errs" -gt 0 ]; then log_error "env-validate: $errs problem(s) — fix them before running the pipeline"; exit 1; fi
  log_info "env-validate: format + reachable connectivity checks passed"
}

case "${1:-}" in
  init)     env_init ;;
  populate) env_populate ;;
  check)    env_check ;;
  validate) env_validate ;;
  *) die "usage: 02-env.sh {init|populate|check|validate}" ;;
esac
