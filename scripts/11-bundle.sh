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
# binaries from the bundle". It did not — and the e2e hid it by letting its "air-gap" box run `make deps`,
# which downloads them from the internet. A green test proving the opposite of its own name.
#
# WHAT MUST BE CARRIED, derived from what the air-gap box actually RUNS:
#   mirror half   bundle-load -> mirror-push -> builder-push -> mirror-verify   needs CRANE
#   install half  platform -> gitops -> install-ingress -> verify               needs KUBECTL, HELM, JQ, YQ
# `make deps` (mise) cannot run there — it downloads. All five are STATIC Go binaries (measured:
# kubectl 58M, helm 62M, jq 2.2M, yq 14M, crane 12M = ~148 MB against a multi-GB bundle), so we carry
# them. Carrying only crane made the MIRROR possible and left the INSTALL impossible — the runbook told
# operators to run steps whose tools could not exist on that box.
#
# What we CANNOT carry, and therefore must be pre-provisioned on the air-gap box (they are OS packages,
# and `git`/`openssl`/`envsubst`/`make` are MISSING on a bare photon:5.0):
#   bash tar curl sha256sum make git openssl envsubst(gettext)
# `make check-tools` on that box lists exactly what is missing — run it BEFORE carrying the bundle.
TOOLS_DIR="${BUNDLE_DIR}/tools"
mkdir -p "$TOOLS_DIR"

# mise_pin <tool> — the version THIS REPO pins in .mise.toml, or "" if it pins none.
# .mise.toml is the single source of truth for the toolchain (portfolio version-manager policy), so it is
# also the source of truth for what we are allowed to carry across the gap.
mise_pin() {
  sed 's/#.*//' "${REPO_ROOT}/.mise.toml" 2>/dev/null \
    | grep -E "^[[:space:]]*$1[[:space:]]*=" | head -1 | cut -d'"' -f2
}

