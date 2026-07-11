#!/usr/bin/env bash
# bootstrap.sh — one-command jump-box bootstrap for the vks-airgap-cicd demo.
#
#   curl -fsSL https://raw.githubusercontent.com/AndriyKalashnykov/vks-airgap-cicd/main/bootstrap-jumpbox.sh | bash
#
# Automates the manual "bootstrap a bare jump box" steps: OS-gate -> ensure base
# packages (git/curl/make/…) -> ensure mise -> clone this repo -> `make deps` ->
# verify the toolchain and print a report. Idempotent: re-running skips what is
# already present.
#
# DUAL-HOMED only (needs internet). A fully air-gapped host uses the carried bundle
# (see the sneakernet flow in the README), not this script. It installs only the OPEN
# toolchain — it NEVER downloads the entitled/licensed VCF CLIs (those stay
# operator-supplied via VCF_CLI_SRC_DIR; see `make install-vcf-clis`).
#
# Overrides (env): REF (git ref to check out, default main), DIR (clone dir),
# REPO_URL (https clone URL).
#
# The whole body is wrapped in main() called on the LAST line, so a truncated
# download (dropped connection mid-pipe) runs NOTHING partial.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/AndriyKalashnykov/vks-airgap-cicd.git}"
REF="${REF:-main}"                     # pin to a tag/SHA via REF=… for reproducibility
DIR="${DIR:-vks-airgap-cicd}"
BASE_PKGS="git curl ca-certificates make tar"   # the minimum to clone + run make deps

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; }
die()  { printf '  \033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- (0) OS detection + supported-OS gate (self-contained; runs before the clone) ---
os_gate() {
  local id="" ver=""
  if [ -r /etc/os-release ]; then . /etc/os-release; id="${ID:-}"; ver="${VERSION_ID:-}"; fi
  case "$id" in
    ubuntu|debian) PKG=apt-get; ok "Detected ${id} ${ver} — supported (apt)";;
    photon)        PKG=tdnf;    ok "Detected ${id} ${ver} — supported (tdnf)";;
    "")            die "cannot detect OS (/etc/os-release missing) — supported: Ubuntu/Debian, Photon OS 5";;
    *)             die "Detected '${id}' — UNSUPPORTED. This bootstrap supports Ubuntu/Debian (apt) and Photon OS 5 (tdnf) only.";;
  esac
  # NOTE: an `[ … ] && SUDO=sudo` here would return non-zero as root (id 0), and since main
  # calls os_gate as a standalone command under `set -e`, that would exit the script right
  # after the gate. Use an if so os_gate always returns 0.
  SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
}

pkg_refresh() {
  case "$PKG" in
    apt-get) $SUDO apt-get update -y >/dev/null 2>&1 || warn "apt-get update had warnings";;
    tdnf)    if $SUDO tdnf clean all >/dev/null 2>&1 && $SUDO tdnf makecache >/dev/null 2>&1; then :; else warn "tdnf makecache had warnings"; fi;;
  esac
}
pkg_install() {  # pkg_install <pkg...>
  case "$PKG" in
    apt-get) DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@" >/dev/null 2>&1;;
    tdnf)    $SUDO tdnf install -y "$@" >/dev/null 2>&1;;
  esac
}

# --- (1) base packages: check -> install-if-missing -> verify ---
ensure_base() {
  say "Base packages"
  pkg_refresh
  local p missing=()
  for p in $BASE_PKGS; do
    # the command name matches the pkg name for this set (git/curl/make/tar); ca-certificates has no cmd
    case "$p" in ca-certificates) if [ -d /etc/ssl/certs ]; then ok "ca-certificates present"; continue; fi;; esac
    if have "$p"; then ok "$p present"; else missing+=("$p"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "installing: ${missing[*]}"
    pkg_install "${missing[@]}" || die "failed to install: ${missing[*]}"
    for p in "${missing[@]}"; do
      case "$p" in ca-certificates) continue;; esac
      if have "$p"; then ok "$p installed + verified"; else die "$p still missing after install"; fi
    done
  fi
}

# --- (2) mise: ensure present, on PATH ---
ensure_mise() {
  say "mise (version manager)"
  export PATH="$HOME/.local/bin:$PATH"
  if have mise; then ok "mise present ($(mise --version 2>/dev/null | head -1))"; return; fi
  say "installing mise (https://mise.run)"
  curl -fsSL https://mise.run | sh >/dev/null 2>&1 || die "mise install failed"
  if have mise; then ok "mise installed + verified ($(mise --version 2>/dev/null | head -1))"
  else die "mise not on PATH after install (expected in ~/.local/bin)"; fi
}

# --- (3) clone or update the repo at REF ---
ensure_repo() {
  say "Repository ($REPO_URL @ $REF)"
  if [ -d "$DIR/.git" ]; then
    ok "$DIR exists — updating to $REF"
    git -C "$DIR" fetch --depth 1 origin "$REF" >/dev/null 2>&1 || die "git fetch failed"
    git -C "$DIR" checkout -q FETCH_HEAD 2>/dev/null || git -C "$DIR" checkout -q "$REF" || die "git checkout $REF failed"
  else
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$DIR" >/dev/null 2>&1 \
      || git clone "$REPO_URL" "$DIR" >/dev/null 2>&1 \
      || die "git clone failed"
    ok "cloned into $DIR"
  fi
}

# --- (4) make deps (mise install + scripts/00-install-prereqs.sh) ---
run_deps() {
  say "make deps (toolchain + rootless-podman prereqs)"
  ( cd "$DIR" && make deps ) || die "'make deps' failed"
  ok "make deps completed"
}

# --- (5) verify the toolchain + report ---
verify_report() {
  say "Toolchain verification"
  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  local tools="git mise kubectl helm kustomize jq yq crane tkn argocd make" t v miss=0
  printf '  %-10s %-8s %s\n' "TOOL" "STATUS" "VERSION"
  printf '  %-10s %-8s %s\n' "----" "------" "-------"
  for t in $tools; do
    if have "$t"; then
      # Tools differ: some support `--version`, others `version` (kubectl/helm/crane/tkn/
      # argocd/kustomize). Try both; `|| true` so a probe failure never trips set -e.
      v="$({ "$t" --version 2>/dev/null || "$t" version 2>/dev/null || true; } | head -1 | cut -c1-48)"
      if [ -z "$v" ]; then v="$(command -v "$t")"; fi
      printf '  %-10s \033[1;32m%-8s\033[0m %s\n' "$t" "OK" "$v"
    else
      printf '  %-10s \033[1;31m%-8s\033[0m %s\n' "$t" "MISSING" "-"; miss=$((miss+1))
    fi
  done
  # container engine: podman preferred, docker fallback
  if have podman; then ok "container engine: podman"; elif have docker; then ok "container engine: docker"; else warn "no container engine (podman/docker) — builder-image + KinD e2e need one"; fi
  echo
  if [ "$miss" -gt 0 ]; then
    warn "$miss tool(s) MISSING — ensure ~/.local/bin and mise shims are on your PATH, then re-run 'make deps'"
  else
    ok "all core tools present"
  fi
}

main() {
  say "vks-airgap-cicd jump-box bootstrap (dual-homed)"
  os_gate
  ensure_base
  ensure_mise
  ensure_repo
  run_deps
  verify_report
  say "Done. Next:  cd $DIR  &&  see the README 'Quick Start' / 'Run against a real VKS lab'."
}

main "$@"
