#!/usr/bin/env bash
# 18-engine-check.sh — READ-ONLY: does THIS box have what its chosen container engine needs, and what
# will that engine COST you? Changes nothing, contacts no registry, needs no cluster.
#
# This exists because the honest answer to "is docker supported?" is not a boolean — it is a table of
# PRECONDITIONS, and the one that matters to an operator is WHETHER THEY NEED ROOT:
#
#   podman            daemonless -> CA per COMMAND (--cert-dir)                    -> sudo-free, always
#   docker ROOTLESS   daemon reads ~/.config/docker/certs.d/<host>/ca.crt          -> sudo-free
#   docker ROOTFUL    daemon reads /etc/docker/certs.d/<host>/ca.crt  (root-owned) -> A SUDO PER REGISTRY
#
# The `docker` group grants access to the SOCKET. It does not grant write access to /etc. So the sudo on
# the rootful path cannot be engineered away — only disclosed, BEFORE the operator commits to an engine
# and discovers the cost on the lab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/engine.sh
. "${SCRIPT_DIR}/lib/engine.sh"
load_env

ENGINE="$(container_engine)"
printf '\n'
printf 'container engine : %s (%s)\n' "$ENGINE" "$(command -v "$ENGINE" 2>/dev/null || echo 'NOT INSTALLED')"
printf 'OS               : %s (%s)\n' "$(os_id)" "$(pkg_mgr)"

problems=0
note()  { printf '  %s\n' "$*"; }
prob()  { printf '  PROBLEM: %s\n' "$*"; problems=$((problems + 1)); }

if [ "$ENGINE" = podman ]; then
  have podman || prob "podman is not installed — run 'make deps'"
  have crun   || note "crun not found — rootless podman builds may fail (make deps installs it)"
  have newuidmap || prob "newuidmap missing (pkg 'uidmap') — rootless podman cannot map uids. Run 'make deps'."
  grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
    || prob "no /etc/subuid entry for $(id -un) — rootless podman cannot map uids (ask an admin: 'usermod --add-subuids 100000-165535 $(id -un)')"
  printf 'registry TLS     : --cert-dir, PER COMMAND (nothing installed, no daemon)\n'
  printf 'sudo required    : NO  — podman is daemonless. This is why it is the default.\n'
else
  # DOCKER. Classify the daemon; engine_mode FAILS CLOSED, so an unreachable daemon says so rather than
  # being silently assumed rootful (which would make us sudo-write a CA into the operator's /etc).
  if ! docker info >/dev/null 2>&1; then   # docker-ok: only reached when the operator CHOSE docker (container_engine() returned it), so the binary exists by construction
    prob "the docker daemon is not reachable. Start it (rootful: 'sudo systemctl start docker' · rootless:
           'systemctl --user start docker'), or use podman — the default, no daemon, no sudo:
           unset CONTAINER_ENGINE"
    printf '\nengine-check: %d problem(s)\n\n' "$problems"
    exit 1
  fi
  MODE="$(engine_mode docker)"
  printf 'docker mode      : %s\n' "$MODE"
  if [ "$MODE" = docker-rootless ]; then
    printf 'registry TLS     : %s/.config/docker/certs.d/<registry>/ca.crt  (your HOME)\n' "$HOME"
    printf 'sudo required    : NO  — rootless docker matches podman ergonomics exactly.\n'
    have dockerd-rootless.sh || note "dockerd-rootless.sh not on PATH (the daemon is already up, so this is cosmetic)"
  else
    printf 'registry TLS     : /etc/docker/certs.d/<registry>/ca.crt  (ROOT-OWNED)\n'
    printf 'sudo required    : YES — ONE PER REGISTRY. The docker group grants SOCKET access, not write\n'
    printf '                   access to /etc, so this cannot be engineered away.\n'
    if have dockerd-rootless.sh; then
      note "this box CAN run rootless docker (dockerd-rootless.sh is present) — that mode needs no sudo:"
      note "  dockerd-rootless-setuptool.sh install   # then: export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/docker.sock"
    elif [ "$(pkg_mgr)" = apt-get ]; then
      note "no rootless helper on this Ubuntu: 24.04's docker.io ships none (26.04+ does). Getting it means"
      note "  adding download.docker.com — a third-party repo we will NOT add to your jump box. So on THIS"
      note "  box docker is rootful-only. podman needs no sudo at all: unset CONTAINER_ENGINE"
    fi
  fi
  # A CA file that does not exist is NOT proof docker will fail: docker MERGES certs.d with the host
  # SYSTEM STORE, so an operator who ran update-ca-certificates already works. Never gate on the file.
  note "(a missing ca.crt does NOT mean docker will fail — docker merges certs.d with the system trust"
  note " store. The only honest test of trust is a handshake: 'make trust-harbor'.)"
fi

printf '\n'
if [ "$problems" -eq 0 ]; then
  log_info "engine-check: OK — ${ENGINE} has what it needs on this box"
else
  die "engine-check: ${problems} problem(s) above"
fi
