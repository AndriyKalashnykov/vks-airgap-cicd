#!/usr/bin/env bash
# 21-mirror-push.sh — push every cached image into Harbor.
# Runs on the dual-homed jump box (after 10) or the air-gapped host (after 20).
#
# Ensures the Harbor projects exist, logs in via stdin (no secret in argv), then
# crane-pushes each cached OCI image to its Harbor destination (identical mapping
# to the pull side via lib/mirror.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

require_cmd crane
require_cmd curl

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_APP_PROJECT:?}"
: "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never passed on argv)}"
: "${IMAGE_CACHE_DIR:?}"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT

# ---- TLS trust for the self-signed Harbor CA (sudo-free: SSL_CERT_FILE, not the store) ----
TLS_VERIFY="true"
if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
  TLS_VERIFY="false"; log_warn "HARBOR_INSECURE=1 — skipping TLS verification (demo only)"
elif [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "$HARBOR_CA_FILE" ]; then
  # crane (go-containerregistry) honors SSL_CERT_FILE — point it at a bundle of the system
  # CAs + the Harbor CA so pushes verify the self-signed cert WITHOUT modifying the
  # root-owned system trust store (no sudo). curl uses --cacert (below).
  BUNDLE="${HARBOR_TMP}/ca-bundle.crt"
  ca_bundle_with_system "$HARBOR_CA_FILE" "$BUNDLE"
  export SSL_CERT_FILE="$BUNDLE"
  log_info "trusting Harbor CA via SSL_CERT_FILE=$BUNDLE (no system-store change, no sudo)"
fi
CURL_CACERT=(); [ -f "${HARBOR_CA_FILE:-/nonexistent}" ] && CURL_CACERT=(--cacert "$HARBOR_CA_FILE")
[ "$TLS_VERIFY" = "false" ] && CURL_CACERT=(--insecure)
# HTTP for an insecure (kind) Harbor, HTTPS otherwise.
SCHEME="https"; [ "$TLS_VERIFY" = "false" ] && SCHEME="http"
# crane uses a boolean --insecure flag (vs skopeo's --tls-verify=<bool>).
INSECURE=(); [ "$TLS_VERIFY" = "false" ] && INSECURE=(--insecure)

# Curl auth in a real umask-077 config FILE (kept out of argv).
HARBOR_CURL_CFG="${HARBOR_TMP}/curl.cfg"
( umask 077; printf 'user = "%s:%s"\n' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > "$HARBOR_CURL_CFG" )

# ---- Harbor API helper (creds via a -K config file — not argv) ----
harbor_api() {
  # harbor_api METHOD PATH [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -o /dev/null -w '%{http_code}' "${CURL_CACERT[@]}" -K "$HARBOR_CURL_CFG")
  # Use --head for HEAD (curl -X HEAD still waits for a body -> curl error 18).
  if [ "$method" = "HEAD" ]; then args+=(--head); else args+=(-X "$method"); fi
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "${SCHEME}://${HARBOR_URL}/api/v2.0/${path}"
}

ensure_project() {
  local name="$1" code
  code="$(harbor_api HEAD "projects?project_name=${name}")"
  if [ "$code" = "200" ]; then
    log_info "Harbor project '$name' exists"
  else
    log_info "creating Harbor project '$name'"
    # Public (HARBOR_PUBLIC_PROJECTS, default true): kubelet/containerd pull anonymously
    # (no imagePullSecret on every workload). Push still requires auth (kaniko/crane log in).
    # Set false for a private-project lab — you then supply an app-namespace imagePullSecret.
    code="$(harbor_api POST "projects" "{\"project_name\":\"${name}\",\"public\":${HARBOR_PUBLIC_PROJECTS:-true}}")"
    case "$code" in
      201|409) log_info "project '$name' ready (http $code)" ;;
      *) die "failed to create Harbor project '$name' (http $code)" ;;
    esac
  fi
}

# ---- Registry login (password on stdin) ----
log_info "logging in to Harbor $HARBOR_URL as $HARBOR_USERNAME"
printf '%s' "$HARBOR_PASSWORD" | run crane auth login "$HARBOR_URL" \
  --username "$HARBOR_USERNAME" --password-stdin

# Guard the public/private toggle up front (malformed value → invalid Harbor JSON otherwise).
case "${HARBOR_PUBLIC_PROJECTS:-true}" in true|false) ;; *) die "HARBOR_PUBLIC_PROJECTS must be 'true' or 'false' (got '${HARBOR_PUBLIC_PROJECTS}')" ;; esac
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
  # No platform arg on push — the cached OCI layout already holds exactly the arch(es)
  # that were pulled; crane push preserves the manifest list/index as-is.
  log_info "push $src -> $dst"
  if mirror_retry 3 run crane push "${INSECURE[@]}" "$cache" "$dst"; then
    :
  else
    log_error "failed to push $dst"; fails=$((fails+1))
  fi
done

[ "$fails" -eq 0 ] || die "$fails/${#IMAGES[@]} images failed to push"
log_info "pushed ${#IMAGES[@]} images into Harbor projects '$HARBOR_INFRA_PROJECT' (infra)"
