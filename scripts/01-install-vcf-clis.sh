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
#   1) Broadcom support portal (preferred) — an authenticated download TOKEN in the URL path
#      (https://dl.broadcom.com/<TOKEN>/PROD/COMP/.../<file>). The links file holds the
#      token-LESS `PROD/COMP/.../<file>` path per artifact; the token comes from
#      BROADCOM_DOWNLOAD_TOKEN / BROADCOM_TOKEN_FILE (default ./token.md) and is fed to curl
#      via a `-K` config file so it never appears in argv/ps.
#   2) links file with a direct http(s) URL (a mirror) — curl (same secret-safe -K path).
#      A MEGA URL also works but needs megatools/megadl/mega-get (curl can't decrypt a #key).
#   3) VCF_CLI_SRC_DIR — a directory already holding the downloaded artifacts. The
#      air-gap-correct path: download on an internet box / carry them in. No network needed.
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

# Broadcom support-portal download: the token goes in the URL PATH
# (https://dl.broadcom.com/<TOKEN>/PROD/COMP/.../<file>). The token is a CREDENTIAL —
# read from BROADCOM_DOWNLOAD_TOKEN, else a token FILE (BROADCOM_TOKEN_FILE, default
# ./token.md if present) — and NEVER placed in argv/ps (the assembled URL, which embeds
# the token, is written to a `curl -K` config file). No auth header/creds needed.
BROADCOM_DL_BASE="${BROADCOM_DL_BASE:-https://dl.broadcom.com}"

bcom_token() {
  if [ -n "${BROADCOM_DOWNLOAD_TOKEN:-}" ]; then printf '%s' "$BROADCOM_DOWNLOAD_TOKEN"; return 0; fi
  local f="${BROADCOM_TOKEN_FILE:-${REPO_ROOT}/token.md}"
  [ -f "$f" ] && tr -d '\n\r' < "$f"
}

# curl_via_config <url> <dest> — curl <url> to <dest> via a `-K` config file so a token
# embedded in the URL never appears in argv/ps. The logged command is `curl -K <cfg>`.
curl_via_config() {
  local url="$1" dest="$2" cfg rc
  umask 077; cfg="$(mktemp)"
  { printf 'url = "%s"\n' "$url"; printf 'output = "%s"\n' "$dest"; printf 'fail\nlocation\nsilent\nshow-error\n'; } > "$cfg"
  curl -K "$cfg"; rc=$?
  rm -f "$cfg"
  return "$rc"
}

