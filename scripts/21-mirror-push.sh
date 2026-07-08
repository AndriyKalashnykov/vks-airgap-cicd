#!/usr/bin/env bash
# 21-mirror-push.sh — push every cached image into Harbor.
# Runs on the dual-homed jump box (after 10) or the air-gapped host (after 20).
#
# Ensures the Harbor projects exist, logs in via stdin (no secret in argv), then
# skopeo-copies each cached OCI image to its Harbor destination (identical mapping
# to the pull side via lib/mirror.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"

require_cmd skopeo
require_cmd curl

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_APP_PROJECT:?}"
: "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never passed on argv)}"
: "${IMAGE_CACHE_DIR:?}"

# ---- TLS trust for the self-signed Harbor CA ----
TLS_VERIFY="true"
if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
  TLS_VERIFY="false"; log_warn "HARBOR_INSECURE=1 — skipping TLS verification (demo only)"
elif [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "$HARBOR_CA_FILE" ]; then
  trust_ca "$HARBOR_CA_FILE" harbor-ca
fi
CURL_CACERT=(); [ -f "${HARBOR_CA_FILE:-/nonexistent}" ] && CURL_CACERT=(--cacert "$HARBOR_CA_FILE")
[ "$TLS_VERIFY" = "false" ] && CURL_CACERT=(--insecure)

# ---- Harbor API helper (creds via a stdin config file — not argv) ----
harbor_api() {
  # harbor_api METHOD PATH [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o /dev/null -w '%{http_code}' -X "$method" "${CURL_CACERT[@]}"
              -K <(printf 'user = "%s:%s"\n' "$HARBOR_USERNAME" "$HARBOR_PASSWORD"))
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "https://${HARBOR_URL}/api/v2.0/${path}"
}

ensure_project() {
  local name="$1" code
  code="$(harbor_api HEAD "projects?project_name=${name}")"
  if [ "$code" = "200" ]; then
    log_info "Harbor project '$name' exists"
  else
    log_info "creating Harbor project '$name'"
    code="$(harbor_api POST "projects" "{\"project_name\":\"${name}\",\"public\":false}")"
    case "$code" in
      201|409) log_info "project '$name' ready (http $code)" ;;
      *) die "failed to create Harbor project '$name' (http $code)" ;;
    esac
  fi
}

# ---- Registry login (password on stdin) ----
log_info "logging in to Harbor $HARBOR_URL as $HARBOR_USERNAME"
printf '%s' "$HARBOR_PASSWORD" | run skopeo login --tls-verify="$TLS_VERIFY" \
  --username "$HARBOR_USERNAME" --password-stdin "$HARBOR_URL"

ensure_project "$HARBOR_INFRA_PROJECT"
ensure_project "$HARBOR_APP_PROJECT"

# ---- Push each cached image ----
mapfile -t IMAGES < <(mirror_collect_images)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images to push (run 10-mirror-pull.sh / bundle-load first)"
log_info "pushing ${#IMAGES[@]} images to Harbor"

fails=0
for src in "${IMAGES[@]}"; do
  cache="$(mirror_cache_dir "$src")"
  dst="$(mirror_target_ref "$src")"
  [ -d "$cache" ] || { log_error "cache missing for $src ($cache) — was it pulled?"; fails=$((fails+1)); continue; }
  log_info "push $src -> $dst"
  if run skopeo copy --all --preserve-digests --retry-times 3 \
        --dest-tls-verify="$TLS_VERIFY" "dir:${cache}" "docker://${dst}"; then
    :
  else
    log_error "failed to push $dst"; fails=$((fails+1))
  fi
done

[ "$fails" -eq 0 ] || die "$fails/${#IMAGES[@]} images failed to push"
log_info "pushed ${#IMAGES[@]} images into Harbor projects '$HARBOR_INFRA_PROJECT' (infra)"
