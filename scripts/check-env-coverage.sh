#!/usr/bin/env bash
# check-env-coverage.sh — every operator-settable variable the scripts READ must be documented in
# .env.example. A gate, not a convention.
#
# WHY: `.env.example` is this repo's BLOCKING source of truth for every operator-tunable value —
# and it silently drifted anyway. 5 of the 8 variables `71-argocd-register-guest.sh` reads
# (ARGOCD_KUBECONFIG, GUEST_KUBECONFIG, GUEST_API_SERVER, ARGOCD_DEST_CLUSTER_NAME,
# ARGOCD_REGISTER_INSECURE, ...) were entirely undocumented, so the cross-cluster ArgoCD path was
# IMPOSSIBLE to configure from the docs — you had to read the script. Nothing caught it, because
# "keep .env.example complete" was a rule and not a check.
#
# WHAT COUNTS as operator-settable: a variable read with a default — `${VAR:-...}` or `: "${VAR:=...}"`
# — or asserted as required (`: "${VAR:?}"`). Those are INPUTS. Internal locals and values the repo
# DISCOVERS and publishes itself (set_env_var -> .env.kind) are not, and are listed below explicitly
# so the exemption is auditable rather than accidental.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

ENV_FILE="${REPO_ROOT}/.env.example"
[ -f "$ENV_FILE" ] || die "no .env.example"

# Values the repo DISCOVERS/GENERATES and writes to .env.kind itself — an operator never sets them.
# (They are still described in .env.example prose; they just need no `VAR=` line.)
PUBLISHED='HARBOR_URL|HARBOR_PASSWORD|HARBOR_CA_FILE|HARBOR_INSECURE|GITEA_ADMIN_PASSWORD|GITEA_CI_PASSWORD|GITEA_CI_TOKEN|ARGOCD_LB_IP|ARGOCD_INSECURE|ARGOCD_DEST_SERVER|INGRESS_LB_IP|INGRESS_CONTROLLER|KUBECONFIG|VKS_AUTH_METHOD|VKS_CONTEXT|ISTIO_GATEWAY_REF|ISTIO_DISCOVERED_VERSION|WEBHOOK_TOKEN'
# Shell/library internals and CI-only knobs — never operator-facing.
INTERNAL='REPO_ROOT|SCRIPT_DIR|BASH_SOURCE|PATH|HOME|PWD|IFS|SSL_CERT_FILE|TMPDIR|LC_ALL|HARBOR_PW|HARBOR_SVC|HARBOR_TMP|HARBOR_CURL_CFG|HARBOR_RELEASE|HARBOR_TLS_SECRET|HARBOR_TLS_VERIFY|HARBOR_INSECURE_BOOL|HARBOR_PROVISIONAL_EXTERNAL_URL|HARBOR_ROBOT_OUT|ARGOCD_SVC|ARGOCD_NS|ARGOCD_MANAGER_NS|ARGOCD_MANIFEST_VERSION|ISTIO_ROUTE_API_EFFECTIVE|PLATFORM_ISTIO_NAMESPACE|PLATFORM_ISTIO_RELEASE|PLATFORM_ISTIOD_NAMESPACE|PROBE_IMAGE|REGISTRY_LOCK_FILE|JUMPBOX_[A-Z_]*|E2E_[A-Z_]*|CI|GITHUB_[A-Z_]*|READY_TIMEOUT_SECONDS|POLL_INTERVAL_SECONDS|CURL_MAX_TIME_SECONDS|MIRROR_RETRIES|MIRROR_FORCE_PULL|NOTIFY|CONTAINER_ENGINE|VCF_[A-Z_]*|PSA_LEVEL_[A-Z_]*|DISPLAY|WAYLAND_DISPLAY|DRY_RUN|GW_IP|TOKEN|RED_TEST_SKIP_PRECHECK'

# SCOPE: the OPERATOR FLOW only — the numbered install/operate scripts (00..8x) plus the shared
# libs. Test fixtures and harnesses (90-e2e-*, e2e-*, test-*, jumpbox-*, bootstrap-*, check-*) have
# their own knobs that an operator never sets, and folding them in would bury the real gaps in noise.
FLOW_SCRIPTS=()
for f in "${REPO_ROOT}"/scripts/[0-8][0-9]-*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    90-*|e2e-*|test-*|jumpbox-*|bootstrap-*|check-*) continue ;;
  esac
  FLOW_SCRIPTS+=("$f")
done

vars="$(grep -rhoE '\$\{[A-Z][A-Z0-9_]{2,}:[-?=]|: *"\$\{[A-Z][A-Z0-9_]{2,}:[?=]' \
          "${FLOW_SCRIPTS[@]}" 2>/dev/null \
        | grep -oE '[A-Z][A-Z0-9_]{2,}' | sort -u)"

rc=0; missing=""
for v in $vars; do
  printf '%s' "$v" | grep -qE "^(${PUBLISHED})$" && continue
  printf '%s' "$v" | grep -qE "^(${INTERNAL})$" && continue
  # Documented = a `VAR=` line, commented or not.
  grep -qE "^#?[[:space:]]*${v}=" "$ENV_FILE" && continue
  log_error "operator-settable '${v}' is READ by the scripts but is NOT in .env.example"
  log_error "    read in: $(grep -rlE "\\\$\{${v}[:}]" "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  missing="${missing} ${v}"; rc=1
done

echo >&2
if [ "$rc" -eq 0 ]; then
  log_info "check-env-coverage: OK — every operator-settable variable the scripts read is documented in .env.example."
else
  log_error "check-env-coverage: .env.example is INCOMPLETE —${missing}"
  log_error "  .env.example is the committed source of truth: a variable only the script knows about"
  log_error "  cannot be configured by an operator. Document it (with when-you-need-it + how-to-get-it),"
  log_error "  or — if it is internal/discovered — add it to the explicit exemption list in this script."
fi
exit "$rc"
