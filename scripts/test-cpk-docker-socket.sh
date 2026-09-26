#!/usr/bin/env bash
# ci-tier: fast — offline; uname and docker are stubbed.
#
# test-cpk-docker-socket.sh — the socket 05-kind-up.sh mounts into cloud-provider-kind is resolved by
# the DAEMON. On Linux that is a host path (rootful /var/run/docker.sock, or the rootless socket). On
# macOS the daemon runs in a VM (Colima, Docker Desktop), so the mount source must be the VM's
# /var/run/docker.sock — and a host-side `-S` test is meaningless there, which used to make kind-up
# die on a Mac whose daemon was fine (B740 A3).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# run <uname> <docker-info-rc> [VAR=VAL ...] -> "rc|stdout"
run() {
  local T; T="$(mktemp -d)"; mkdir -p "$T/bin"
  printf '#!/bin/sh\necho %s\n' "$1" > "$T/bin/uname"
  printf '#!/bin/sh\nexit %s\n' "$2" > "$T/bin/docker"
  chmod +x "$T/bin/uname" "$T/bin/docker"
  shift 2
  local out rc
  out="$(env -u DOCKER_HOST -u XDG_RUNTIME_DIR -u REPO_ROOT PATH="$T/bin:$PATH" "$@" bash -c '
    . scripts/lib/os.sh >/dev/null 2>&1
    cpk_docker_socket 2>/dev/null' )"; rc=$?
  rm -rf "$T"
  printf '%s|%s' "$rc" "$out"
}

# a real unix socket on this box, for the Linux rootless case
SOCKDIR="$(mktemp -d)"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCKDIR/docker.sock"
trap 'rm -rf "$SOCKDIR"' EXIT

got="$(run Darwin 0 DOCKER_HOST=unix:///Users/x/.colima/default/docker.sock)"
[ "$got" = "0|/var/run/docker.sock" ] && ok "macOS + a daemon that answers -> the VM's /var/run/docker.sock (not the Mac-side path)" \
  || bad "macOS: got '$got', want '0|/var/run/docker.sock'"
got="$(run Darwin 1)"
[ "${got%%|*}" != 0 ] && ok "macOS + a daemon that does NOT answer -> refuses" || bad "macOS dead daemon: got '$got'"
got="$(run Linux 0 XDG_RUNTIME_DIR="$SOCKDIR")"
[ "$got" = "0|$SOCKDIR/docker.sock" ] && ok "Linux rootless (XDG_RUNTIME_DIR socket) -> that socket" \
  || bad "Linux rootless: got '$got'"
got="$(run Linux 0 DOCKER_HOST="unix://$SOCKDIR/docker.sock")"
[ "$got" = "0|$SOCKDIR/docker.sock" ] && ok "Linux DOCKER_HOST=unix://... -> that socket" || bad "Linux DOCKER_HOST: got '$got'"
got="$(run Linux 0 DOCKER_HOST="unix://$SOCKDIR/missing.sock")"
[ "${got%%|*}" != 0 ] && ok "Linux + a socket path that does not exist -> refuses (the -S check still applies on Linux)" \
  || bad "Linux missing socket: got '$got'"

[ "$fail" -eq 0 ] && echo "cpk-docker-socket: ALL PASS" || { echo "cpk-docker-socket: FAILED"; exit 1; }
