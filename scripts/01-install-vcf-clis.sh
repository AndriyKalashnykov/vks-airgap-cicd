#!/usr/bin/env bash
# scripts/01-install-vcf-clis.sh — download + install the Broadcom VCF/VKS lab CLIs a
# jump box needs to drive a REAL VCF/VKS 9.1 lab. These are NOT needed for the local KinD
# flow (which uses the upstream argocd from 00-install-prereqs.sh); install them only when
# targeting an actual lab:
#
#   - argocd (VCF build, e.g. v3.0.19-vcf)         — talk to the lab's VKS-provided ArgoCD
#   - vcf    (VCF Consumption CLI, e.g. 9.1.0.x)    — VKS auth / cluster access
#   - vcf plugins (Consumption CLI plugin bundle)   — the `vcf` subcommand plugins
#
# These are Broadcom-LICENSED binaries the operator supplies (entitled download portal or
# the operator's own mirror). Their download URLs live in a GITIGNORED `links.md`
# (operator-local, never committed). Two supply modes, in priority order:
#
#   1) VCF_CLI_SRC_DIR — a directory already holding the downloaded artifacts. Preferred
#      (and the only air-gap-correct path): download them on an internet box / carry them
#      in, then point this at the dir. No network access needed.
#   2) links file — auto-download from the URLs in the operator-local links file (default
#      ./links.md; one artifact name per line and its URL on the next). Internet side only.
#      Direct http(s) URLs use curl; a URL whose scheme needs a dedicated client falls back
#      to a downloader (megatools/megadl/mega-get) if one is installed.
#
# Sudo-free: installs to BIN_DIR (~/.local/bin by default), matching 00-install-prereqs.sh
# (override BIN_DIR to install elsewhere). Usage:
#   scripts/01-install-vcf-clis.sh [all|argocd|vcf|plugins]   (default: all)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

WHAT="${1:-all}"
BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"
LINKS_FILE="${LINKS_FILE:-${REPO_ROOT}/links.md}"
SRC_DIR="${VCF_CLI_SRC_DIR:-}"

# Pinned versions (operator-supplied — these track whatever licensed artifacts you hold;
# Renovate cannot bump a MEGA/entitled download, so they live in .env.example, not renovate).
ARGOCD_VCF_VERSION="${ARGOCD_VCF_VERSION:?set ARGOCD_VCF_VERSION in .env.example (e.g. v3.0.19-vcf)}"
VCF_CLI_VERSION="${VCF_CLI_VERSION:?set VCF_CLI_VERSION in .env.example (e.g. 9.1.0.0.25296329)}"
VCF_PLUGINS_VERSION="${VCF_PLUGINS_VERSION:?set VCF_PLUGINS_VERSION in .env.example (e.g. 9.1.0.0300.25509668)}"

mkdir -p "$BIN_DIR"
case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) log_warn "add $BIN_DIR to your PATH" ;; esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- OS/arch → the tokens used in the artifact filenames ----------------------
os="$(uname -s)"; os="${os,,}"                         # linux | darwin (bash lowercase, no `tr`)
case "$(uname -m)" in
  x86_64|amd64)  go_arch=amd64; vcf_arch=AMD64 ;;
  aarch64|arm64) go_arch=arm64; vcf_arch=ARM64 ;;
  *) die "unsupported machine arch: $(uname -m)" ;;
esac

# Artifact filenames (match the naming in links.md), parameterized by the pinned versions.
argocd_file="argocd-cli-${os}-${go_arch}-${ARGOCD_VCF_VERSION}.gz"
vcf_file="VCF-Consumption-CLI-Linux_${vcf_arch}-${VCF_CLI_VERSION}.tar.gz"
plugins_file="VCF-Consumption-CLI-PluginBundle-Linux_${vcf_arch}-${VCF_PLUGINS_VERSION}.tar.gz"

# --- Helpers -----------------------------------------------------------------

# links_url <filename> — print the URL that follows <filename> in the links file (each
# artifact name is on one line and its URL on the next).
links_url() {
  [ -f "$LINKS_FILE" ] || return 1
  awk -v f="$1" '$0==f {getline; print; exit}' "$LINKS_FILE"
}

# fetch_url <url> <dest> — download <url> to <dest>. Prefer a dedicated downloader when one
# is installed (some entitled links need a scheme-specific client); else curl for direct
# http(s) URLs. The caller validates the result, so a wrong-content download is caught.
fetch_url() {
  local url="$1" dest="$2"
  if   have megatools;  then run megatools dl --path "$(dirname "$dest")" "$url"
  elif have megadl;     then run megadl --path "$(dirname "$dest")" "$url"
  elif have mega-get;   then run mega-get "$url" "$dest"
  else
    case "$url" in
      http://*|https://*) run curl -fSL "$url" -o "$dest" ;;
      *) die "cannot fetch '${url}': no suitable downloader installed — pre-download the artifacts and set VCF_CLI_SRC_DIR=<dir>" ;;
    esac
  fi
}

