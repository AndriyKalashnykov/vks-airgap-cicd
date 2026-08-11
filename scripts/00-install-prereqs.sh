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
# PREPEND, do not merely warn. MEASURED 2026-08-10 on bare photon:5.0: this script installs mise to
# BIN_DIR and the pinned tools under mise's tree, then its OWN summary loop below reported
# `crane MISSING kubectl MISSING helm MISSING ...` for tools it had just installed — because none of
# them are on PATH in THIS process. The operator then read `make check-tools`, was told
# "Install the toolchain with: make deps", and was in a loop on the first command of the runbook.
# A warning that the reader is not in a position to act on, printed 200 lines above the failure it
# predicts, is not a remedy. The Makefile prepends the same dirs for every RECIPE, but it cannot
# help here: its PATH is computed at parse time, before `mise trust` has run.
case ":$PATH:" in *":$BIN_DIR:"*) : ;; *) PATH="$BIN_DIR:$PATH"; export PATH ;; esac
# ...and the mise install tree, resolving mise by absolute path (it is in BIN_DIR, which was not on
# PATH a moment ago). `mise bin-paths` exits 1 with EMPTY stdout against an untrusted .mise.toml, so
# the guard is on the OUTPUT being non-empty, not on the exit status. No `tr`: photon:5.0 ships no
# coreutils (it arrives only as a side effect of installing podman), so `tr` cannot be assumed here.
if ! have mise && [ -x "${BIN_DIR}/mise" ]; then
  _mp="$( (cd "$REPO_ROOT" && "${BIN_DIR}/mise" bin-paths) 2>/dev/null || true)"
  if [ -n "$_mp" ]; then
    while IFS= read -r _d || [ -n "${_d:-}" ]; do
      [ -n "$_d" ] || continue
      case ":$PATH:" in *":$_d:"*) : ;; *) PATH="$_d:$PATH" ;; esac
    done <<EOF
$_mp
EOF
    export PATH
  fi
  unset _mp _d
fi

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
# strictly better. Internet-side only: `make bundle` runs on the internet box, never the air-gap one.
# `unzip` is here because 30-vks-login.sh's missing-anchor die PRESCRIBES it: vCenter serves the
# Supervisor's VMCA root only as certs/download.zip, and the Supervisor presents just its leaf, so
# there is no way to obtain that anchor without unzipping. A remedy that names a binary we never
# install is the same defect as a remedy that names a target that does not exist.
# `coreutils` is EXPLICIT and load-bearing, not decoration. MEASURED 2026-08-10: photon:5.0 ships no
# `tr`, `sha256sum` or `paste`, and this list did not install it — it arrived only as a TRANSITIVE
# side effect of installing podman/docker, pinned by nothing. 19 call sites across scripts/lib depend
# on `tr` alone (state.sh, mirror.sh, tls.sh, istio.sh, os.sh), and 11-bundle.sh's integrity check
# needs sha256sum. A box provisioned without the engine packages passed every earlier check and then
# printed `tr: command not found` from lib/state.sh on the operator's very first command.
pkg_install ca-certificates coreutils curl file git jq tar gzip unzip findutils gawk openssl "$GETTEXT_PKG"

