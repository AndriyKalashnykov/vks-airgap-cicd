#!/usr/bin/env bash
# scripts/01-install-vcf-clis.sh — install the Broadcom VCF/VKS lab CLIs a jump box needs to
# drive a REAL VCF/VKS 9.1 lab: the VCF-flavored argocd, the VCF Consumption CLI (vcf), and its
# plugin bundle. NOT needed for the local KinD flow (that uses the upstream argocd from
# 00-install-prereqs.sh) — install these only when targeting an actual lab.
#
# The artifacts are Broadcom-LICENSED and OPERATOR-SUPPLIED. Download them however you have
# entitlement (the Broadcom support portal, an internal mirror, ...) on an internet-connected
# box, put them ALL in ONE directory, and point VCF_CLI_SRC_DIR at it — the air-gap-correct
# path (carry the folder in; no download client / token / network at install time). The folder
# may hold per-arch files AND/OR the portal's multi-arch "Binaries" bundles; this script picks
# the right archive for THIS jump box's OS/arch and extracts the matching binary.
#
# Sudo-free: installs to BIN_DIR (~/.local/bin by default). Usage:
#   VCF_CLI_SRC_DIR=<dir> scripts/01-install-vcf-clis.sh [all|argocd|vcf|plugins]   (default: all)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

WHAT="${1:-all}"
BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"
# The one input: a directory holding the downloaded, licensed artifacts.
SRC_DIR="${VCF_CLI_SRC_DIR:?set VCF_CLI_SRC_DIR to the directory holding the downloaded VCF/VKS lab CLI artifacts (argocd/vcf/plugins)}"

# Pinned versions (operator-supplied — track whatever licensed artifacts you hold; Renovate
# cannot bump a licensed download, so they live in .env.example, not renovate).
ARGOCD_VCF_VERSION="${ARGOCD_VCF_VERSION:?set ARGOCD_VCF_VERSION in .env.example (e.g. v3.0.19-vcf)}"
VCF_CLI_VERSION="${VCF_CLI_VERSION:?set VCF_CLI_VERSION in .env.example (e.g. 9.1.0.0.25296329)}"
VCF_PLUGINS_VERSION="${VCF_PLUGINS_VERSION:?set VCF_PLUGINS_VERSION in .env.example (e.g. 9.1.0.0300.25509668)}"

[ -d "$SRC_DIR" ] || die "VCF_CLI_SRC_DIR '$SRC_DIR' is not a directory"
mkdir -p "$BIN_DIR"
case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) log_warn "add $BIN_DIR to your PATH" ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- OS/arch of THIS jump box → the tokens used in the artifact filenames ------
os="$(uname -s)"; os="${os,,}"                         # linux | darwin (bash lowercase, no `tr`)
case "$(uname -m)" in
  x86_64|amd64)  go_arch=amd64; vcf_arch=AMD64 ;;
  aarch64|arm64) go_arch=arm64; vcf_arch=ARM64 ;;
  *) die "unsupported machine arch: $(uname -m)" ;;
esac

# Expected vendor filenames for this OS/arch, parameterized by the pinned versions.
argocd_file="argocd-cli-${os}-${go_arch}-${ARGOCD_VCF_VERSION}.gz"
vcf_file="VCF-Consumption-CLI-Linux_${vcf_arch}-${VCF_CLI_VERSION}.tar.gz"
plugins_file="VCF-Consumption-CLI-PluginBundle-Linux_${vcf_arch}-${VCF_PLUGINS_VERSION}.tar.gz"

RESOLVED_ARCHIVE=""

# resolve_archive <cli> — locate the <cli> archive in VCF_CLI_SRC_DIR (the exact vendor name for
# this OS/arch, OR a version glob so the portal's multi-arch "…-Binaries-…" bundle also matches),
# copy it into $WORK, validate it's a gzip, and set RESOLVED_ARCHIVE. Returns via a global (NOT
# stdout) so no sub-tool's output can corrupt the path.
resolve_archive() {
  local cli="$1" glob="" name="" out m
  case "$cli" in
    argocd)  name="$argocd_file";  glob="argocd-cli-${os}-${go_arch}-${ARGOCD_VCF_VERSION}*" ;;
    vcf)     name="$vcf_file";     glob="VCF-Consumption-CLI-*${VCF_CLI_VERSION}*.tar.gz" ;;
    plugins) name="$plugins_file"; glob="VCF-Consumption-CLI-*Plugin*${VCF_PLUGINS_VERSION}*.tar.gz" ;;
    *) die "resolve_archive: unknown cli '$cli'" ;;
  esac
  out="${WORK}/${cli}-archive"
  if [ -f "${SRC_DIR}/${name}" ]; then
    log_info "using ${name} from VCF_CLI_SRC_DIR"; cp "${SRC_DIR}/${name}" "$out"
  elif m="$(find "$SRC_DIR" -maxdepth 1 -type f -name "$glob" 2>/dev/null | sort | head -1)" && [ -n "$m" ]; then
    # `sort` makes the pick deterministic across machines (find order is filesystem-dependent).
    # The glob is version-pinned per cli, so only same-version archives can co-match here (e.g. an
    # arch-agnostic "…-Binaries-…" bundle) — a differently-versioned artifact in the folder is
    # never selected; the wrong-version case dies below, it does not silently pick.
    log_info "using $(basename "$m") from VCF_CLI_SRC_DIR"; cp "$m" "$out"
  else
    die "no ${cli} artifact for ${os}/${go_arch} in ${SRC_DIR} (looked for '${name}' or '${glob}') — put that archive in the folder"
  fi
  [ -s "$out" ] || die "the ${cli} archive is empty"
  # Portable gzip-validity check: decompress to /dev/null. `gunzip -c` works on GNU gzip AND
  # Photon's toybox gzip (which has NO `gzip -t` — it errors "Unknown option 't'").
  gunzip -c "$out" >/dev/null 2>&1 || die "the ${cli} archive is not a valid gzip (corrupt/incomplete artifact?)"
  RESOLVED_ARCHIVE="$out"
}

