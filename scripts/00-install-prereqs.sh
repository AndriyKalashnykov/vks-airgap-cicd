#!/usr/bin/env bash
# 00-install-prereqs.sh — install the jump-box toolchain on Ubuntu or PhotonOS.
#
# Installs OS packages (git, jq, curl, ca-certificates, tar, gzip) via the
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
# NOTE: skopeo is intentionally NOT installed. The image mirror uses `crane` (a static Go
# binary provided by mise via .mise.toml) — skopeo has no static binary and isn't packaged
# on Photon OS 5, so it can't be relied on cross-distro. See scripts/lib/mirror.sh.
pkg_refresh
pkg_install ca-certificates curl git jq tar gzip
# podman is the default container engine (build/push the Maven builder, render
# diagrams); docker also works if already present. Best-effort — some minimal
# images lack it in the default repos.
pkg_install podman || log_warn "podman unavailable via package manager; install podman or docker manually"
# Photon's podman ships WITHOUT crun (its default OCI runtime, not pulled as a dep) and
# WITHOUT a default unqualified-search-registries, so a `podman build` of a short-named base
# image (maven:...-temurin — the offline Maven builder) fails with "crun not found" or
# "short-name ... did not resolve". Install crun + point bare names at docker.io. Both are
# best-effort + idempotent, and no-ops on distros (e.g. Ubuntu) that already ship them.
if have podman; then
  have crun || pkg_install crun || log_warn "crun unavailable — rootless podman builds may fail (install crun manually)"
  # Match only an ACTIVE (uncommented) setting — Photon's default registries.conf ships a
  # commented `# unqualified-search-registries = […]` example that a loose grep would match.
  if ! grep -qsE '^[[:space:]]*unqualified-search-registries' /etc/containers/registries.conf 2>/dev/null; then
    log_info "configuring podman unqualified-search-registries = [\"docker.io\"]"
    printf 'unqualified-search-registries = ["docker.io"]\n' \
      | $SUDO tee -a /etc/containers/registries.conf >/dev/null \
      || log_warn "could not write /etc/containers/registries.conf — short image names may not resolve"
  fi
fi
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
# go_arch: Go-style (amd64/arm64) — used by argocd + kubectl asset names.
# uname_arch: uname -m style (x86_64/aarch64) — used by the tkn (Tekton CLI) asset names.
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) go_arch=amd64; uname_arch=x86_64 ;;
  aarch64|arm64) go_arch=arm64; uname_arch=aarch64 ;;
  *) die "unsupported CPU arch '$arch'" ;;
esac

install_tkn() {
  have tkn && { log_info "tkn present: $(tkn version --client 2>/dev/null | head -1)"; return 0; }
  local v="${TKN_VERSION:?TKN_VERSION unset}" url tmp
  # tkn assets use uname -m arch names (x86_64/aarch64), NOT Go arch (amd64/arm64).
  url="https://github.com/tektoncd/cli/releases/download/v${v}/tkn_${v}_Linux_${uname_arch}.tar.gz"
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

# kubectl: normally provided by mise (.mise.toml). Install a pinned build only if
# it's still missing (mise absent, or not on PATH).
install_kubectl() {
  have kubectl && { log_info "kubectl present: $(command -v kubectl)"; return 0; }
  local v="${KUBECTL_VERSION:-v1.31.4}"
  log_info "kubectl not found — downloading ${v}"
  curl -fsSL "https://dl.k8s.io/release/${v}/bin/linux/${go_arch}/kubectl" -o "${BIN_DIR}/kubectl"
  chmod 0755 "${BIN_DIR}/kubectl"
}

install_tkn
install_argocd
install_kubectl

# ---- Summary --------------------------------------------------------------
log_info "prereqs installed. Versions:"
for c in crane git jq kubectl helm kustomize yq tkn argocd; do
  if have "$c"; then printf '  %-9s %s\n' "$c" "$(command -v "$c")" >&2; else log_warn "  $c MISSING"; fi
done
log_info "done. If any tool is MISSING, ensure mise ran (make deps) and $BIN_DIR is on PATH."
