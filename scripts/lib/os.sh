#!/usr/bin/env bash
# scripts/lib/os.sh — shared library for all vks-cicd scripts.
#
# Provides: OS detection + package-manager abstraction (Ubuntu apt / PhotonOS tdnf),
# structured logging, env loading (.env.example then .env), command assertions,
# and internal-CA trust helpers. Source it; do not execute it.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/lib/os.sh"
#
# shellcheck shell=bash

# Guard against double-sourcing.
[ -n "${__VKS_OS_SH_LOADED:-}" ] && return 0
__VKS_OS_SH_LOADED=1

# Repo root = parent of scripts/. Resolved from THIS file's location so callers
# in scripts/ or scripts/lib/ both work. Fallbacks handle the case where
# BASH_SOURCE is empty (file sourced at the top level of `bash -c`).
if [ -z "${REPO_ROOT:-}" ]; then
  _os_self="${BASH_SOURCE[0]:-}"
  if [ -n "$_os_self" ]; then
    REPO_ROOT="$(cd "$(dirname "$_os_self")/../.." && pwd)"
  fi
  # If that didn't land on a real repo root, fall back to git, then CWD.
  if [ -z "${REPO_ROOT:-}" ] || [ ! -f "${REPO_ROOT}/.env.example" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  unset _os_self
fi
export REPO_ROOT

# ---------------------------------------------------------------------------
# Logging (key=value-ish, timestamped, to stderr so stdout stays pipe-clean)
# ---------------------------------------------------------------------------
_log() {
  # _log LEVEL message...
  local level="$1"; shift
  printf '%s level=%s msg=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}
log_info()  { _log INFO  "$*"; }
log_warn()  { _log WARN  "$*"; }
log_error() { _log ERROR "$*"; }
die()       { _log FATAL "$*"; exit 1; }

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
# Returns the /etc/os-release ID: ubuntu | photon | debian | rhel | ...
os_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}

# Maps the OS to its package manager. Extend here for new distros.
pkg_mgr() {
  case "$(os_id)" in
    ubuntu|debian) printf 'apt-get' ;;
    photon)        printf 'tdnf' ;;
    rhel|centos|fedora|rocky|almalinux) printf 'dnf' ;;
    *)             printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Privilege helper — use sudo only when not already root and sudo exists.
# ---------------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    log_warn "not root and no sudo found; package/CA operations may fail"
  fi
fi
export SUDO

# ---------------------------------------------------------------------------
# Package management
# ---------------------------------------------------------------------------
pkg_refresh() {
  local mgr; mgr="$(pkg_mgr)"
  [ -n "$mgr" ] || die "unsupported OS '$(os_id)': no known package manager"
  log_info "refreshing package metadata via $mgr"
  case "$mgr" in
    apt-get) $SUDO apt-get update -y ;;
    tdnf)    $SUDO tdnf makecache || true ;;
    dnf)     $SUDO dnf makecache -y || true ;;
  esac
}

# pkg_install pkg1 [pkg2 ...] — installs packages using the host's manager.
pkg_install() {
  [ "$#" -gt 0 ] || return 0
  local mgr; mgr="$(pkg_mgr)"
  [ -n "$mgr" ] || die "unsupported OS '$(os_id)': cannot install $*"
  log_info "installing via $mgr: $*"
  case "$mgr" in
    apt-get) DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@" ;;
    tdnf)    $SUDO tdnf install -y "$@" ;;
    dnf)     $SUDO dnf install -y "$@" ;;
  esac
}

# ---------------------------------------------------------------------------
# Command assertions
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# require_cmd cmd [human hint] — fail fast with an actionable message.
require_cmd() {
  local cmd="$1" hint="${2:-run scripts/00-install-prereqs.sh}"
  have "$cmd" || die "required command '$cmd' not found — $hint"
}

# ---------------------------------------------------------------------------
# Environment loading — .env.example (committed defaults) then .env (overrides).
# `set -a` exports everything so child processes (skopeo, kubectl, curl) see it.
# ---------------------------------------------------------------------------
load_env() {
  local example="${REPO_ROOT}/.env.example" override="${REPO_ROOT}/.env"
  [ -f "$example" ] || die ".env.example missing at $example (it is the committed source of truth)"
  set -a
  # shellcheck disable=SC1090
  . "$example"
  # shellcheck disable=SC1090
  [ -f "$override" ] && . "$override"
  set +a
}

# ---------------------------------------------------------------------------
# Internal-CA trust — install a self-signed CA (Harbor/Gitea) into system trust.
# ---------------------------------------------------------------------------
# trust_ca /path/to/ca.crt [friendly-name]
trust_ca() {
  local ca="$1" name="${2:-vks-internal}"
  [ -f "$ca" ] || { log_warn "CA file '$ca' not found — skipping system trust"; return 0; }
  case "$(os_id)" in
    ubuntu|debian)
      $SUDO cp "$ca" "/usr/local/share/ca-certificates/${name}.crt"
      $SUDO update-ca-certificates
      ;;
    photon|rhel|centos|fedora|rocky|almalinux)
      $SUDO cp "$ca" "/etc/pki/ca-trust/source/anchors/${name}.crt"
      $SUDO update-ca-trust extract
      ;;
    *) log_warn "unknown OS '$(os_id)': add $ca to the system trust store manually" ;;
  esac
  log_info "trusted CA $ca as $name"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# dry_run flag: set DRY_RUN=1 to print privileged/mutating commands instead of
# running them. run() honors it.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY_RUN %s\n' "$*" >&2
  else
    "$@"
  fi
}
