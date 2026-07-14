#!/usr/bin/env bash
# 17-engine-rootless-docker-check.sh — is ROOTLESS DOCKER viable against our self-signed Harbor?
#
# WHY THIS LEG DECIDES THE DOCKER QUESTION
# ---------------------------------------
# podman is sudo-free BY CONSTRUCTION (daemonless; CA passed per command). Rootful docker ALWAYS costs a
# sudo: its daemon reads root-owned /etc/docker/certs.d, and the `docker` GROUP grants SOCKET access, NOT
# write access to /etc — that cannot be engineered away. So ROOTLESS DOCKER is the ONLY configuration in
# which docker matches podman's ergonomics. If it works, "docker is supported" is a real statement. If it
# does not, "docker is supported" means "docker costs a password prompt per Harbor" — and on KinD the LB IP
# changes on EVERY `kind-up`, so that is a prompt every cluster, plus a litter of dead certs.d/172.18.0.x/.
#
# WE RUN IT ON THE HOST, NOT IN dind — AND THAT IS THE STRONGER TEST
# `docker:dind-rootless` CANNOT START on this host:
#     [rootlesskit:parent] error: failed to start the child: fork/exec /proc/self/exe: operation not permitted
# because Ubuntu 23.10+ sets `kernel.apparmor_restrict_unprivileged_userns=1`, which blocks unprivileged
# user-namespace creation INSIDE a container. `--privileged`, `--security-opt apparmor=unconfined` and
# `seccomp=unconfined` do NOT lift it (all three tried, all three failed). That is an artefact of NESTING,
# and it says nothing about rootless docker on a real machine.
#
# Running it on the host instead is not a workaround — it is more faithful: a real user (uid != 0), a real
# rootless daemon, no outer privilege to accidentally borrow. The dind route's own failure mode was that
# inside a --privileged container you are ROOT, so a CA drop-in needs no sudo and the harness would "prove"
# a sudo-free ROOTFUL path that exists for no operator.
#
# THE FAKE THIS GUARDS AGAINST
# A harness can "prove rootless" while actually talking to the ROOTFUL daemon on /var/run/docker.sock. So
# before measuring anything we ASSERT: uid != 0 · DOCKER_HOST is the user's own socket · `docker info`
# SecurityOptions CONTAINS `rootless`. Without those three, a green here is worthless.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${HARBOR_URL:?run 'make install-harbor' first}"
: "${HARBOR_PASSWORD:?}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
PROJECT="${HARBOR_INFRA_PROJECT:-cicd}"
CA="${HARBOR_CA_FILE:?}"
[ -f "$CA" ] || die "no CA at $CA"

[ "$(id -u)" -ne 0 ] || die "run this as a NORMAL USER — the whole point is that rootless docker needs no root"
require_cmd dockerd-rootless.sh "install docker's rootless extras (docker-ce-rootless-extras), or 'apt install uidmap slirp4netns fuse-overlayfs'"
require_cmd newuidmap "apt install uidmap  (Ubuntu's apt DROPS this under --no-install-recommends — a documented trap)"
grep -q "^$(id -un):" /etc/subuid || die "no /etc/subuid entry for $(id -un) — rootless docker cannot map uids"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
LOG="$(mktemp -t rootless-dockerd.XXXXXX.log)"

# Do NOT kill a rootless daemon the operator was already running.
STARTED_BY_US=0
cleanup() {
  [ "$STARTED_BY_US" = 1 ] && { pkill -f 'rootlesskit.*dockerd' >/dev/null 2>&1 || true; }
  rm -f "$LOG"
}
trap cleanup EXIT

if docker info >/dev/null 2>&1; then
  log_info "a rootless dockerd is already running at ${DOCKER_HOST} — using it (will NOT stop it)"
else
  log_info "starting a rootless dockerd as $(id -un) (uid $(id -u)) — no sudo, no root"
  dockerd-rootless.sh > "$LOG" 2>&1 &
  STARTED_BY_US=1
  deadline=$(( SECONDS + ${READY_TIMEOUT_SECONDS:-90} ))
  until docker info >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || { tail -15 "$LOG" >&2; die "rootless dockerd did not come up (see its log above)"; }
    sleep 2
  done
fi

# --- THE ANTI-FAKE ASSERTIONS -----------------------------------------------------------------------
uid="$(id -u)"
sec="$(docker info --format '{{range .SecurityOptions}}{{.}} {{end}}')"
log_info "uid=${uid}  DOCKER_HOST=${DOCKER_HOST}  SecurityOptions=${sec}"
case "$DOCKER_HOST" in *"/run/user/${uid}/"*) ;; *) die "FAKE: DOCKER_HOST is not this user's own socket — that is the ROOTFUL daemon";; esac
case "$sec" in *rootless*) ;; *) die "FAKE: docker info does NOT report 'rootless' — this is the ROOTFUL daemon";; esac
log_info "ASSERT-ROOTLESS: PASS (uid=${uid}, own socket, SecurityOptions contains 'rootless')"

# --- THE CA: a rootless daemon reads $HOME/.config/docker/certs.d — NO SUDO --------------------------
CERTD="${HOME}/.config/docker/certs.d/${HARBOR_URL}"
log_info "installing the Harbor CA at ${CERTD}/ca.crt  (in \$HOME — no sudo, no /etc)"
mkdir -p "$CERTD"
install -m 0644 "$CA" "${CERTD}/ca.crt"      # deliberately NOT engine_sudo: if this needed root, the leg fails
# certs.d is read PER REQUEST — no daemon restart. The login below proves that empirically.

# --- login -> pull -> build -> push -> pull-back (the engine's entire registry-TLS surface) ----------
BASE="${HARBOR_URL}/${PROJECT}/maven:3.9-eclipse-temurin-25"
TAG="${HARBOR_URL}/${PROJECT}/engine-probe:docker-rootless-$(date -u +%Y%m%d%H%M%S)"

log_info "login ${HARBOR_URL} (password on stdin, never argv)"
printf '%s' "$HARBOR_PASSWORD" | docker login --username "$HARBOR_USERNAME" --password-stdin "$HARBOR_URL" >/dev/null
log_info "pull  ${BASE}"; docker pull "$BASE" >/dev/null
WORK="$(mktemp -d)"; printf 'FROM %s\nRUN true\n' "$BASE" > "${WORK}/Dockerfile"
log_info "build ${TAG}"; docker build -t "$TAG" "$WORK" >/dev/null; rm -rf "$WORK"
log_info "push  ${TAG}"; docker push "$TAG" >/dev/null
docker rmi "$TAG" >/dev/null 2>&1 || true
log_info "pull-back ${TAG}"; docker pull "$TAG" >/dev/null

printf '\n'
printf 'LEG %-16s engine=%-6s mode=%-16s CA=%-42s sudo=%s\n' \
  "host" "docker" "docker-rootless" "~/.config/docker/certs.d/<host>/ca.crt" "NO"
printf '\n'
log_info "ROOTLESS DOCKER WORKS: login+pull+build+push+pull-back against our self-signed Harbor, with NO sudo."
log_info "  Preconditions it needed: uidmap(newuidmap) + /etc/subuid + docker's rootless extras."
log_info "  NOT proven here: rootless docker on the Photon/Ubuntu JUMP-BOX IMAGES (needs those same packages;"
log_info "  Ubuntu's apt DROPS uidmap/slirp4netns/passt under --no-install-recommends), and NOT proven that"
log_info "  kind works on a rootless daemon (05-kind-up.sh hardcodes /var/run/docker.sock — see the decision doc)."
