#!/usr/bin/env bash
# lib/engine.sh — make the CONTAINER ENGINE's registry-TLS trust work, and RECORD what it cost.
#
# THE QUESTION THIS LIBRARY EXISTS TO ANSWER HONESTLY
# --------------------------------------------------
# "Is docker supportable as an alternative to podman?" The answer is not a boolean — it is a table of
# PRECONDITIONS, because the three engine modes differ in exactly one thing that matters to an operator:
# WHETHER THEY NEED ROOT.
#
#   podman            daemonless -> CA per COMMAND (--cert-dir)                      -> sudo-free, always
#   docker ROOTLESS   daemon reads ~/.config/docker/certs.d/<host>/ca.crt            -> sudo-free
#   docker ROOTFUL    daemon reads /etc/docker/certs.d/<host>/ca.crt  (root-owned)   -> SUDO, unavoidable
#
# The `docker` GROUP grants access to the SOCKET. It does NOT grant write access to /etc. So the sudo on
# the rootful path cannot be engineered away — it can only be measured and disclosed. We therefore RECORD
# every sudo this library performs (engine_sudo_calls) instead of asserting "no sudo needed", because the
# jump-box images give `vks` NOPASSWD:ALL — meaning a leg can sudo SILENTLY and a naive harness would
# report "sudo-free" for a path that is not.
#
# TWO FACTS THAT ARE EASY TO GET WRONG (both source-verified; see CLAUDE.md "engine facts"):
#   * docker MERGES certs.d with the HOST SYSTEM STORE (moby: loadTLSConfig seeds RootCAs from
#     SystemCertPool() and APPENDS). So a MISSING ca.crt does NOT mean docker will fail — an operator who
#     ran `update-ca-certificates` already works. Never gate on the FILE's existence; gate on a real TLS
#     handshake (engine_login_probe).
#   * certs.d is read PER REQUEST -> a CA drop-in needs NO daemon restart. The SYSTEM STORE does (Go caches
#     the pool once per process). We use certs.d precisely so no restart is needed.

# How many times WE escalated. The harness prints this, and it IS the claim — so it must survive a
# SUBSHELL. It did not, and the harness lied on its very first real run:
#
#     CA_METHOD="$(engine_trust_ca ...)"     # <- command substitution = SUBSHELL
#
# engine_trust_ca sudo'd (the operator typed a password), incremented a shell variable IN THE SUBSHELL,
# and the parent printed `sudo=NO`. A global cannot cross a subshell. A FILE can — so the counter is a
# file. (rules/common/coding-style.md says exactly this. Writing the rule does not stop you writing the
# bug; only a mechanism does.)
ENGINE_SUDO_COUNT_FILE="${ENGINE_SUDO_COUNT_FILE:-$(mktemp -t engine-sudo.XXXXXX)}"
export ENGINE_SUDO_COUNT_FILE
# Do NOT clobber a counter a parent already started: a matrix driver sources this, then calls 16 as a
# CHILD — which would re-source engine.sh and zero the parent's count.
[ -s "$ENGINE_SUDO_COUNT_FILE" ] || printf '0' > "$ENGINE_SUDO_COUNT_FILE"

engine_sudo_calls() { cat "$ENGINE_SUDO_COUNT_FILE" 2>/dev/null || printf '0'; }

# engine_sudo — every escalation goes through here so it is COUNTED, never silent. Works in a subshell.
engine_sudo() {
  # Count ACTUAL ESCALATIONS. Already root (the jump-box containers run as root) => no escalation
  # happened, and reporting sudo=YES there would be as much a lie as the sudo=NO we started with.
  if [ "$(id -u)" -eq 0 ]; then "$@"; return $?; fi
  local n; n="$(engine_sudo_calls)"
  printf '%s' "$(( n + 1 ))" > "$ENGINE_SUDO_COUNT_FILE"
  sudo "$@"
}

# engine_mode <engine> — "podman" | "docker-rootless" | "docker-rootful".
#
# `docker info` is asked for the field DIRECTLY (--format), never piped to `grep -q`: under
# `set -o pipefail` a grep that exits early SIGPIPEs docker and the pipeline reports failure. (This repo
# has been bitten by that exact shape; see rules/common/coding-style.md.)
engine_mode() {
  local eng="${1:?engine}"
  [ "$eng" = podman ] && { printf 'podman'; return 0; }
  local sec
  sec="$(docker info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>/dev/null || true)"   # docker-ok: only reached when the OPERATOR chose CONTAINER_ENGINE=docker; the air-gap flow is podman + crane.
  case "$sec" in
    *rootless*) printf 'docker-rootless' ;;
    *)          printf 'docker-rootful'  ;;
  esac
}

