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
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
# shellcheck source=scripts/lib/progress.sh
. "${SCRIPT_DIR}/lib/progress.sh"

require_cmd crane
require_cmd curl

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_APP_PROJECT:?}"
: "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never passed on argv)}"
: "${IMAGE_CACHE_DIR:?}"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT

# ---- TLS trust + auth for the self-signed Harbor CA (sudo-free; see lib/harbor.sh) ----
# harbor_setup exports SSL_CERT_FILE (crane) and sets SCHEME / CURL_CACERT / HARBOR_CURL_CFG /
# HARBOR_TLS_VERIFY; harbor_api + ensure_project come from the same lib (shared with 22-harbor-robot.sh).
harbor_setup "$HARBOR_TMP"
# crane uses a boolean --insecure flag (vs skopeo's --tls-verify=<bool>).
INSECURE=(); [ "$HARBOR_TLS_VERIFY" = "false" ] && INSECURE=(--insecure)

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
pg_init "${#IMAGES[@]}"
for src in "${IMAGES[@]}"; do
  cache="$(mirror_cache_dir "$src")"
  dst="$(mirror_target_ref "$src")"
  [ -d "$cache" ] || { log_error "cache missing for $src ($cache) — was it pulled?"; fails=$((fails+1)); continue; }
  # No platform arg on push — the cached OCI layout already holds exactly the arch(es)
  # that were pulled; crane push preserves the manifest list/index as-is.
  pg_step "push $src -> $dst"
  if mirror_retry "${MIRROR_RETRIES:-5}" run crane push "${INSECURE[@]}" "$cache" "$dst"; then
    :
  else
    log_error "failed to push $dst"; fails=$((fails+1))
  fi
done

[ "$fails" -eq 0 ] || die "$fails/${#IMAGES[@]} images failed to push"
pg_done "mirror-push: ${#IMAGES[@]} images into Harbor project '$HARBOR_INFRA_PROJECT'"
log_info "verify integrity with: make mirror-verify"