# stage_tool <name> <version-args...> — resolve the PINNED binary, copy it, then PROVE the copy is the
# right tool, at the right version, statically linked, and actually runs.
#
# THREE ways `command -v <tool>` hands you the WRONG binary, and all three fail only AFTER the carry, on a
# box that cannot fix them:
#   1. a mise SHIM — a symlink to the ~94 MB DYNAMICALLY-LINKED `mise` binary. `install` dereferences it,
#      so we would carry MISE, RENAMED `kubectl`, across the gap.
#   2. ANOTHER VENDOR'S BUILD, earlier on PATH. MEASURED on the dev box that cut this bundle:
#      `command -v kubectl` -> ~/google-cloud-sdk/bin/kubectl, a gcloud "dispatcher" reporting
#      v1.34.4-dispatcher, while .mise.toml pins 1.36.2. It is a real, static, working kubectl — it is just
#      not OURS, and it is two minors off the pin the rest of the repo gates on. The old guard passed it:
#      it asked "is it mise?" and "is it static?" and never "is it the tool we pinned?".
#   3. a STALE copy in ~/.local/bin (including one a previous bundle-load installed).
# So: resolve through MISE (the pin), not through PATH — and then ASSERT the version matches the pin.
stage_tool() {
  local name="$1"; shift
  local bin ver pin

  # PIN-FIRST resolution. `mise which` returns the real install path (never a shim).
  bin=""
  if have mise; then bin="$(mise which "$name" 2>/dev/null || true)"; fi
  [ -n "$bin" ] && [ -x "$bin" ] || bin="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$bin" ] || die "${name} is not installed here, and the AIR-GAPPED box cannot download it.
  Install the toolchain on THIS box first (make deps), then re-run: the bundle must carry it."
  bin="$(readlink -f "$bin")"
  install -m 0755 "$bin" "${TOOLS_DIR}/${name}"

  # RUN THE COPY. A file that exists and is +x is not a binary that works.
  ver="$("${TOOLS_DIR}/${name}" "$@" 2>&1 | head -1)" || ver=""
  case "$ver" in
    ''|*[Mm]ise*) die "the binary resolved as '${name}' is NOT ${name} (it reports: '${ver:-<nothing>}') — resolved to ${bin}.
  This is the mise SHIM trap. Staging it would carry MISE across the air gap under another name." ;;
  esac

  # IS IT THE ONE WE PINNED? This is the check that catches a foreign vendor's build (gcloud's kubectl
  # dispatcher) — which is static, runs, and is not mise, so every other check waves it through.
  pin="$(mise_pin "$name")"
  if [ -n "$pin" ] && ! printf '%s' "$ver" | grep -qF "$pin"; then
    die "the ${name} we resolved is NOT the version this repo pins.
  .mise.toml pins : ${pin}
  resolved binary : ${bin}
  it reports      : ${ver}
  Carrying it would put an unpinned ${name} on the air-gapped box, where nobody can replace it.
  Fix the box: 'mise install' (and check 'type -a ${name}' — another ${name} may shadow mise's on PATH)."
  fi

  # STATIC? The air-gap box's libc is not ours to assume. Do NOT silently skip this when file(1) is absent
  # — a check that quietly does not run is the failure this repo keeps shipping.
  if [ "${BUNDLE_SKIP_STATIC_CHECK:-0}" = "1" ]; then
    log_warn "  BUNDLE_SKIP_STATIC_CHECK=1 — NOT checking that ${name} is statically linked (you own this)"
  elif have file; then
    # `static-pie linked` is ALSO static — file(1) prints that for a static PIE ELF, and matching only
    # on the exact string 'statically linked' would REJECT a perfectly good binary. (The grep string was
    # the bug, not file(1).)
    file -b "${TOOLS_DIR}/${name}" | grep -qE 'statically linked|static-pie' \
      || die "the staged ${name} is NOT statically linked ($(file -b "${TOOLS_DIR}/${name}")) — it may not run on the air-gap box's libc."
  else
    die "file(1) is not installed, so the STATIC-LINKAGE check on the carried binaries cannot run.
  Install it (apt-get install file / tdnf install file) — a dynamically-linked binary carried across the
  gap fails there, on the one box that cannot fix it. Override only if you know why: BUNDLE_SKIP_STATIC_CHECK=1."
  fi

  printf '%s\t%s\t%s\n' "$name" "${pin:-<unpinned>}" "$ver" >> "${TOOLS_DIR}/TOOLS.tsv.tmp"
  log_info "  staged ${name} $(du -h "${TOOLS_DIR}/${name}" | cut -f1) — pin ${pin:-<none>}, static, runs: ${ver}"
}

rm -f "${TOOLS_DIR}/TOOLS.tsv.tmp"
log_info "staging the toolchain the air-gapped box cannot download:"
stage_tool crane   version
stage_tool kubectl version --client
stage_tool helm    version
stage_tool jq      --version
stage_tool yq      --version
sort -u "${TOOLS_DIR}/TOOLS.tsv.tmp" > "${TOOLS_DIR}/TOOLS.tsv"; rm -f "${TOOLS_DIR}/TOOLS.tsv.tmp"

# ARCH IS A CROSS-BOX CONTRACT. The staged binaries are THIS box's arch, and (separately) lib/mirror.sh
# pulls non-digest-pinned images for MIRROR_ARCH (default amd64). Carry both so bundle-load can REFUSE an
# arch-mismatched box instead of dying with `Exec format error` after the carry.
{
  printf 'BUNDLE_HOST_ARCH=%s\n'   "$(uname -m)"
  printf 'BUNDLE_MIRROR_ARCH=%s\n' "${MIRROR_ARCH:-amd64}"
} > "${TOOLS_DIR}/ARCH"

log_info "toolchain staged ($(du -sh "$TOOLS_DIR" | cut -f1), $(uname -m)) — the air-gap box installs it at 'make bundle-load'"

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
