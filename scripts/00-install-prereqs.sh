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
# findutils (`find`) is not in Photon's base image and is used by the archive-extraction in
# scripts/01-install-vcf-clis.sh (and generally handy); tar/gzip cover the same minimal-image gaps.
#
# DO NOT ASSUME THE BASE SHIPS THE "OBVIOUS" UNIX TOOLS — MEASURED on the bare images:
#   photon:5.0    LACKS awk, openssl, envsubst, git, make   (has bash tar gzip find curl sed grep)
#   ubuntu:26.04  LACKS openssl, envsubst, git, make, curl  (has bash tar gzip find awk sed grep)
# Two of these are load-bearing and were MISSING from this list, so `make deps` on a real bare Photon
# jump box produced a box that could not run the flow:
#   awk      — lib/apps.sh reads apps/registry.tsv with it (EVERY per-app loop), and
#              23-mirror-verify.sh does its images.lock digest lookup with it.
#   envsubst — renders the ${VAR} tokens in every k8s/ manifest (03-check-tools calls it REQUIRED).
# It stayed invisible because the jump-box TEST image (jumpbox/Dockerfile.photon) installs enough
# packages to pull awk in TRANSITIVELY — so `make jumpbox` was green on a box provisioned by accident,
# while an operator following the runbook got a box that dies at mirror-verify.
# `make check-tools` now lists awk explicitly, so a box missing it says so instead of failing later.
case "$(pkg_mgr)" in
  apt-get) GETTEXT_PKG=gettext-base ;;   # envsubst lives in gettext-base on Debian/Ubuntu...
  *)       GETTEXT_PKG=gettext ;;        # ...and in gettext on Photon (tdnf).
esac
# `file` is used by 11-bundle.sh to assert the carried binaries are STATICALLY linked. On Ubuntu it is
# absent from the base image; on Photon /usr/bin/file is a symlink to toybox, whose output the check
# now understands — but installing GNU file REPLACES that symlink (measured: `tdnf install -y file`
# exits 0, installs file-5.47, no conflict with toybox despite both owning /usr/bin/file), which is
# strictly better. Internet-side only: `make bundle` runs on the staging box, never the air-gap one.
pkg_install ca-certificates curl file git jq tar gzip findutils gawk openssl "$GETTEXT_PKG"
# ---- container engine -----------------------------------------------------
# THE INVARIANT, and it is the whole reason this block is shaped the way it is:
#
#     DOCKER IS NEVER *REQUIRED*. It is only ever installed because the operator ASKED for it
#     (CONTAINER_ENGINE=docker). With CONTAINER_ENGINE unset, this script installs PODMAN AND NOTHING
#     ELSE — a jump box that ran `make deps` has no docker daemon, and the air-gap flow (crane + podman)
#     does not want one.
#
# The package list is NOT written here — it comes from `engine_packages` (lib/os.sh), a PURE function
# that prints names and installs nothing. That is what lets scripts/test-container-engine.sh (check 7)
# EXECUTE it and assert the list offline, in both directions, instead of grepping for a docker
# invocation it structurally cannot see.
ENGINE_CHOICE="$(engine_choice)"
if [ "$ENGINE_CHOICE" = docker ]; then
  log_warn "CONTAINER_ENGINE=docker — installing DOCKER instead of podman, because you asked."
  log_warn "  podman remains the default and the recommended engine: it is daemonless, so it needs NO"
  log_warn "  sudo to trust a self-signed registry (--cert-dir, per command). See 'make engine-check'."
else
  log_info "container engine: podman (the default — daemonless, sudo-free registry trust)"
fi
# shellcheck disable=SC2046  # word-splitting the package list is exactly the intent here
pkg_install $(engine_packages "$ENGINE_CHOICE" "$(pkg_mgr)") \
  || log_warn "some ${ENGINE_CHOICE} packages were unavailable via the package manager — run 'make engine-check'"

# Photon ships only a COMMENTED unqualified-search-registries example, so a `podman build` of a
# short-named base fails "short-name … did not resolve". Match only an ACTIVE (uncommented) setting —
# a loose grep matches the commented example and wrongly concludes it is already configured.
if [ "$ENGINE_CHOICE" = podman ] && have podman; then
  if ! grep -qsE '^[[:space:]]*unqualified-search-registries' /etc/containers/registries.conf 2>/dev/null; then
    log_info "configuring podman unqualified-search-registries = [\"docker.io\"]"
    printf 'unqualified-search-registries = ["docker.io"]\n' \
      | $SUDO tee -a /etc/containers/registries.conf >/dev/null \
      || log_warn "could not write /etc/containers/registries.conf — short image names may not resolve"
  fi
fi

# UBUNTU ROOTLESS-DOCKER RELEASE SPLIT (ran-it, 2026-07-14). docker.io is version 29.1.3 on BOTH 24.04
# and 26.04, but only 26.04's deb actually SHIPS the rootless helper — and it hides it in
# /usr/share/docker.io/contrib/, which is OFF PATH. 24.04's deb ships ZERO rootless files.
#
# WE DO NOT ADD A THIRD-PARTY APT REPO TO SOMEONE ELSE'S JUMP BOX. Getting rootless docker on 24.04
# means download.docker.com + a GPG key (docker-ce-rootless-extras), which on a real corporate jump box
# is a proxy-allowlist / security-review item an admin may simply refuse. So we tell the truth instead:
# there, docker is ROOTFUL-ONLY, and rootful docker costs a SUDO PER REGISTRY to trust a self-signed
# Harbor (root-owned /etc/docker/certs.d; the `docker` group grants SOCKET access, not write access to
# /etc). podman costs none, on every box. Photon needs none of this: it puts dockerd-rootless.sh in
# /usr/bin, on PATH, from its own repos.
if [ "$ENGINE_CHOICE" = docker ] && [ "$(pkg_mgr)" = "apt-get" ]; then
  if ! have dockerd-rootless.sh && [ -x /usr/share/docker.io/contrib/dockerd-rootless.sh ]; then
    log_info "linking dockerd-rootless.sh onto PATH (Ubuntu hides it in /usr/share/docker.io/contrib)"
    $SUDO ln -sf /usr/share/docker.io/contrib/dockerd-rootless.sh /usr/local/bin/dockerd-rootless.sh || true
    $SUDO ln -sf /usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh /usr/local/bin/dockerd-rootless-setuptool.sh || true
  fi
  if ! have dockerd-rootless.sh; then
    log_warn "this Ubuntu's docker.io ships NO rootless helper (true on 24.04; 26.04+ ships it)."
    log_warn "  => docker here is ROOTFUL-ONLY, which costs a SUDO PER REGISTRY to trust a self-signed Harbor."
    log_warn "  => podman needs no sudo at all, on any box. Reconsider: unset CONTAINER_ENGINE"
    log_warn "  (We deliberately do NOT add download.docker.com to your apt sources.)"
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
  # KUBECTL_VERSION is always set by load_env from .env.example (the source of truth) — require
  # it rather than carry a second, drift-prone inline default (was the stale `v1.31.4`).
  local v="${KUBECTL_VERSION:?KUBECTL_VERSION unset}"
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
