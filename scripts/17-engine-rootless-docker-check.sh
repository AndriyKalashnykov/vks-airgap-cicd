#!/usr/bin/env bash
# 17-engine-rootless-docker-check.sh — bring up a ROOTLESS dockerd, then hand off to 16-engine-trust-check.
#
# THIS IS A DAEMON-LIFECYCLE WRAPPER, NOT A SECOND IMPLEMENTATION.
# The first version of this file re-implemented login/pull/build/push AND PRINTED `sudo=NO` AS A LITERAL —
# it asserted the one thing it existed to measure. That is the same failure as the subshell-lost counter it
# was written after: the sudo column IS the deliverable, so it must be MEASURED. Now 16 does all the
# measuring (engine_mode -> docker-rootless -> $HOME/.config/docker/certs.d, no escalation -> sudo=NO comes
# from the COUNTER, and would say YES the day that path ever needed root).
#
# WHY ROOTLESS DOCKER DECIDES THE DOCKER QUESTION
# podman is sudo-free by construction. Rootful docker ALWAYS costs a sudo (root-owned /etc/docker/certs.d;
# the `docker` group grants SOCKET access, not write access to /etc). So rootless is the ONLY docker mode
# that matches podman's ergonomics.
#
# WHY ON THE HOST — and a CORRECTION, because the claim that used to sit here was FALSE.
#
# This header used to say rootless-docker-in-a-container "will not start on an AppArmor-restricting host"
# (Ubuntu 23.10+ sets kernel.apparmor_restrict_unprivileged_userns=1). RAN IT, 2026-07-14, on exactly such
# a host: it STARTS — with AND without `--security-opt apparmor=rootlesskit`. dockerd came up as `vks`
# (uid 1001), SecurityOptions reported `name=rootless`, DockerRootDir landed under $HOME, and it built and
# ran an image.
#
# The mechanism the old text described is real but was mis-scoped: Ubuntu grants userns via a profile
# ATTACHED BY HOST PATH (/etc/apparmor.d/rootlesskit -> /usr/bin/rootlesskit); inside a container that
# binary is a different file, the profile does not attach, the process is `unconfined` — and unconfined is
# what restrict=1 denies. That kills an UNPRIVILEGED dind-rootless. Our jump-box harness runs
# `--privileged`, which grants CAP_SYS_ADMIN, so the userns is permitted regardless and the AppArmor path
# never gates it. "I tried three flags and none worked" is not a proof of impossibility — none of those
# flags acted on the mechanism. (See rules: name the mechanism, then ask which thing you tried acts on it.)
#
# So dind-rootless IS available, and `make jumpbox-matrix` uses it for the docker legs on both OSes.
# THIS script stays HOST-NATIVE anyway, because host-native is the STRONGER test: a real uid, a real
# rootlesskit, and no outer privilege to borrow.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

[ "$(id -u)" -ne 0 ] || die "run this as a NORMAL USER — the entire point is that rootless docker needs no root"
require_cmd dockerd-rootless.sh "docker's rootless extras (docker-ce-rootless-extras)"   # docker-ok: this script EXISTS to validate rootless DOCKER; it is a developer/validation tool, never part of the air-gap operator flow (which is podman + crane).
require_cmd newuidmap "apt install uidmap  (Ubuntu's apt DROPS it under --no-install-recommends)"
grep -q "^$(id -un):" /etc/subuid || die "no /etc/subuid entry for $(id -un) — rootless docker cannot map uids"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCK="${XDG_RUNTIME_DIR}/docker.sock"   # docker-ok: the ROOTLESS daemon's own socket, in $XDG_RUNTIME_DIR — this validation tool exists to test rootless docker; it is never on the air-gap operator path.

# ISOLATE the docker CLI config: `docker login` otherwise writes an auth entry into the operator's SHARED
# ~/.docker/config.json (rootful and rootless read the same $HOME). We do not touch their file.
DOCKER_CONFIG_DIR="$(mktemp -d)"
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"
export DOCKER_HOST="unix://${SOCK}"

DAEMON_PGID=""
LOG="$(mktemp -t rootless-dockerd.XXXXXX.log)"

# CLEANUP BY PROCESS GROUP, VERIFIED BY ARTIFACT — never `pkill -f`.
# The old version ran `pkill -f 'rootlesskit.*dockerd'`, which (a) kills by PATTERN, so it would have
# killed a rootless daemon the OPERATOR was running on a different socket, along with every container on
# it, and (b) kills the PARENT, orphaning the dockerd/slirp4netns children. This repo's own rules say
# exactly that (git-workflow.md: kill the process GROUP, then verify by ARTIFACT, never a process grep).
# shellcheck disable=SC2329  # invoked via `trap cleanup EXIT` below; shellcheck cannot see that.
cleanup() {
  if [ -n "$DAEMON_PGID" ]; then
    kill -- -"$DAEMON_PGID" 2>/dev/null || true
    for _ in $(seq 1 20); do [ -S "$SOCK" ] || break; sleep 0.5; done
    [ -S "$SOCK" ] && log_warn "the rootless daemon's socket is still present at $SOCK — check by hand"
  fi
  rm -rf "$LOG" "$DOCKER_CONFIG_DIR"
}
trap cleanup EXIT

if docker info >/dev/null 2>&1; then   # docker-ok: probing the ROOTLESS daemon this validation tool manages.
  log_info "a rootless dockerd is already running at ${DOCKER_HOST} — using it (we will NOT stop it)"
else
  log_info "starting a rootless dockerd as $(id -un) (uid $(id -u)) — no sudo, no root"
  setsid dockerd-rootless.sh > "$LOG" 2>&1 &       # docker-ok: see above — rootless-docker validation only.
  DAEMON_PGID="$!"
  deadline=$(( SECONDS + ${READY_TIMEOUT_SECONDS:-90} ))
  until docker info >/dev/null 2>&1; do            # docker-ok: readiness probe for the daemon we just started.
    [ "$SECONDS" -lt "$deadline" ] || { tail -15 "$LOG" >&2; die "rootless dockerd did not come up (log above)"; }
    sleep 2
  done
fi

# --- ANTI-FAKE: prove we are NOT talking to the rootful daemon ---------------------------------------
uid="$(id -u)"
sec="$(docker info --format '{{range .SecurityOptions}}{{.}} {{end}}')"   # docker-ok: validation tool.
log_info "uid=${uid}  DOCKER_HOST=${DOCKER_HOST}  SecurityOptions=${sec}"
case "$DOCKER_HOST" in *"/run/user/${uid}/"*) ;; *) die "FAKE: DOCKER_HOST is not this user's own socket";; esac
case "$sec" in *rootless*) ;; *) die "FAKE: docker info does not report 'rootless' — this is the ROOTFUL daemon";; esac
log_info "ASSERT-ROOTLESS: PASS (uid=${uid}, own socket, SecurityOptions contains 'rootless')"

# --- HAND OFF: 16 does ALL the measuring (CA method, the sudo COUNTER, the login-error branching) ------
#
# RUN IT AS A CHILD, NOT `exec`. `exec` REPLACES THE PROCESS IMAGE — so the `trap cleanup EXIT` above
# NEVER FIRES, and the rootless dockerd we started is LEAKED on the operator's box, every run. That is
# the very thing the setsid/PGID cleanup was written to prevent. `exec` and `trap … EXIT` are mutually
# exclusive; a child + explicit exit code keeps both.
log_info "handing off to 16-engine-trust-check.sh with CONTAINER_ENGINE=docker (rootless)"
CONTAINER_ENGINE=docker "${SCRIPT_DIR}/16-engine-trust-check.sh"; rc=$?
exit $rc