# engine_certs_d_dir <mode> <registry> — where THAT mode's daemon looks for the CA.
# The directory is keyed on the registry reference EXACTLY as the client writes it: host, plus the port
# ONLY when non-default, no scheme, no trailing slash. A scheme or a slash here yields a path that can
# never exist and an error message that is confidently wrong — so the caller must pass a bare host[:port].
engine_certs_d_dir() {
  case "${1:?mode}" in
    docker-rootless) printf '%s/.config/docker/certs.d/%s' "$HOME" "${2:?registry}" ;;
    docker-rootful)  printf '/etc/docker/certs.d/%s' "${2:?registry}" ;;
    *) return 1 ;;
  esac
}

# engine_trust_ca <engine> <registry> <ca-file> — make THIS engine trust the self-signed registry.
# Echoes the method used (for the precondition row). Podman needs no install at all — the caller passes
# --cert-dir per command, which is why podman is sudo-free by construction.
engine_trust_ca() {
  local eng="${1:?}" reg="${2:?}" ca="${3:-}" mode dir
  mode="$(engine_mode "$eng")"
  if [ "$mode" = podman ]; then
    printf 'podman --cert-dir (per-command, no install)'
    return 0
  fi
  [ -n "$ca" ] && [ -f "$ca" ] || { log_error "no CA file at '${ca:-<unset>}' — cannot wire docker trust"; return 1; }
  dir="$(engine_certs_d_dir "$mode" "$reg")"
  if [ "$mode" = docker-rootless ]; then
    mkdir -p "$dir" && install -m 0644 "$ca" "${dir}/ca.crt"        # $HOME — no sudo
  else
    engine_sudo install -D -m 0644 "$ca" "${dir}/ca.crt"            # /etc — root-owned, sudo COUNTED
  fi
  printf '%s/ca.crt' "$dir"
}

# engine_login_probe <engine> <registry> <user> <cert-dir-args...> — a REAL trust operation, cheap, first.
#
# `login` performs the actual TLS handshake AND authenticates, against whichever store THIS engine reads —
# so it cannot false-fire the way a filesystem check does (that guard was retracted; docker merges certs.d
# with the system store, so a missing file proves nothing).
#
# It CAPTURES STDERR and branches the advice on the REAL error. The previous version discarded stderr and
# branched on the ENGINE NAME, so a wrong password, an unwired LoadBalancer, a dead daemon and a missing IP
# SAN all printed "install the CA" — a guard confidently telling you to fix the wrong thing.
#
# The password arrives on STDIN, never argv.
engine_login_probe() {
  local eng="${1:?}" reg="${2:?}" user="${3:?}"; shift 3
  local err rc=0
  err="$(printf '%s' "${HARBOR_PASSWORD:-}" | "$eng" login "$@" --username "$user" --password-stdin "$reg" 2>&1 >/dev/null)" || rc=$?
  [ $rc -eq 0 ] && { log_info "trust + auth OK ($eng -> $reg)"; return 0; }

  log_error "$eng cannot log in to $reg. The engine said:"
  printf '%s\n' "$err" | sed 's/^/    /' >&2
  case "$err" in
    *"doesn't contain any IP SANs"*|*"is not valid for"*|*"IP SAN"*)
      log_error "  -> the CERT is wrong, not the trust: since Go 1.15 a leaf with no matching SAN is"
      log_error "     REJECTED EVEN WITH A TRUSTED CA (Go 1.17 removed the escape hatch). Installing the"
      log_error "     CA will NOT help. Re-mint the cert with a SAN for '$reg' (06-install-harbor.sh)." ;;
    *x509*|*"unknown authority"*|*"certificate signed by"*)
      log_error "  -> the CA is not trusted by THIS engine. Wire it: 'make engine-trust-check' installs it"
      log_error "     (podman: --cert-dir, no sudo · docker rootless: ~/.config/docker/certs.d · docker"
      log_error "     rootful: /etc/docker/certs.d, needs sudo)." ;;
    *401*|*[Uu]nauthorized*|*"incorrect username or password"*)
      log_error "  -> TLS is FINE; the CREDENTIALS are wrong. Check HARBOR_USERNAME/HARBOR_PASSWORD." ;;
    *"Cannot connect to the Docker daemon"*|*"daemon is not running"*)
      log_error "  -> no docker daemon. Start it, or use podman (CONTAINER_ENGINE=podman)." ;;
    *"connection refused"*|*"i/o timeout"*|*"no route to host"*)
      log_error "  -> the registry is not reachable. On KinD the LoadBalancer takes 5-60s to wire AFTER the"
      log_error "     IP is assigned (assigned != routable) — this is usually a WAIT, not a config error." ;;
    *)
      log_error "  -> unclassified. The engine's own message is above; trust it over any advice here." ;;
  esac
  return 1
}
