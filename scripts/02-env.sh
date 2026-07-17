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

ENV_FILE="${REPO_ROOT}/.env"
EXAMPLE_FILE="${REPO_ROOT}/.env.example"

# A value is "unset" for our purposes if empty OR still a committed placeholder.
is_placeholder() { case "$1" in ''|'<SET-IN-.env>'|*'<SET-'*) return 0 ;; *) return 1 ;; esac; }

# HARBOR_URL's committed .env.example default is a real-looking hostname that MEANS "not configured
# yet" (the real value is the discovered LB IP for KinD, or your lab's Harbor FQDN). is_placeholder
# cannot catch it — it is neither empty nor a <SET-*> token — so env_check AND env_validate test it
# via this helper. The sentinel literal lives ONCE, inside this function body: a function def is
# immune to load_env's `set -a; . .env` (a top-level var would be clobbered by it).
harbor_url_is_placeholder() { case "${1:-}" in ''|harbor.vks.local) return 0 ;; *) return 1 ;; esac; }

# Upsert KEY=VALUE into .env (idempotent — replaces an existing line, else appends).
env_set() { set_env_var "$1" "$2" "$ENV_FILE"; }

# ---------------------------------------------------------------------------
# init — fresh .env from the committed source of truth (old one saved to .env.bak)
# ---------------------------------------------------------------------------
env_init() {
  [ -f "$EXAMPLE_FILE" ] || die ".env.example missing at $EXAMPLE_FILE (the committed source of truth)"
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    log_warn "existing .env backed up to .env.bak (your previous overrides are preserved there)"
  fi
  cp "$EXAMPLE_FILE" "$ENV_FILE"
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
  load_env   # so we can see which values are already set (and honor .env.kind)

  echo "== GENERATE (secrets for the components we install — minted only if unset) =="
  # Gitea is ALWAYS ours → always safe to generate.
  local g_admin g_ci h_pw a_pw made=0
  if is_placeholder "${GITEA_ADMIN_PASSWORD:-}"; then g_admin="$(gen_password)"; env_set GITEA_ADMIN_PASSWORD "$g_admin"; echo "  + GITEA_ADMIN_PASSWORD  (generated)"; made=1; fi
  if is_placeholder "${GITEA_CI_PASSWORD:-}";    then g_ci="$(gen_password)";    env_set GITEA_CI_PASSWORD    "$g_ci";    echo "  + GITEA_CI_PASSWORD     (generated)"; made=1; fi
  # Harbor/ArgoCD passwords: a throwaway default that works out-of-the-box for the local
  # KinD stand-in / a self-hosted Harbor. On a REAL lab these are given to you — OVERRIDE
  # HARBOR_PASSWORD with the admin/robot secret (env-populate never clobbers a value you set).
  if is_placeholder "${HARBOR_PASSWORD:-}";        then h_pw="$(gen_password)"; env_set HARBOR_PASSWORD        "$h_pw"; echo "  + HARBOR_PASSWORD       (generated — OVERRIDE for a real lab)"; made=1; fi
  if is_placeholder "${ARGOCD_ADMIN_PASSWORD:-}";  then a_pw="$(gen_password)"; env_set ARGOCD_ADMIN_PASSWORD  "$a_pw"; echo "  + ARGOCD_ADMIN_PASSWORD (generated — KinD only; real lab sets its own)"; made=1; fi
  [ "$made" = 1 ] || echo "  (all already set — nothing generated)"

  echo
  echo "== DISCOVER (values only knowable after install — read from a reachable cluster) =="
  if have kubectl && [ -f "${KUBECONFIG:-/nonexistent}" ] && kubectl cluster-info >/dev/null 2>&1; then
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
  else
    echo "  (no reachable cluster — skipping. The KinD flow auto-writes these to .env.state;"
    echo "   on a real lab discover them after install:)"
    echo "     HARBOR_URL:    kubectl -n <harbor-ns>  get svc -o jsonpath='{...loadBalancer.ingress[0].ip}'"
    echo "     ARGOCD_SERVER: kubectl -n <argocd-ns>  get svc argocd-server -o jsonpath='{...loadBalancer.ingress[0].ip}'"
    echo "     KUBECONFIG:    vcf cluster kubeconfig get <cluster> --export-file ./secrets/vks.kubeconfig"
  fi

  echo
  echo "== user-PROVIDE (only YOU know — set these in .env by hand) =="
  echo "  Real VKS lab (skip for the local KinD flow):"
  echo "    SUPERVISOR_HOST      vCenter → Workload Management → Supervisors → Control Plane IP"
  echo "    VKS_NAMESPACE        the vSphere Namespace name"
  echo "    VKS_USERNAME         your vSphere SSO admin (e.g. administrator@vsphere.local)"
  echo "    VKS_CLUSTER_NAME     the VKS workload cluster name"
  echo "    HARBOR_PASSWORD      OVERRIDE the generated value with the lab's admin/robot secret"
  echo "    VCF_CLI_SRC_DIR      folder holding the licensed VCF/argocd-vcf CLI archives (make install-vcf-clis)"
  echo
  log_info "populate done — run 'make env-check' then 'make env-validate'"
}

