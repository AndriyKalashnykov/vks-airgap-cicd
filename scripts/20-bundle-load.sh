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
# This box cannot download ANY of it — that is what "air-gapped" means. The bundle carries the static
# binaries the flow needs (crane for the mirror; kubectl/helm/jq/yq for the install), and this is the step
# that puts them on PATH. It used to install crane ONLY, which made the mirror possible and left the
# install impossible while the runbook cheerfully told operators to run it.
BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"
TOOLS_DIR="${BUNDLE_DIR}/tools"

if [ ! -d "$TOOLS_DIR" ]; then
  # Not fatal only if the tools are somehow already here (a pre-provisioned box). Otherwise say the real
  # cause NOW, not three commands later when mirror-push dies with 'crane: command not found'.
  have crane || die "this bundle carries no toolchain (${TOOLS_DIR} is missing) and crane is not installed
  on this box. The air-gapped host CANNOT download it. Re-cut the bundle on the internet side with a
  current 'make bundle' — it stages crane, kubectl, helm, jq and yq — and carry that."
  log_warn "bundle carries no tools/, but the toolchain is already on this box — continuing with $(command -v crane)"
else
  # ARCH IS A CROSS-BOX CONTRACT. The staged binaries are the INTERNET box's arch, and (separately) the
  # cached images were pulled for MIRROR_ARCH. Compare both against THIS box now — a mismatch otherwise
  # surfaces as `Exec format error` at mirror-push, or (worse) as `exec format error` inside Kubernetes
  # three steps later, with nothing pointing back at the carry.
  if [ -f "${TOOLS_DIR}/ARCH" ]; then
    # shellcheck disable=SC1091
    . "${TOOLS_DIR}/ARCH"
    if [ "${BUNDLE_HOST_ARCH:-}" != "$(uname -m)" ]; then
      die "ARCH MISMATCH: this bundle was cut on ${BUNDLE_HOST_ARCH} but this box is $(uname -m).
  The carried binaries will not execute here, and the cached images were pulled for
  MIRROR_ARCH=${BUNDLE_MIRROR_ARCH:-amd64}. Re-cut the bundle on a ${BUNDLE_HOST_ARCH:-<other>} box (or set
  MIRROR_ARCH=<amd64|arm64> there — NOT $(uname -m): OCI platforms are 'amd64'/'arm64', so
  'linux/aarch64' or 'linux/x86_64' would make the pull fail) and carry that."
    fi
  fi

  mkdir -p "$BIN_DIR"
  installed=0
  kept=0
  for t in "$TOOLS_DIR"/*; do
    name="$(basename "$t")"
    case "$name" in ARCH|TOOLS.tsv) continue ;; esac
    [ -f "$t" ] || continue

    # DO NOT CLOBBER A TOOL THIS BOX ALREADY HAS. ~/.local/bin comes FIRST on PATH, so installing ours
    # unconditionally would SHADOW the operator's — and their kubectl is very likely the one their lab
    # pinned to their cluster's version. Silently overriding it is a version-skew bug we would have
    # introduced ourselves, on the one box that cannot easily undo it.
    #
    # So: if the tool is already here AND RUNS, keep theirs and say so. Ours is only for what is MISSING.
    # BUNDLE_TOOLS_FORCE=1 overrides (e.g. the box's copy is broken or the wrong arch).
    # what WE carry, per the bundle's own manifest (no network needed to know it)
    carried_ver="$(awk -F'\t' -v n="$name" '$1==n{print $3}' "${TOOLS_DIR}/TOOLS.tsv" 2>/dev/null | head -1 || true)"
    why=""
    if [ "${BUNDLE_TOOLS_FORCE:-0}" != "1" ] && existing="$(command -v "$name" 2>/dev/null)"; then
      case "$name" in
        crane)   ev="$("$existing" version 2>&1 | head -1)" ;;
        kubectl) ev="$("$existing" version --client 2>&1 | head -1)" ;;
        helm)    ev="$("$existing" version --short 2>&1 | head -1)" ;;
        *)       ev="$("$existing" --version 2>&1 | head -1)" ;;
      esac
      # A FLOOR. `[ -n "$ev" ]` alone was not a policy: **helm 2** prints `Client: v2.x` (non-empty), so an
      # ancient helm would be silently PREFERRED over the pinned one we carried, and then fail at
      # `helm upgrade --install` with a nonsense error. We have no network to look versions up — but we do
      # not need one: the bundle carries TOOLS.tsv (name / pin / version), so compare against that.
      keep_it=1
      case "$name" in
        helm)    printf '%s' "$ev" | grep -qE 'v?3\.' || { keep_it=0; why="helm 2 (or unrecognised) — this flow needs helm 3" ; } ;;
        kubectl) # within one minor of what we carry, else skew bites at apply time.
                 # `|| true` is LOAD-BEARING, not defensive: `grep -oE` exits 1 when it matches
                 # nothing, `pipefail` promotes that to the assignment, and `set -e` (line 6) then
                 # kills bundle-load SILENTLY — rc=1, zero output, on the AIR-GAP box. The
                 # `[ -n "$have_mm" ]` guard below was written for exactly that case and was
                 # UNREACHABLE DEAD CODE without this. Measured: 4 of 6 realistic
                 # `kubectl version --client` outputs kill it (an `unknown flag` error, a mise-shim
                 # error, a version with no leading `v`, and empty). `ours_mm` is worse still: it
                 # reads TOOLS.tsv field 3, which 11-bundle.sh:15 leaves EMPTY when the staged
                 # binary would not run — so a slightly-bad bundle killed the far side, silently.
                 have_mm="$(printf '%s' "$ev"     | grep -oE 'v[0-9]+\.[0-9]+' | head -1 || true)"
                 ours_mm="$(printf '%s' "$carried_ver" | grep -oE 'v[0-9]+\.[0-9]+' | head -1 || true)"
                 # POLARITY, deliberately matching the helm branch one line above: an UNPARSEABLE
                 # version is a REJECT, not a keep. Absorbing the failure with a bare `|| true` and
                 # falling through would KEEP an unreadable kubectl while helm REPLACES an unreadable
                 # helm — two adjacent branches with opposite policies for the same condition.
                 if [ -z "$have_mm" ]; then
                   keep_it=0; why="cannot parse a version from '${ev}' — refusing to trust it over the carried ${carried_ver}"
                 elif [ -n "$ours_mm" ] && [ "$have_mm" != "$ours_mm" ]; then
                   h="${have_mm#v}"; o="${ours_mm#v}"
                   hmin="${h#*.}"; omin="${o#*.}"
                   d=$(( hmin > omin ? hmin - omin : omin - hmin ))
                   [ "${h%%.*}" = "${o%%.*}" ] && [ "$d" -le 1 ] || { keep_it=0; why="${ev} is more than one minor from the carried ${carried_ver}"; }
                 fi ;;
      esac
      if [ "$keep_it" = 1 ] && [ -n "$ev" ]; then
        log_info "  KEPT ${name} — this box already has a working one (${existing}: ${ev}); not overriding it"
        kept=$((kept + 1))
        continue
      fi
      [ -n "$ev" ] && log_warn "  ${name} on this box is TOO OLD to use (${existing}: ${ev}) — ${why}. Installing the carried one."
      log_warn "  ${name} exists at ${existing} but does not run — installing the carried one over it"
    fi

    install -m 0755 "$t" "${BIN_DIR}/${name}"

    # RUN IT. A file that exists and is +x is not a binary that works: `command -v` on the internet box
    # can resolve to a mise SHIM, so what got staged could be MISE under another name. That fails HERE,
    # on a box with no internet. (This check used to hide inside a log line with `2>/dev/null`, which
    # swallowed the failure and logged an EMPTY version.)
    case "$name" in
      crane)   probe=(version) ;;
      kubectl) probe=(version --client) ;;
      helm)    probe=(version) ;;
      jq|yq)   probe=(--version) ;;
      *)       probe=(--version) ;;
    esac
    ver="$("${BIN_DIR}/${name}" "${probe[@]}" 2>&1 | head -1)" || ver=""
    case "$ver" in
      ''|*[Mm]ise*) die "the carried '${name}' does not run on this box $(uname -m) (it reports: '${ver:-<nothing>}').
  Either the bundle was cut on a different architecture, or the internet box staged a mise SHIM instead of
  the real binary. Re-cut the bundle there." ;;
    esac
    log_info "  installed ${name} -> ${BIN_DIR}/${name}"
    installed=$((installed + 1))
  done
  log_info "carried toolchain: ${installed} installed, ${kept} already present and kept (this box could not have downloaded any of them)"
  [ "${BUNDLE_TOOLS_FORCE:-0}" = "1" ] || [ "$kept" -eq 0 ] \
    || log_info "  (BUNDLE_TOOLS_FORCE=1 replaces the box's copies with the carried ones)"
  # FAIL, do not warn. The very next step is `make platform`, which runs kubectl — and on this box a
  # `command not found` cannot be fixed by installing anything. A warning at the end of a 12 GB load is
  # not where an operator is looking.
  case ":$PATH:" in
    *":$BIN_DIR:"*) : ;;
    *) die "the carried toolchain is installed in ${BIN_DIR}, but that is NOT on your PATH — so the next
  steps (make platform / gitops / verify) will not find kubectl/helm/jq/yq. Add it and re-run:
      export PATH=\"${BIN_DIR}:\$PATH\"
  (Or set BIN_DIR to a directory already on your PATH: make bundle-load BIN_DIR=/usr/local/bin ...)" ;;
  esac
fi

# The tools we CANNOT carry: OS packages. On a bare photon:5.0, `make`, `awk`, `git`, `openssl` and
# `envsubst` are ALL missing, and this box cannot install them from the internet. Say so HERE, before the
# operator gets three steps into an install that cannot finish.
#
# `awk` was missing from this list, and it is not cosmetic: lib/apps.sh reads apps/registry.tsv with it
# (EVERY per-app loop) and 23-mirror-verify.sh does its images.lock digest lookup with it. So a bare Photon
# jump box loaded the bundle happily and then died at mirror-verify — with nothing here having warned it.
missing_os=""
for t in bash tar curl sha256sum make awk git openssl envsubst; do
  command -v "$t" >/dev/null 2>&1 || missing_os="${missing_os} ${t}"
done
if [ -n "$missing_os" ]; then
  log_warn "these are NOT in the bundle (they are OS packages) and are MISSING on this box:${missing_os}"
  log_warn "  the mirror (mirror-push / mirror-verify) may still work; the INSTALL (platform/gitops/verify) will not."
  log_warn "  Install them from your lab's package mirror:"
  log_warn "    apt-get install -y git openssl gettext-base make gawk tar curl   # Debian/Ubuntu"
  log_warn "    tdnf install -y git openssl gettext make gawk tar curl           # Photon"
  log_warn "  'make check-tools' lists everything the flow needs."
fi

n="$(find "${BUNDLE_DIR}/images" -maxdepth 1 -type d | wc -l)"
log_info "bundle loaded: $((n-1)) cached images under ${BUNDLE_DIR}/images"
log_info "next: make mirror-push"