# fetch_url <url> <dest> — download <url> to <dest>. Routing by URL shape:
#   - a Broadcom path (PROD/COMP/...) -> assemble https://dl.broadcom.com/<TOKEN>/<path>, curl (secret-safe)
#   - a direct http(s) URL (portal/mirror; may embed a token) -> curl (secret-safe)
#   - a MEGA URL (mega.nz) -> megatools/megadl/mega-get (curl can't decrypt the #key)
# The caller validates the result (gzip -t), so a wrong-content download is caught.
fetch_url() {
  local url="$1" dest="$2" tok
  case "$url" in
    PROD/*|/PROD/*|COMP/*)
      tok="$(bcom_token)"
      [ -n "$tok" ] || die "Broadcom path '${url}' needs a token — set BROADCOM_DOWNLOAD_TOKEN or BROADCOM_TOKEN_FILE (a token.md)"
      curl_via_config "${BROADCOM_DL_BASE}/${tok}/${url#/}" "$dest" ;;
    *mega.nz*|*mega.co.nz*)
      if   have megatools;  then run megatools dl --path "$(dirname "$dest")" "$url"
      elif have megadl;     then run megadl --path "$(dirname "$dest")" "$url"
      elif have mega-get;   then run mega-get "$url" "$dest"
      else die "MEGA URL needs megatools/megadl/mega-get — install one, or pre-download to VCF_CLI_SRC_DIR"; fi ;;
    http://*|https://*)
      curl_via_config "$url" "$dest" ;;
    *) die "cannot fetch '${url}': not a Broadcom PROD/... path, a direct http(s) URL, or a MEGA URL — pre-download to VCF_CLI_SRC_DIR" ;;
  esac
}

# resolve_archive <cli> — locate/download the archive for <cli>, echo its local path.
# Source priority (first that applies): a per-CLI direct URL env var (a Broadcom-portal
# PRE-SIGNED URL — self-signed, time-limited — or a mirror) -> VCF_CLI_SRC_DIR (exact name
# OR a version glob, so a portal `...-Binaries-...` bundle is found too) -> the links file
# (by the versioned filename OR the bare <cli> key). Validates the result is a real gzip.
resolve_archive() {
  local cli="$1" url="" glob="" name="" out u m
  case "$cli" in
    argocd)  url="${ARGOCD_VCF_URL:-}"; glob="argocd-cli-*${ARGOCD_VCF_VERSION}*";                    name="$argocd_file" ;;
    vcf)     url="${VCF_CLI_URL:-}";     glob="VCF-Consumption-CLI-*${VCF_CLI_VERSION}*.tar.gz";        name="$vcf_file" ;;
    plugins) url="${VCF_PLUGINS_URL:-}"; glob="VCF-Consumption-CLI-*Plugin*${VCF_PLUGINS_VERSION}*.tar.gz"; name="$plugins_file" ;;
    *) die "resolve_archive: unknown cli '$cli'" ;;
  esac
  out="${WORK}/${cli}-archive"
  if [ -n "$url" ]; then
    log_info "fetching ${cli} archive from its configured URL"
    fetch_url "$url" "$out"
  elif [ -n "$SRC_DIR" ] && [ -f "${SRC_DIR}/${name}" ]; then
    log_info "using pre-downloaded ${name} from VCF_CLI_SRC_DIR"; cp "${SRC_DIR}/${name}" "$out"
  elif [ -n "$SRC_DIR" ] && m="$(find "$SRC_DIR" -maxdepth 1 -name "$glob" 2>/dev/null | head -1)" && [ -n "$m" ]; then
    log_info "using pre-downloaded $(basename "$m") from VCF_CLI_SRC_DIR"; cp "$m" "$out"
  else
    u="$(links_url "$name" || true)"; [ -n "$u" ] || u="$(links_url "$cli" || true)"
    [ -n "$u" ] || die "no source for ${cli}: set ${cli}_URL (portal pre-signed URL / mirror), VCF_CLI_SRC_DIR, or a ${LINKS_FILE} entry"
    log_info "fetching ${cli} archive"; fetch_url "$u" "$out"
  fi
  [ -s "$out" ] || die "download did not produce an archive for ${cli}"
  gzip -t "$out" 2>/dev/null || die "the ${cli} archive is not a valid gzip (bad/blocked/expired download?) — re-generate the URL or use VCF_CLI_SRC_DIR"
  printf '%s' "$out"
}

# --- Installers --------------------------------------------------------------

install_argocd_vcf() {
  log_info "installing argocd (VCF ${ARGOCD_VCF_VERSION}, ${os}/${go_arch}) -> ${BIN_DIR}/argocd"
  log_warn "this is the VCF-flavored argocd for a real lab; it shadows any upstream argocd in ${BIN_DIR}"
  local ar; ar="$(resolve_archive argocd)"
  # The argocd artifact is either a bare .gz of the binary (MEGA) or a tarball/bundle (portal).
  if tar -tzf "$ar" >/dev/null 2>&1; then
    local d bin; d="$(mktemp -d)"; tar -xzf "$ar" -C "$d"
    bin="$(find "$d" -type f \( -name "argocd-cli-${os}-${go_arch}*" -o -name "argocd-${os}-${go_arch}" -o -name argocd \) | head -1)"
    [ -n "$bin" ] || { rm -rf "$d"; die "argocd binary not found inside the archive"; }
    install -m 0755 "$bin" "${BIN_DIR}/argocd"; rm -rf "$d"
  else
    gunzip -c "$ar" > "${BIN_DIR}/argocd"; chmod 0755 "${BIN_DIR}/argocd"
  fi
  "${BIN_DIR}/argocd" version --client || log_warn "argocd installed but 'version --client' failed"
}

install_vcf_cli() {
  [ "$os" = linux ] || die "the VCF Consumption CLI is Linux-only for this installer (no ${os} target)"
  log_info "installing vcf (VCF Consumption CLI ${VCF_CLI_VERSION}, ${os}/${go_arch}) -> ${BIN_DIR}/vcf"
  local ar d bin; ar="$(resolve_archive vcf)"
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
  local ar pdir src; ar="$(resolve_archive plugins)"
  pdir="${WORK}/plugins"; mkdir -p "$pdir"; tar -xzf "$ar" -C "$pdir"
  # `vcf plugin install all --local-source` wants the dir holding the plugin binaries. A
  # multi-arch bundle nests them under <os>/<arch>/...; point at that subdir when present.
  src="$pdir"
  local archdir; archdir="$(find "$pdir" -type d -path "*/${os}/${go_arch}" | head -1)"
  [ -n "$archdir" ] && src="$archdir"
  # Clear any stale local plugin state so the bundle installs cleanly (matches the vendor steps).
  rm -rf "${HOME}/.local/vcf" "${HOME}/.local/vcf-cli-telemetry"
  run "$vcf_bin" plugin install all --local-source "$src"
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
