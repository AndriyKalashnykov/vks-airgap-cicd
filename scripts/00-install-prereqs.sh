#!/usr/bin/env bash
# 00-install-prereqs.sh — install the jump-box toolchain on Ubuntu or PhotonOS.
#
# Installs OS packages (skopeo, git, jq, curl, ca-certificates, tar, gzip) via the
# host package manager, then ensures the CLIs mise does not cover (tkn, argocd) are
# present at pinned versions. mise (if installed) provides java/maven/kubectl/helm/
# kustomize/yq — run `mise install` first (the `deps` Make target does).
#
# INTERNET side only. On a sneakernet air-gapped host, the same binaries are
# delivered by the transferred bundle (scripts/20-bundle-load.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"
mkdir -p "$BIN_DIR"
case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) log_warn "add $BIN_DIR to your PATH" ;; esac

log_info "detected OS: $(os_id) (pkg manager: $(pkg_mgr))"

# ---- OS packages ----------------------------------------------------------
pkg_refresh
# skopeo package name is consistent across apt (Ubuntu 20.10+) and tdnf (Photon).
pkg_install ca-certificates curl git jq tar gzip skopeo
# The shellcheck linter is best-effort (dev/lint convenience; not required at runtime).
pkg_install shellcheck || log_warn "shellcheck unavailable via package manager; lint will skip it"

# ---- mise-provided tools (java/maven/kubectl/helm/kustomize/yq) ------------
if have mise; then
  log_info "mise present — ensuring toolchain from .mise.toml"
  ( cd "$REPO_ROOT" && mise install )
else
  log_warn "mise not found — kubectl/helm/kustomize/yq must be on PATH already or installed manually"
fi

# ---- Pinned CLIs not covered by mise: tkn, argocd -------------------------
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) go_arch=amd64 ;;
  aarch64|arm64) go_arch=arm64 ;;
  *) die "unsupported CPU arch '$arch'" ;;
esac

install_tkn() {
  have tkn && { log_info "tkn present: $(tkn version --client 2>/dev/null | head -1)"; return 0; }
  local v="${TKN_VERSION:?TKN_VERSION unset}" url tmp
  url="https://github.com/tektoncd/cli/releases/download/v${v}/tkn_${v}_Linux_${go_arch}.tar.gz"
  tmp="$(mktemp -d)"
  log_info "downloading tkn ${v}"
  curl -fsSL "$url" -o "${tmp}/tkn.tgz"
  tar -xzf "${tmp}/tkn.tgz" -C "$tmp" tkn
  install -m 0755 "${tmp}/tkn" "${BIN_DIR}/tkn"
  rm -rf "$tmp"
}

install_argocd() {
  have argocd && { log_info "argocd present: $(argocd version --client --short 2>/dev/null | head -1)"; return 0; }
  local v="${ARGOCD_CLI_VERSION:?ARGOCD_CLI_VERSION unset}" url
  url="https://github.com/argoproj/argo-cd/releases/download/${v}/argocd-linux-${go_arch}"
  log_info "downloading argocd ${v}"
  curl -fsSL "$url" -o "${BIN_DIR}/argocd"
  chmod 0755 "${BIN_DIR}/argocd"
}

install_tkn
install_argocd

# ---- Summary --------------------------------------------------------------
log_info "prereqs installed. Versions:"
for c in skopeo git jq kubectl helm kustomize yq tkn argocd; do
  if have "$c"; then printf '  %-9s %s\n' "$c" "$(command -v "$c")" >&2; else log_warn "  $c MISSING"; fi
done
log_info "done. If any tool is MISSING, ensure mise ran (make deps) and $BIN_DIR is on PATH."
