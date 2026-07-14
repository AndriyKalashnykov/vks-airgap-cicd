#!/usr/bin/env bash
# 20-bundle-load.sh — (SNEAKERNET, air-gap host) unpack a transferred bundle so
# 21-mirror-push.sh can push its images into Harbor.
#
# Usage: make bundle-load BUNDLE_TARBALL=/path/to/vks-airgap-cicd-bundle-*.tar.zst
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${BUNDLE_DIR:?}"
tarball="${BUNDLE_TARBALL:?set BUNDLE_TARBALL=/path/to/vks-airgap-cicd-bundle-*.tar.[zst|gz]}"
[ -f "$tarball" ] || die "bundle not found: $tarball"

# --- CHECKSUM: MANDATORY, NOT "IF PRESENT" ----------------------------------------------------------
# This was `if [ -f .sha256 ] && have sha256sum` — so a bundle with no checksum, or a box with no
# sha256sum, SILENTLY SKIPPED verification and printed nothing. The archive just crossed an air gap on
# removable media. Skipping the hash is exactly backwards: this is the one place it matters.
have sha256sum || die "sha256sum is missing on this box — it is required to verify a bundle that crossed removable media."
[ -f "${tarball}.sha256" ] || die "no checksum beside the bundle (${tarball}.sha256).
  Carry it too — it is written next to the tarball by 'make bundle', and it is how you find out the copy
  was corrupted BEFORE you spend 20 minutes pushing a broken cache into Harbor."
log_info "verifying checksum"
( cd "$(dirname "$tarball")" && sha256sum -c "$(basename "${tarball}.sha256")" ) \
  || die "CHECKSUM MISMATCH for $tarball — the copy across the gap is corrupt. Re-copy it; do not push it."

# --- EXTRACT: PROBE TAR'S CAPABILITY, DO NOT INFER IT FROM A BINARY'S PRESENCE ----------------------
# `have zstd || die "zstd required"` was the WRONG GUARD. Photon's tar is TOYBOX, which has NO --zstd
# option at all — so on Photon that guard PASSES (the zstd binary is there) and tar then dies with
#     tar: Unknown option 'zstd'
# an error naming neither zstd nor the bundle. The capability belongs to TAR, not to the binary. Probe
# tar itself, and if it cannot, say the ONE thing the operator can act on — because this box has no
# internet and cannot install anything: the bundle must be RE-CUT on the internet side.
# tar_supports --zstd|--gzip : can THIS tar actually do it?
#
# PROBE WITH A REAL FILE, NOT `-T -`. The first draft was `echo x | tar "$1" -cf /dev/null -T -`, and
# toybox tar DOES NOT SUPPORT `-T` — so the probe answered "no" for --gzip, which toybox actually
# SUPPORTS. That guard would have refused a perfectly good .tar.gz on Photon: a brand-new gate breaking
# a working path, which is why a freshly-built instrument is trusted last, not first.
# Ground truth on photon:5.0 (toybox 0.8.9): --gzip YES, --zstd NO ("tar: Unknown option 'zstd'").
tar_supports() {
  local d; d="$(mktemp -d)"; : > "${d}/probe"
  local rc=0
  tar "$1" -cf /dev/null -C "$d" probe >/dev/null 2>&1 || rc=1
  rm -rf "$d"
  return $rc
}
dest="$(dirname "$BUNDLE_DIR")"
log_info "extracting $tarball into $dest"
case "$tarball" in
  # A plain .tar is the DEFAULT and needs no compressor and no tar flag — it works on toybox, busybox,
  # GNU and bsdtar alike. (Compression buys ~1% on already-gzipped OCI layers; see 11-bundle.sh.)
  *.tar)     run tar -C "$dest" -xf "$tarball" ;;
  *.tar.gz)  tar_supports --gzip || die "this box's tar cannot decompress gzip. Re-cut the bundle on the internet box with: make bundle BUNDLE_COMPRESSOR=none"
             run tar -C "$dest" --gzip -xf "$tarball" ;;
  *.tar.zst) tar_supports --zstd || die "THIS BOX'S TAR CANNOT UNPACK ZSTD ($(tar --version 2>&1 | head -1)).
  Photon's toybox tar has no --zstd option at all — installing the zstd binary does NOT fix it, and this
  box has no internet to install a different tar anyway.
  The fix is on the INTERNET box, not here: re-cut the bundle with
      make bundle BUNDLE_COMPRESSOR=none      # a plain .tar — universal, and ~1% larger
  and carry that instead."
             run tar -C "$dest" --zstd -xf "$tarball" ;;
  *)         die "unknown archive type: $tarball (expected .tar, .tar.gz or .tar.zst)" ;;
