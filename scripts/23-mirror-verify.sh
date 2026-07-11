#!/usr/bin/env bash
# 23-mirror-verify.sh — verify every mirrored image is INTACT in Harbor.
#
# Why this exists: `crane push` verifies the local->registry transfer, but nothing
# confirmed Harbor SERVES the images intact afterwards. Registry blob corruption
# (e.g. from concurrent load during a mirror) surfaces LATER as a Kaniko/pull
# `MANIFEST_UNKNOWN` / `BLOB_UNKNOWN` mid-pipeline — the worst place to find it.
# For a human operator on a real jump box, this is the "are the images good?"
# gate to run AFTER `make mirror`, BEFORE driving the pipeline.
#
# Two checks per image:
#   1. INTEGRITY (hard gate) — `crane validate --remote <dst>` fetches the manifest
#      AND every layer blob and verifies their digests. A missing/corrupt blob or
#      manifest FAILS here. (MIRROR_VERIFY_FAST=1 -> --fast: manifest/config only,
#      skips layer download; faster but does NOT catch a corrupt layer blob.)
#   2. PROVENANCE (reported) — Harbor's digest vs the source digest recorded in
#      images.lock at pull time. A match proves Harbor serves the exact content we
#      mirrored. A benign difference can occur when crane rewraps a multi-arch
#      OCI layout, so a mismatch WITH integrity OK is a WARN, not a failure.
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

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${BUNDLE_DIR:?}"
LOCK_FILE="${BUNDLE_DIR}/images.lock"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
# harbor_setup exports SSL_CERT_FILE (crane trusts the self-signed CA) + sets
# HARBOR_TLS_VERIFY; crane uses a boolean --insecure flag for the plain-HTTP mode.
harbor_setup "$HARBOR_TMP"
INSECURE=(); [ "$HARBOR_TLS_VERIFY" = "false" ] && INSECURE=(--insecure)

FAST=(); [ "${MIRROR_VERIFY_FAST:-0}" = "1" ] && FAST=(--fast)

# lock_digest SRC -> the source digest recorded for SRC in images.lock (empty if none).
lock_digest() {
  [ -f "$LOCK_FILE" ] || { printf ''; return; }
  awk -v s="$1" '$1==s {print $2; exit}' "$LOCK_FILE"
}

mapfile -t IMAGES < <(mirror_collect_images)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images to verify (run 'make mirror' first)"
[ -f "$LOCK_FILE" ] || log_warn "no images.lock at $LOCK_FILE — provenance check skipped (run 'make mirror-pull' to generate it)"

log_info "verifying ${#IMAGES[@]} images in Harbor $HARBOR_URL/$HARBOR_INFRA_PROJECT (mode: ${MIRROR_VERIFY_FAST:+fast}${MIRROR_VERIFY_FAST:-full})"
fails=0; warns=0
pg_init "${#IMAGES[@]}"
for src in "${IMAGES[@]}"; do
  dst="$(mirror_target_ref "$src")"
  pg_step "verify $dst"
  # 1. INTEGRITY (hard gate)
  if ! err="$(crane validate --remote "$dst" "${FAST[@]}" "${INSECURE[@]}" 2>&1)"; then
    log_error "  INTEGRITY FAIL  $dst"
    log_error "    $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"
    fails=$((fails+1)); continue
  fi
  # 2. PROVENANCE (reported; WARN-only when integrity already passed)
  want="$(lock_digest "$src")"
  if [ -n "$want" ]; then
    got="$(crane digest "$dst" "${INSECURE[@]}" 2>/dev/null || true)"
    if [ "$got" = "$want" ]; then
      log_info "  OK    $dst (integrity + digest $got)"
    else
      log_warn "  WARN  $dst integrity OK but digest differs from lock (want $want got ${got:-<none>}) — likely OCI-layout rewrap"
      warns=$((warns+1))
    fi
  else
    log_info "  OK    $dst (integrity; no lock digest to match)"
  fi
done

if [ "$fails" -gt 0 ]; then
  die "$fails/${#IMAGES[@]} images FAILED integrity — Harbor's copy is corrupt/incomplete (re-mirror; see the no-concurrent-load rule)"
fi
pg_done "mirror-verify: ${#IMAGES[@]} images intact in Harbor${warns:+ (${warns} provenance warnings)}"
