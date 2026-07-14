#!/usr/bin/env bash
# 19-trust-harbor.sh — make THIS engine trust the self-signed Harbor, and PROVE it with a handshake.
#
# This is the target the docs point at instead of explaining docker's daemon TLS model at the operator.
# The operator does not need to know where their engine reads a CA from; they need one command.
#
# IT PROVES TRUST BY PERFORMING A TRUST OPERATION — never by checking that a file exists.
# A guard that died when /etc/docker/certs.d/<host>/ca.crt was absent was shipped here once and RETRACTED:
# docker on Linux MERGES certs.d with the host SYSTEM STORE (moby: loadTLSConfig seeds RootCAs from
# x509.SystemCertPool() and APPENDS), so an operator who had run `update-ca-certificates` had a WORKING
# docker and the guard hard-blocked them. It was wrong in the other direction too — a stale ca.crt PASSED
# the file check and then died at the push 20 minutes later. `login` does the real TLS handshake AND the
# auth, against whichever store this engine actually reads, and it cannot false-fire.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/engine.sh
. "${SCRIPT_DIR}/lib/engine.sh"
load_env

: "${HARBOR_URL:?HARBOR_URL is not set — run 'make install-harbor' (KinD) or set it in .env (real lab)}"
: "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never on argv)}"

ENGINE="$(container_engine)"
MODE="$(engine_mode "$ENGINE")"
CA="${HARBOR_CA_FILE:-}"
log_info "engine=${ENGINE} mode=${MODE} registry=${HARBOR_URL}"

CERT_ARGS=()
if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
  [ "$ENGINE" = podman ] || die "HARBOR_INSECURE=1 (plain HTTP) is PODMAN-ONLY.
  A CA drop-in never enables plain HTTP — docker would need an 'insecure-registries' entry in
  /etc/docker/daemon.json plus a daemon RELOAD (root). Use podman, or serve Harbor over TLS."
  log_warn "HARBOR_INSECURE=1 — plain HTTP, no CA to install. Verifying the login only."
  CERT_ARGS=(--tls-verify=false)
else
  CA_METHOD="$(engine_trust_ca "$ENGINE" "$HARBOR_URL" "$CA")" \
    || die "could not wire the CA. Is HARBOR_CA_FILE set? ('make fetch-harbor-ca' re-fetches it)"
  log_info "CA method: ${CA_METHOD}"
  if [ "$ENGINE" = podman ]; then
    # podman takes the CA per COMMAND — nothing was installed, so build the dir the caller will pass.
    CERTD="$(mktemp -d)"; trap 'rm -rf "$CERTD"' EXIT
    [ -n "$CA" ] && [ -f "$CA" ] && cp "$CA" "${CERTD}/ca.crt"
    CERT_ARGS=(--tls-verify=true --cert-dir "$CERTD")
  fi
fi

# THE PROOF. Not "the file is there" — a handshake.
engine_login_probe "$ENGINE" "$HARBOR_URL" "$HARBOR_USERNAME" "${CERT_ARGS[@]}" \
  || die "trust NOT established (the engine's own error is above — trust it over any advice)."

N_SUDO="$(engine_sudo_calls)"
printf '\n'
if ! engine_sudo_measurable; then
  printf 'TRUSTED: %s -> %s   (sudo cost: UNMEASURABLE — you are root; re-run as a normal user to see it)\n' "$ENGINE" "$HARBOR_URL"
elif [ "$N_SUDO" -gt 0 ]; then
  printf 'TRUSTED: %s -> %s   (cost: %s sudo call(s) — rootful docker needs root to write /etc/docker/certs.d)\n' "$ENGINE" "$HARBOR_URL" "$N_SUDO"
  printf '         podman would have cost NONE. To switch: unset CONTAINER_ENGINE\n'
else
  printf 'TRUSTED: %s -> %s   (cost: NO sudo)\n' "$ENGINE" "$HARBOR_URL"
fi
printf '\n'