esac

[ -d "${BUNDLE_DIR}/images" ] || die "extraction did not produce ${BUNDLE_DIR}/images"
# The manifests are as load-bearing as the images on an air-gapped box: Tekton's install YAML AND the
# Gateway API CRDs are carried here. A bundle with images but no manifests gets all the way to
# `make install-ingress` before dying — and until recently it died reaching for github.com, which on
# an air-gapped box is a network timeout that names nothing useful.
[ -d "${BUNDLE_DIR}/manifests" ] || die "extraction did not produce ${BUNDLE_DIR}/manifests — this bundle carries images but no manifests (Tekton install YAML, Gateway API CRDs). Re-cut it: make mirror-pull && make bundle"
# --- INSTALL THE CARRIED TOOLCHAIN ------------------------------------------------------------------
# The air-gapped box cannot download crane (that is the whole point), so the bundle carries it. Install it
# onto PATH here — this is the step that makes `make mirror-push` possible on a box with no internet.
BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"
if [ -x "${BUNDLE_DIR}/tools/crane" ]; then
  # ARCH IS A CROSS-BOX CONTRACT. The staged crane is the INTERNET box's arch, and (separately) the
  # cached images were pulled for MIRROR_ARCH. Compare both against THIS box now — an arch mismatch
  # otherwise surfaces as `Exec format error` at mirror-push, or (worse) as `exec format error` inside
  # Kubernetes three steps later, with nothing pointing back at the carry.
  if [ -f "${BUNDLE_DIR}/tools/ARCH" ]; then
    # shellcheck disable=SC1091
    . "${BUNDLE_DIR}/tools/ARCH"
    if [ "${BUNDLE_HOST_ARCH:-}" != "$(uname -m)" ]; then
      die "ARCH MISMATCH: this bundle was cut on ${BUNDLE_HOST_ARCH} but this box is $(uname -m).
  The carried crane will not execute here, and the cached images were pulled for
  MIRROR_ARCH=${BUNDLE_MIRROR_ARCH:-amd64}. Re-cut the bundle on a ${BUNDLE_HOST_ARCH:-<other>} box (or set
  MIRROR_ARCH=$(uname -m) there) and carry that."
    fi
  fi

  mkdir -p "$BIN_DIR"
  install -m 0755 "${BUNDLE_DIR}/tools/crane" "${BIN_DIR}/crane"

  # RUN IT. This used to be `$(… version 2>/dev/null | head -1)` inside a log line — which swallowed the
  # failure, logged an EMPTY version, and carried on. A file that exists and is +x is not a binary that
  # works: `command -v crane` on the internet box can resolve to a mise SHIM (a symlink to the mise
  # binary), so what got staged could be MISE, RENAMED crane. That fails HERE, on a box with no internet.
  crane_ver="$("${BIN_DIR}/crane" version 2>&1 | head -1)" \
    || die "the carried crane does not execute on this box ($(uname -m)): ${BIN_DIR}/crane
  If the bundle was cut on a different architecture, re-cut it on a $(uname -m) box."
  case "$crane_ver" in
    ''|*[Mm]ise*) die "the carried 'crane' is NOT crane (it reports: '${crane_ver:-<nothing>}').
  The internet box staged a mise SHIM instead of the real binary. Re-cut the bundle there." ;;
  esac
  log_info "installed the carried crane -> ${BIN_DIR}/crane (${crane_ver})"
  case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) log_warn "add $BIN_DIR to your PATH so 'make mirror-push' can find crane" ;; esac
else
  # Not fatal ONLY if crane is somehow already here (a pre-provisioned box). Otherwise say the real cause
  # now, not three commands later when mirror-push dies with 'crane: command not found'.
  have crane || die "this bundle carries no toolchain (${BUNDLE_DIR}/tools/crane is missing) and crane is
  not installed on this box. The air-gapped host CANNOT download it. Re-cut the bundle on the internet
  side with a current 'make bundle' — it stages crane — and carry that."
  log_warn "bundle carries no tools/crane, but crane is already on this box — continuing with $(command -v crane)"
fi

n="$(find "${BUNDLE_DIR}/images" -maxdepth 1 -type d | wc -l)"
log_info "bundle loaded: $((n-1)) cached images under ${BUNDLE_DIR}/images"
log_info "next: make mirror-push"