# --- Installers --------------------------------------------------------------

install_argocd_vcf() {
  log_info "installing argocd (VCF ${ARGOCD_VCF_VERSION}, ${os}/${go_arch}) -> ${BIN_DIR}/argocd"
  log_warn "this is the VCF-flavored argocd for a real lab; it shadows any upstream argocd in ${BIN_DIR}"
  local ar d bin; resolve_archive argocd; ar="$RESOLVED_ARCHIVE"
  # The argocd artifact is either a bare .gz of the binary OR a tarball/bundle. Detect
  # robustly: try to extract it as a tar.gz — if that yields at least one file, it's a bundle
  # (find the argocd binary); otherwise the .gz is the raw binary, so gunzip it straight out.
  # (The "extracted a file?" check avoids the false-positive where `tar` reads a tiny non-tar
  # gzip as an empty archive.)
  d="$(mktemp -d)"
  if tar -xzf "$ar" -C "$d" 2>/dev/null && [ -n "$(find "$d" -type f 2>/dev/null | head -1)" ]; then
    bin="$(find "$d" -type f \( -name "argocd-cli-${os}-${go_arch}*" -o -name "argocd-${os}-${go_arch}" -o -name argocd \) | head -1)"
    [ -n "$bin" ] || bin="$(find "$d" -type f -name 'argocd*' | head -1)"
    [ -n "$bin" ] || { rm -rf "$d"; die "argocd binary not found inside the archive"; }
    install -m 0755 "$bin" "${BIN_DIR}/argocd"
  else
    gunzip -c "$ar" > "${BIN_DIR}/argocd"; chmod 0755 "${BIN_DIR}/argocd"
  fi
  rm -rf "$d"
  "${BIN_DIR}/argocd" version --client || log_warn "argocd installed but 'version --client' failed"
}

install_vcf_cli() {
  [ "$os" = linux ] || die "the VCF Consumption CLI is Linux-only for this installer (no ${os} target)"
  log_info "installing vcf (VCF Consumption CLI ${VCF_CLI_VERSION}, ${os}/${go_arch}) -> ${BIN_DIR}/vcf"
  local ar d bin; resolve_archive vcf; ar="$RESOLVED_ARCHIVE"
  d="$(mktemp -d)"; tar -xzf "$ar" -C "$d"
  # Flat tarball (vcf-cli-linux_<arch> at root) OR a multi-arch "Binaries" bundle
  # (<os>/<arch>/v<ver>/vcf-cli-<os>_<arch>) — find at ANY depth.
  bin="$(find "$d" -type f -name "vcf-cli-${os}_${go_arch}" | head -1)"
  [ -n "$bin" ] || { rm -rf "$d"; die "vcf-cli-${os}_${go_arch} not found inside the archive"; }
  install -m 0755 "$bin" "${BIN_DIR}/vcf"; rm -rf "$d"
  "${BIN_DIR}/vcf" version || log_warn "vcf installed but 'vcf version' failed"
}

install_vcf_plugins() {
  [ "$os" = linux ] || die "the VCF Consumption CLI plugin bundle is Linux-only for this installer (no ${os} target)"
  have vcf || [ -x "${BIN_DIR}/vcf" ] || die "install the vcf CLI first (make install-vcf-cli)"
  local vcf_bin; vcf_bin="$(command -v vcf || echo "${BIN_DIR}/vcf")"
  log_info "installing vcf plugins (bundle ${VCF_PLUGINS_VERSION}, ${os}/${go_arch})"
  local ar pdir src; resolve_archive plugins; ar="$RESOLVED_ARCHIVE"
  pdir="${WORK}/plugins"; mkdir -p "$pdir"; tar -xzf "$ar" -C "$pdir"
  # A multi-arch bundle nests the plugins under <os>/<arch>/...; point --local-source there.
  src="$pdir"
  local archdir; archdir="$(find "$pdir" -type d -path "*/${os}/${go_arch}" | head -1)"
  [ -n "$archdir" ] && src="$archdir"
  # `vcf plugin install all` is idempotent — it upgrades/replaces in place, so no pre-clean is
  # needed (verified: a second install over existing state succeeds). Real vcf state lives under
  # ~/.config/vcf + ~/.local/share/vcf-cli; do NOT wipe those (it would destroy the operator's
  # vcf config/context on a re-install).
  run "$vcf_bin" plugin install all --local-source "$src"
  "$vcf_bin" plugin list || log_warn "plugins installed but 'vcf plugin list' failed"
}

# --- Preflight: the extraction/install tools every path needs (clear error over a cryptic
#     mid-run failure). `find` (findutils) is the usual gap on a bare Photon box.
for _t in tar gzip find install; do require_cmd "$_t"; done

# --- Dispatch ----------------------------------------------------------------
case "$WHAT" in
  argocd)  install_argocd_vcf ;;
  vcf)     install_vcf_cli ;;
  plugins) install_vcf_plugins ;;
  all)     install_argocd_vcf; install_vcf_cli; install_vcf_plugins ;;
  *) die "usage: $0 [all|argocd|vcf|plugins]" ;;
esac

log_info "VCF/VKS lab CLIs installed to ${BIN_DIR} (ensure it is on your PATH)"