# MEASURED on a fresh Photon 5.0 VM 2026-08-11, off the broken guest's own disk:
#     MESSAGE=OpenSSL version mismatch. Built against 30000080, you have 30500070
# (0x30000080 = OpenSSL 3.0.8, 0x30500070 = 3.5.7). The line above upgrades openssl-libs, and Photon
# 5.0 GA ships openssh-9.1p1 built against 3.0.8. OpenSSH BEFORE 9.4 hard-fails when the runtime
# OpenSSL MINOR differs from the compile-time one -- ssh_compatible_openssl() masks 0xfff0000f, and
# the major-only relaxation first appears in V_9_4_P1. It aborts in seed_rng() at entropy.c:103,
# reached from sshd.c long BEFORE the banner is written.
#
# Why it presents as a mystery rather than a service failure: sshd.socket (Accept=yes) is enabled on
# this image, so SYSTEMD owns the listener and does the accept(). Port 22 stays LISTEN no matter how
# dead sshd is; every connection spawns a fresh sshd -i from disk that dies instantly. The server
# accepted and closed WITHOUT READING, so the client's already-sent identification string sits unread
# and the kernel answers RST -- hence `Connection reset by peer` mid-kex, permanently, with a healthy
# looking open port. It cost this project two rebuilt VMs and several wrong diagnoses.
#
# openssh-socket is NOT optional, and it is a SECOND defect with the same symptom. MEASURED on a
# fresh VM: upgrading openssh ALONE fixes the version guard (sshd -t rc=0, OpenSSH_10.4p1/OpenSSL
# 3.5.7) and then DELETES sshd.socket and sshd@.service, which moved to the openssh-socket
# subpackage that tdnf does not pull on upgrade. systemd keeps the in-memory listener `active`, so
# port 22 still accepts and then has no template unit to spawn -- `Connection reset by peer` mid-kex
# again, from a completely different cause. With both packages: all four units survive, versions
# match, and the SSH session stays up through the 205s upgrade.
#
# 10.4p1 is in photon-updates (verified), well past the 9.4 boundary. tdnf only -- on apt the package
# is openssh-client/-server and Ubuntu does not have the defect.
if [ "$(pkg_mgr)" = tdnf ]; then pkg_install openssh openssh-socket; fi
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

  # ── ROOTLESS PODMAN PREREQUISITES ─────────────────────────────────────────────────────────────
  # MEASURED on a fresh Photon OS 5.0 VM 2026-08-11: kernel.unprivileged_userns_clone=0 AND
  # /etc/subuid ABSENT — so podman, this repo's DEFAULT engine, could not build at all. Before
  # engine-check was wired into preflight the failure surfaced ~528s into `make install-all`, at
  # builder-image: "user namespaces are not enabled in /proc/sys/kernel/unprivileged_userns_clone".
  #
  # ⚠️ NO CONTAINER TEST CAN SEE THIS. `kernel.*` sysctls are not namespaced, so a Photon CONTAINER
  # reads the HOST's value (measured 1 on an Ubuntu host, never Photon's 0), and
  # jumpbox/Dockerfile.photon pre-writes /etc/subuid. Only a real VM observes either.
  #
  # ROOT NEEDS NEITHER. Running as root and granting "root" a subuid range PERMANENTLY POISONS the
  # block for the real operator: run 1 as root writes root:100000:65536, run 2 as the operator then
  # collides with it and refuses. And docs/scenario-1.md says "Prefix with sudo if you are not root",
  # so that path is normal, not exotic. Skip the whole stanza. (ran-it, adversary round 2026-08-11)
  if [ "$(id -u)" -eq 0 ]; then
    log_info "running as root — rootless-podman subuid/userns setup does not apply"
  else

  userns_file=/proc/sys/kernel/unprivileged_userns_clone
  userns_drop=/etc/sysctl.d/99-vks-userns.conf
  if [ -e "$userns_file" ]; then
    # PERSISTENCE IS A SEPARATE GOAL FROM THE LIVE VALUE. Gating only on "reads 0" means a box where
    # someone ran `sysctl -w` is skipped, no drop-in is written, and the next reboot reproduces the
    # original 20-minute builder-image failure. So: write the drop-in whenever it is missing, and
    # reload only when the live value is actually 0.
    if [ ! -f "$userns_drop" ]; then
      $SUDO mkdir -p /etc/sysctl.d 2>/dev/null || true   # absent on a bare photon image (measured)
      printf 'kernel.unprivileged_userns_clone=1\n' | $SUDO tee "$userns_drop" >/dev/null \
        || log_warn "could not write ${userns_drop} — the setting will not survive a reboot"
    fi
    if [ "$(cat "$userns_file" 2>/dev/null || echo 1)" = 0 ]; then
      log_warn "kernel.unprivileged_userns_clone=0 — rootless podman cannot create a user namespace."
      log_warn "  Enabling it SYSTEM-WIDE (every account on this box). Photon ships this off by policy."
      log_warn "  To undo:  sudo rm ${userns_drop} && sudo sysctl -w kernel.unprivileged_userns_clone=0"
      # The NARROW form first (an explicit file), --system only as a fallback: --system reloads EVERY
      # config file, which on a box whose live values have drifted from its files has side effects we
      # did not ask for. Never BARE `sysctl -p` — with no argument it reads only /etc/sysctl.conf.
      $SUDO sysctl -p "$userns_drop" >/dev/null 2>&1 \
        || $SUDO sysctl --system >/dev/null 2>&1 \
        || $SUDO sh -c "echo 1 > $userns_file" 2>/dev/null || true
      # Read the VALUE back. An exit code proves nothing here.
      if [ "$(cat "$userns_file" 2>/dev/null || echo 0)" = 1 ]; then
        log_info "  unprivileged_userns_clone is now 1"
      else
        log_warn "  STILL 0 — rootless podman will fail. Apply it by hand, then 'make engine-check'."
      fi
    fi
  fi

  # subuid/subgid. Checked and repaired INDEPENDENTLY: the two writes below can succeed and fail
  # separately, and inferring subgid from subuid means a half-written box is skipped forever.
  # getsubids consults NSS (a directory-joined box may hold ranges no file carries) — but it is
  # MISSING on both bare photon:5.0 and ubuntu:26.04, and nothing in engine_packages installs it, so
  # the file fallback is the path that actually runs on the OS this fix exists for.
  subid_user="$(id -un)"
  _has_subid() {  # $1=uid|gid  -> 0 if the user already has a range
    case "$1" in
      uid) have getsubids && getsubids    "$subid_user" >/dev/null 2>&1 && return 0
           grep -qs "^${subid_user}:" /etc/subuid 2>/dev/null ;;
      gid) have getsubids && getsubids -g "$subid_user" >/dev/null 2>&1 && return 0
           grep -qs "^${subid_user}:" /etc/subgid 2>/dev/null ;;
    esac
  }
  # NEXT FREE BLOCK, never a hardcoded 100000. MEASURED: ubuntu:26.04 ships
  # `ubuntu:100000:65536` and /etc/login.defs SUB_UID_MIN=100000 — i.e. the block everyone
  # allocates first. Hardcoding it makes a COLLISION the common case, and refusing then leaves
  # rootless podman broken for an operator who did nothing wrong.
  _next_subid() {  # $1=file -> first free start, or empty if we cannot tell
    [ -f "$1" ] || { printf '100000'; return 0; }
    awk -F: 'NF>=3 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { e=$2+$3; if (e>m) m=e }
             END { print (m < 100000 ? 100000 : m) }' "$1" 2>/dev/null
  }
  _grant_subid() {  # $1=file  $2=uid|gid  -> echoes 1 if it wrote
    local f="$1" start
    _has_subid "$2" && { log_info "subuid/subgid: ${subid_user} already has a ${2} range"; return 1; }
    # FAIL CLOSED. `x="$(awk ... 2>/dev/null)"` maps a missing awk, an awk error and an unreadable
    # file to the SAME empty string as "no clash" — so an empty result must REFUSE, not proceed.
    start="$(_next_subid "$f")"
    case "$start" in ''|*[!0-9]*)
      log_warn "cannot determine a free subid range from ${f} — REFUSING to write one."
      log_warn "  Add a non-overlapping range by hand, then re-run 'make deps'."
      return 1 ;;
    esac
    log_info "granting ${subid_user} ${start}:65536 in ${f}"
    log_warn "  To undo:  sudo sed -i '/^${subid_user}:${start}:65536\$/d' ${f}"
    printf '%s:%s:65536\n' "$subid_user" "$start" | $SUDO tee -a "$f" >/dev/null || return 1
    # 0644, ALWAYS. MEASURED 2026-08-11: `sudo tee` CREATES the file with root's umask -> 0600, and
    # podman runs as the OPERATOR, so it cannot read it:
    #   level=error msg="cannot find UID/GID for user vks: open /etc/subuid: permission denied"
    #   level=warning msg="Using rootless single mapping into the namespace."
    #            0       1000          1
    # Everything else — the range, newuidmap (04755), `podman system migrate` — was correct and
    # irrelevant; the build still died with `requested 0:42 for /etc/shadow`. Every distro that ships
    # these files ships them world-readable: they are public id-allocation metadata, not secrets.
    $SUDO chmod 0644 "$f" || log_warn "could not chmod 0644 ${f} — podman may not be able to read it"
    return 0
  }
  subid_wrote=0
  _grant_subid /etc/subuid uid && subid_wrote=1
  _grant_subid /etc/subgid gid && subid_wrote=1
  # ONLY when we actually wrote. podman keeps a pause process pinning the OLD mapping and migrate is
  # what clears it — but it also STOPS the user's running containers, so running it after a FAILED
  # write (or a no-op) costs the operator their containers for a change that did not happen.
  if [ "$subid_wrote" = 1 ]; then
    log_warn "  running 'podman system migrate' — this STOPS running containers (images are kept)"
    podman system migrate >/dev/null 2>&1 || log_warn "  'podman system migrate' failed — run it by hand"
  fi

  # VERIFY BY HANDSHAKE, not by reading a file back: the thing that must be true for a build that
  # chowns is a WIDE uid_map (the measured failure was `requested 0:42 for /etc/shadow`, a MAPPING
  # failure). The else branch matters most — it is the state you reach when a write failed.
  if uidmap="$(podman unshare cat /proc/self/uid_map 2>&1)"; then
    if printf '%s\n' "$uidmap" | awk 'NF>=3 && $3+0 >= 65536 {f=1} END{exit !f}'; then
      log_info "rootless podman: uid_map carries a 65536-wide range — builds can chown"
    else
      log_warn "rootless podman: uid_map has NO wide range — a build that chowns will still fail."
      log_warn "  Run 'make engine-check' for the remedy."
    fi
  else
    log_warn "rootless podman is NOT usable yet — 'podman unshare' failed:"
    log_warn "  ${uidmap}"
  fi
  unset userns_file userns_drop subid_user subid_wrote uidmap
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
# The remedy must NOT be "run make deps" — the operator is reading this BECAUSE they just ran it.
# Naming the command they just completed successfully is the loop this script's PATH prepend (top of
# file) exists to break; if anything is still MISSING here it is a genuine install failure, and the
# only thing left for the reader to do is make the tools reachable from their own INTERACTIVE shell,
# which `make` cannot do for them.
log_info "done."
log_info "make targets resolve these automatically. For YOUR OWN shell, put them on PATH:"
log_info "    export PATH=\"$BIN_DIR:\$PATH\"       # this shell, right now"
# Print the line for the shell they ACTUALLY use. `>> ~/.bashrc  # or ~/.zshrc` makes the reader
# resolve an ambiguity we can resolve for them, and it is simply wrong for a zsh or fish operator.
_rc="$(shell_rc_file)"; _act="$(shell_activate_line)"
if [ -n "$_rc" ] && [ -n "$_act" ]; then
  log_info "    make shell-init                    # permanently — appends to ${_rc} for your $(basename "$SHELL")"
else
  log_warn "    could not identify your shell from SHELL='${SHELL:-unset}' — add mise activation to your"
  log_warn "    interactive shell's rc file by hand: https://mise.jdx.dev/getting-started.html"
fi
unset _rc _act
