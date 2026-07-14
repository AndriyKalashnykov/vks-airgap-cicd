#!/usr/bin/env bash
# 11-bundle.sh — (SNEAKERNET) package the pulled image cache + install manifests
# into a single transferable archive to carry into the air gap.
#
# The archive contains $BUNDLE_DIR (images/ OCI cache + manifests/). Carry the git
# repo itself separately (git clone / copy) — it holds the scripts, Makefile, and
# k8s/Tekton/ArgoCD assets the inside host runs. On the air-gapped host, run
# 20-bundle-load.sh, then 21-mirror-push.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${BUNDLE_DIR:?}"
[ -d "${BUNDLE_DIR}/images" ] || die "no image cache at ${BUNDLE_DIR}/images — run 'make mirror-pull' first"

OUT_DIR="${BUNDLE_OUT_DIR:-$REPO_ROOT}"
# The tarball must NOT land inside the directory we are archiving: tar would be reading a file that
# is still growing and abort with "file changed as we read it" (it did — it broke e2e-sneakernet).
# Fail fast and say why, instead of producing a corrupt/failed bundle.
_bundle_abs="$(cd "$BUNDLE_DIR" 2>/dev/null && pwd)" || die "BUNDLE_DIR does not exist: $BUNDLE_DIR"
mkdir -p "$OUT_DIR"
_out_abs="$(cd "$OUT_DIR" && pwd)"
case "$_out_abs/" in
  "$_bundle_abs"/*) die "BUNDLE_OUT_DIR ($_out_abs) is INSIDE BUNDLE_DIR ($_bundle_abs) — tar cannot archive a directory into itself. Point BUNDLE_OUT_DIR somewhere else (default: the repo root)." ;;
esac
stamp="$(date -u +%Y%m%d-%H%M%S)"
base="vks-airgap-cicd-bundle-${stamp}"

# --- THE COMPRESSOR IS A CROSS-BOX CONTRACT, AND IT USED TO BE DECIDED UNILATERALLY ----------------
#
# This used to be `if have zstd; then --zstd; else --gzip; fi` — the OUTSIDE box choosing, from its own
# capabilities, a format the INSIDE box must be able to decode. The inside box gets no say and no warning.
# Two measured facts made that a real, shipping bug:
#
#   1. `zstd` is ABSENT from a bare photon:5.0 AND a bare ubuntu:26.04. Worse, Photon's tar is TOYBOX,
#      which has NO `--zstd` OPTION AT ALL — so even *installing* zstd does not help:
#          photon:5.0$ tdnf install -y zstd && tar --zstd -cf a.tzst f
#          tar: Unknown option 'zstd'
#      A guard of `have zstd` therefore PASSES and then tar dies with an error naming neither zstd nor
#      the bundle. The capability is tar's, not the binary's.
#   2. COMPRESSION BUYS ~1%. The payload is already-compressed OCI layer blobs (`mediaType:
#      …tar.gzip`). Measured on a 300 MB slice of the real cache: gzip 99.2%, zstd 99.9% of raw — and
#      gzip costs ~25 s/GB of single-threaded CPU, i.e. MINUTES on an 11 GB bundle, to save ~1%.
#
# So the answer is not "pick the universal compressor" — it is DON'T COMPRESS. A plain `.tar` needs no
# compressor binary and no tar compression flag, so it works on toybox, busybox, GNU tar and bsdtar
# alike. It removes the entire capability class instead of relocating it. It is also the fastest.
#
# `gzip`/`zstd` remain available for an operator who wants them (and knows their inside box can decode
# them) — bundle-load probes tar's ACTUAL capability and refuses with an actionable message.
BUNDLE_COMPRESSOR="${BUNDLE_COMPRESSOR:-none}"
case "$BUNDLE_COMPRESSOR" in
  none) tarball="${OUT_DIR}/${base}.tar";     comp=() ;;
  gzip) tarball="${OUT_DIR}/${base}.tar.gz";  comp=(--gzip) ;;
  zstd) tarball="${OUT_DIR}/${base}.tar.zst"; comp=(--zstd)
        log_warn "BUNDLE_COMPRESSOR=zstd — the AIR-GAP box's tar must support --zstd. Photon's toybox tar does NOT (no --zstd option, even with the zstd binary installed). It saves ~1% on an already-compressed payload; 'none' is the safe default." ;;
  *)    die "BUNDLE_COMPRESSOR='${BUNDLE_COMPRESSOR}' is not one of: none (default) | gzip | zstd" ;;
esac

# --- CARRY THE TOOLCHAIN, NOT JUST THE IMAGES -------------------------------------------------------
#
# The bundle used to contain images/ + manifests/ ONLY, while CLAUDE.md claimed "the air-gapped host gets
# binaries from the bundle". It did not. An operator who followed our own runbook would carry the tarball
# to a box with NO INTERNET and have NO `crane` — and `make mirror-push` would die on its first line.
#
# Our own sneakernet e2e hid this: its "air-gap box" ran `make deps`, which DOWNLOADS crane from the
# internet via mise. The IMAGE-cache fidelity was real (the box asserts bundle/ is empty and rebuilds only
# from the carried tarball); the TOOLCHAIN fidelity was fake. A green test that proves the opposite of its
# name is the exact class this repo keeps finding.
#
# The MIRROR half of the gap is ONE static Go binary: bundle-load (tar) -> mirror-push (crane, curl) ->
# mirror-verify (crane). So stage `crane` INTO the bundle — ~12 MB against an 11 GB tarball.
#
# NOTE (do not over-read this): the bundle carries the toolchain for the MIRROR half only. A full
# air-gapped INSTALL (`make platform` / `gitops` / `install-ingress`) additionally needs kubectl, helm,
# jq and envsubst on the inside box, and `46-install-istio.sh` fetches its chart from the internet.
# Those are NOT in the bundle. docs/sneakernet.md says so plainly rather than implying otherwise.
TOOLS_DIR="${BUNDLE_DIR}/tools"
mkdir -p "$TOOLS_DIR"

# `command -v crane` IS NOT ENOUGH — it can resolve to a mise SHIM (a symlink to the ~98 MB, DYNAMICALLY
# linked `mise` binary). `install` dereferences it, so we would stage MISE, RENAMED `crane`, into the
# bundle: it copies fine, it is +x, and it fails only on the air-gapped box after the carry. Resolve the
# symlink, then PROVE the thing actually runs and is statically linked — a file that exists is not a
# binary that works (the house failure of this repo).
crane_bin="$(command -v crane 2>/dev/null)" \
  || die "crane not found on PATH — it is the mirror engine, and the AIR-GAPPED box cannot download it.
  Install it here first (make deps), then re-run: the bundle must carry it."
crane_bin="$(readlink -f "$crane_bin")"

install -m 0755 "$crane_bin" "${TOOLS_DIR}/crane"

# 1. it must RUN (this is what catches the mise shim: `mise version` != `crane version`).
crane_ver="$("${TOOLS_DIR}/crane" version 2>&1 | head -1)" \
  || die "the crane we staged does not run: ${crane_bin}"
case "$crane_ver" in
  ''|*[Mm]ise*) die "the binary on PATH as 'crane' is NOT crane (it reports: '${crane_ver:-<nothing>}') — resolved to ${crane_bin}.
  This is the mise SHIM trap: ~/.local/share/mise/shims/crane is a symlink to the mise binary. Staging it
  would carry MISE across the air gap, renamed crane, and fail there with no way to fix it.
  Run 'mise install crane' / use the real binary, then re-run." ;;
esac

# 2. it must be STATIC — the air-gap box's libc is not ours to assume.
if have file && ! file -b "${TOOLS_DIR}/crane" | grep -q 'statically linked'; then
  die "the staged crane is NOT statically linked ($(file -b "${TOOLS_DIR}/crane")) — it will not run on the air-gap box's libc."
fi

# 3. ARCH IS A CROSS-BOX CONTRACT TOO. The staged crane is THIS box's arch, and (separately)
#    lib/mirror.sh pulls non-digest-pinned images for MIRROR_ARCH (default amd64). Carry BOTH facts so
#    bundle-load can refuse an arm64 inside box instead of dying with `Exec format error` after the carry.
{
  printf 'BUNDLE_HOST_ARCH=%s\n'  "$(uname -m)"
  printf 'BUNDLE_CRANE_VER=%s\n'  "$crane_ver"
  printf 'BUNDLE_MIRROR_ARCH=%s\n' "${MIRROR_ARCH:-amd64}"
} > "${TOOLS_DIR}/ARCH"

log_info "staged crane into the bundle ($(du -h "${TOOLS_DIR}/crane" | cut -f1), ${crane_ver}, $(uname -m), static) — the air-gapped box needs it and cannot download it"

log_info "creating bundle $tarball from $BUNDLE_DIR"
# -C the parent so the archive unpacks to a predictable 'bundle/' dir name.
run tar -C "$(dirname "$BUNDLE_DIR")" "${comp[@]}" \
  -cf "$tarball" "$(basename "$BUNDLE_DIR")"

# The checksum is MANDATORY, not best-effort. This bundle crosses a gap on REMOVABLE MEDIA — the one
# situation where you genuinely want the hash, and the one place a silent bit-flip is plausible. It used
# to be `if have sha256sum` on BOTH sides: no checksum written here (no warning), and no verification
# there (no warning). A "verified" that quietly did not verify is worse than none.
have sha256sum || die "sha256sum is missing on this box — the bundle crosses removable media and MUST carry a checksum. Install coreutils and re-run."
( cd "$(dirname "$tarball")" && sha256sum "$(basename "$tarball")" > "${tarball}.sha256" )
log_info "checksum: $(cat "${tarball}.sha256")"

size="$(du -h "$tarball" | cut -f1)"
# A FAT32 stick cannot hold a file >4 GiB. This bundle is ~11 GB. It is the single likeliest way a real
# sneakernet carry fails, and it fails at COPY time, on the operator's floor, with a useless error.
sz_bytes="$(stat -c%s "$tarball")"
if [ "$sz_bytes" -gt 4294967295 ]; then
  log_warn "this bundle is ${size} — it CANNOT be copied to a FAT32 / exFAT-formatted stick with a 4 GiB file limit. Use exFAT (no limit), ext4, XFS, or NTFS, or split it (split -b 3G) and cat it back."
fi
log_info "bundle ready: $tarball ($size)"
log_info "carry it (and this git repo) into the air gap, then:"
log_info "  make bundle-load BUNDLE_TARBALL=$tarball   # unpacks the images AND installs crane"
log_info "  make mirror-push && make mirror-verify     # push, then PROVE every image is intact"