# ensure_artifact <filename> — guarantee $WORK/<filename> exists, from VCF_CLI_SRC_DIR if
# present, else by downloading its links.md URL. Dies with an actionable message otherwise.
ensure_artifact() {
  local f="$1"
  if [ -n "$SRC_DIR" ] && [ -f "${SRC_DIR}/${f}" ]; then
    log_info "using pre-downloaded ${f} from VCF_CLI_SRC_DIR"
    cp "${SRC_DIR}/${f}" "${WORK}/${f}"
    return 0
  fi
  local url; url="$(links_url "$f" || true)"
  [ -n "$url" ] || die "cannot find '${f}': set VCF_CLI_SRC_DIR to a dir containing it, or add it to ${LINKS_FILE}"
  log_info "fetching ${f}"
  fetch_url "$url" "${WORK}/${f}"
  [ -s "${WORK}/${f}" ] || die "download did not produce ${WORK}/${f}"
  # Validate: the artifact must be a real gzip, not an HTML error page from a bad fetch.
  gzip -t "${WORK}/${f}" 2>/dev/null || die "'${f}' is not a valid gzip (bad/blocked download?) — pre-download it and set VCF_CLI_SRC_DIR"
}

# --- Installers --------------------------------------------------------------

install_argocd_vcf() {
  log_info "installing argocd (VCF ${ARGOCD_VCF_VERSION}, ${os}/${go_arch}) -> ${BIN_DIR}/argocd"
  log_warn "this is the VCF-flavored argocd for a real lab; it shadows any upstream argocd in ${BIN_DIR}"
  ensure_artifact "$argocd_file"
  # The .gz decompresses to the argocd binary; stream it straight to BIN_DIR (name-agnostic).
  gunzip -c "${WORK}/${argocd_file}" > "${BIN_DIR}/argocd"
  chmod 0755 "${BIN_DIR}/argocd"
  "${BIN_DIR}/argocd" version --client || log_warn "argocd installed but 'version --client' failed"
}

install_vcf_cli() {
  [ "$os" = linux ] || die "the VCF Consumption CLI is Linux-only; no ${os} artifact exists"
  log_info "installing vcf (VCF Consumption CLI ${VCF_CLI_VERSION}, linux/${go_arch}) -> ${BIN_DIR}/vcf"
  ensure_artifact "$vcf_file"
  run tar -xf "${WORK}/${vcf_file}" -C "$WORK"
  # The tarball ships a `vcf-cli-linux_<arch>` binary; find it robustly.
  local bin; bin="$(find "$WORK" -maxdepth 2 -type f -name "vcf-cli-linux_${go_arch}" | head -1)"
  [ -n "$bin" ] || die "vcf-cli-linux_${go_arch} not found inside ${vcf_file}"
  install -m 0755 "$bin" "${BIN_DIR}/vcf"
  "${BIN_DIR}/vcf" version || log_warn "vcf installed but 'vcf version' failed"
}

install_vcf_plugins() {
  [ "$os" = linux ] || die "the VCF Consumption CLI plugin bundle is Linux-only; no ${os} artifact exists"
  have vcf || [ -x "${BIN_DIR}/vcf" ] || die "install the vcf CLI first (make install-vcf-cli)"
  local vcf_bin; vcf_bin="$(command -v vcf || echo "${BIN_DIR}/vcf")"
  log_info "installing vcf plugins (bundle ${VCF_PLUGINS_VERSION}, linux/${go_arch})"
  ensure_artifact "$plugins_file"
  local pdir="${WORK}/plugins"
  mkdir -p "$pdir"
  run tar -zxf "${WORK}/${plugins_file}" -C "$pdir"
  # Clear any stale local plugin state so the bundle installs cleanly (matches the vendor steps).
  rm -rf "${HOME}/.local/vcf" "${HOME}/.local/vcf-cli-telemetry"
  run "$vcf_bin" plugin install all --local-source "$pdir"
  "$vcf_bin" plugin list || log_warn "plugins installed but 'vcf plugin list' failed"
}

# --- Dispatch ----------------------------------------------------------------
case "$WHAT" in
  argocd)  install_argocd_vcf ;;
  vcf)     install_vcf_cli ;;
  plugins) install_vcf_plugins ;;
  all)     install_argocd_vcf; install_vcf_cli; install_vcf_plugins ;;
  *) die "usage: $0 [all|argocd|vcf|plugins]" ;;
esac

log_info "VCF/VKS lab CLIs installed to ${BIN_DIR} (ensure it is on your PATH)"