# ---------------------------------------------------------------------------
# check — presence only (fast, no network)
# ---------------------------------------------------------------------------
env_check() {
  [ -f "$ENV_FILE" ] || die "no .env yet — run 'make env-init' first"
  load_env
  # HARBOR_URL + KUBECONFIG are checked explicitly below (sentinel / file-existence), not in this
  # generic placeholder loop — so they are intentionally absent here.
  local missing=() required=(HARBOR_USERNAME HARBOR_PASSWORD GITEA_ADMIN_PASSWORD)
  # method-specific requirements
  case "${VKS_AUTH_METHOD:-kubeconfig}" in
    vcf)     required+=(SUPERVISOR_HOST VKS_USERNAME VKS_NAMESPACE VKS_CONTEXT_NAME) ;;
    vsphere) required+=(SUPERVISOR_HOST VKS_USERNAME VKS_NAMESPACE VKS_CLUSTER_NAME VKS_PASSWORD) ;;
  esac
  local k v
  for k in "${required[@]}"; do
    v="$(eval "printf '%s' \"\${$k:-}\"")"
    is_placeholder "$v" && missing+=("$k")
  done
  # HARBOR_URL: the committed default 'harbor.vks.local' is a real-looking sentinel is_placeholder
  # cannot catch (env_validate special-cases it via the same helper) — so check it explicitly.
  harbor_url_is_placeholder "${HARBOR_URL:-}" && missing+=("HARBOR_URL (unset or still the committed placeholder — set your real Harbor host; the KinD path fills it via .env.kind)")
  # KUBECONFIG: load_env DEFAULTS it to secrets/vks.kubeconfig, so "set" != "the file exists". env-check
  # is deliberately the STRICTER PRESENCE gate — the kubeconfig FILE must be here. env-validate is the
  # REACHABILITY gate; it assumes presence and only WARNs when the file is absent, so it can be run
  # standalone before you have fetched the workload kubeconfig.
  [ -f "${KUBECONFIG:-/nonexistent}" ] || missing+=("KUBECONFIG (file not found: '${KUBECONFIG:-}' — fetch the workload kubeconfig first)")
  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "env-check: ${#missing[@]} required value(s) missing/placeholder:"
    printf '  - %s\n' "${missing[@]}"
    echo "Set them in .env (run 'make env-populate' to mint the ones we can), then re-check."
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
  case "${HARBOR_URL:-}" in
    '')        log_error "HARBOR_URL is empty"; errs=$((errs+1)) ;;
    *://*)     log_error "HARBOR_URL must be a host or host:port with NO scheme (got '$HARBOR_URL')"; errs=$((errs+1)) ;;
    *)         log_info  "HARBOR_URL format ok ($HARBOR_URL)" ;;
  esac
  if pw_weak "${HARBOR_PASSWORD:-}";        then log_error "HARBOR_PASSWORD is weak/unset (need >=8 with upper+lower+digit)"; errs=$((errs+1)); fi
  if pw_weak "${GITEA_ADMIN_PASSWORD:-}";   then log_error "GITEA_ADMIN_PASSWORD is weak/unset (need >=8 with upper+lower+digit)"; errs=$((errs+1)); fi

  # --- KUBECONFIG connectivity (only if the file is configured & present) ---
  if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
    if kubectl cluster-info >/dev/null 2>&1; then
      log_info "KUBECONFIG reachable ($(kubectl config current-context 2>/dev/null || echo '?'))"
    else
      log_error "KUBECONFIG=$KUBECONFIG exists but the cluster is unreachable"; errs=$((errs+1))
    fi
  else
    log_warn "KUBECONFIG not present yet (${KUBECONFIG:-unset}) — skipping cluster reachability (set it after you get the workload kubeconfig)"
  fi

  # --- Harbor reachability + auth (secret via umask-077 curl -K, never argv) -
  if harbor_url_is_placeholder "${HARBOR_URL:-}"; then
    log_warn "HARBOR_URL is the placeholder default — skipping Harbor reachability (real value comes from discovery/.env.kind)"
  else
      local scheme=https; [ "${HARBOR_INSECURE:-0}" = 1 ] && scheme=http
      local cafg=(); [ "$scheme" = https ] && [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "${HARBOR_CA_FILE}" ] && cafg=(--cacert "${HARBOR_CA_FILE}")
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
            401)     log_error "Harbor rejected HARBOR_USERNAME/HARBOR_PASSWORD (HTTP 401)"; errs=$((errs+1)) ;;
            *)       log_warn "Harbor auth probe inconclusive (HTTP $acode) — verify at mirror time" ;;
          esac
        fi
      elif [ "$scheme" = https ] && { [ "$rc" = 60 ] || [ "$rc" = 35 ] || [ "$rc" = 51 ] || [ "$rc" = 83 ]; }; then
        log_error "Harbor TLS not trusted at $scheme://$HARBOR_URL (curl exit $rc) — set HARBOR_CA_FILE for a self-signed Harbor, or the cert is not publicly trusted"; errs=$((errs+1))
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
