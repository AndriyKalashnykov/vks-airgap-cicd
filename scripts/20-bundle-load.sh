#!/usr/bin/env bash
# 20-bundle-load.sh — (SNEAKERNET, air-gap host) unpack a transferred bundle so
# 21-mirror-push.sh can push its images into Harbor.
#
# Usage: make bundle-load BUNDLE_TARBALL=/path/to/vks-cicd-bundle-*.tar.zst
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${BUNDLE_DIR:?}"
tarball="${BUNDLE_TARBALL:?set BUNDLE_TARBALL=/path/to/vks-cicd-bundle-*.tar.[zst|gz]}"
[ -f "$tarball" ] || die "bundle not found: $tarball"

# Verify checksum if present.
if [ -f "${tarball}.sha256" ] && have sha256sum; then
  log_info "verifying checksum"
  ( cd "$(dirname "$tarball")" && sha256sum -c "$(basename "${tarball}.sha256")" ) \
    || die "checksum mismatch for $tarball"
fi

dest="$(dirname "$BUNDLE_DIR")"
log_info "extracting $tarball into $dest"
case "$tarball" in
  *.tar.zst) have zstd || die "zstd required to unpack $tarball"; run tar -C "$dest" --zstd -xf "$tarball" ;;
  *.tar.gz)  run tar -C "$dest" --gzip -xf "$tarball" ;;
  *)         die "unknown archive type: $tarball (expected .tar.zst or .tar.gz)" ;;
esac

[ -d "${BUNDLE_DIR}/images" ] || die "extraction did not produce ${BUNDLE_DIR}/images"
n="$(find "${BUNDLE_DIR}/images" -maxdepth 1 -type d | wc -l)"
log_info "bundle loaded: $((n-1)) cached images under ${BUNDLE_DIR}/images"
log_info "next: make mirror-push"
