#!/usr/bin/env bash
# 16-engine-trust-check.sh — does THIS container engine actually work against our self-signed Harbor,
# and WHAT DID IT COST? Prints one PRECONDITION ROW. That row is the claim; anything broader is a lie.
#
# WHY THIS EXISTS INSTEAD OF MATRIXING `make builder-image`
# --------------------------------------------------------
# The engine's ENTIRE registry-TLS surface is: login + pull-from-Harbor + build + push-to-Harbor + pull-back.
# `builder-image` also bakes a full Maven dependency cache (~20 min) — which proves nothing about the
# engine (that is `mvn` hitting Maven Central INSIDE the build). Matrixing it would cost ~2h to test a
# property provable in ~60s. So: same trust path, 2-line Dockerfile, six legs in minutes.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM
#   * Nothing about a REAL LAB's Harbor: that is an FQDN (possibly WITH A PORT -> certs.d/<host>:<port>/,
#     a naming rule we have never exercised), a corporate CA that may ALREADY be in the system store, and a
#     scoped ROBOT rather than admin. This proves the mechanism, not the lab.
#   * Nothing about `HARBOR_INSECURE=1`, which skips TLS entirely and is PODMAN-ONLY (docker needs a daemon
#     `insecure-registries` entry + a reload). An insecure leg tests no trust at all — it is excluded, not
#     counted.
#   * Nothing about kind: `make e2e-kind` requires DOCKER regardless of CONTAINER_ENGINE. The honest
#     inverse of "podman is the default" is: a podman-only box cannot run the local KinD e2e.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/engine.sh
. "${SCRIPT_DIR}/lib/engine.sh"
load_env

: "${HARBOR_URL:?run 'make install-harbor' first}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD (never on argv)}"
HARBOR_USERNAME="${HARBOR_USERNAME:-admin}"
PROJECT="${HARBOR_INFRA_PROJECT:-cicd}"

ENGINE="$(container_engine)"
MODE="$(engine_mode "$ENGINE")"
require_cmd "$ENGINE"

if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
  [ "$ENGINE" = podman ] || die "HARBOR_INSECURE=1 is PODMAN-ONLY. docker needs an 'insecure-registries' entry in daemon.json + a daemon reload (root). Use podman, or serve Harbor over TLS."
  log_warn "HARBOR_INSECURE=1 — TLS is SKIPPED, so this run proves NOTHING about trust. Excluded from the matrix."
fi

# THE COLD-START ASSERTION. The host's ~/.docker/config.json carries logins to PREVIOUS Harbor LB IPs — a
# leg could otherwise "pass" on a leftover credential and prove nothing. Same for a CA already installed.
# We do not delete the operator's state; we REPORT it, so a green cannot be mistaken for a fresh green.
if [ -f "${HOME}/.docker/config.json" ] && grep -q "\"${HARBOR_URL}\"" "${HOME}/.docker/config.json" 2>/dev/null; then
  log_warn "NOTE: ~/.docker/config.json already holds a login for ${HARBOR_URL} (a previous run). The login"
  log_warn "      probe below still performs a REAL TLS handshake, so trust is genuinely re-tested."
fi

log_info "engine-trust-check: engine=${ENGINE} mode=${MODE} registry=${HARBOR_URL}"

# --- 1. Trust: make THIS engine trust the self-signed CA (and count any sudo) -----------------------
CERT_ARGS=()
CA_METHOD="none (insecure)"
if [ "${HARBOR_INSECURE:-0}" != "1" ]; then
  CA="${HARBOR_CA_FILE:-}"
  [ -n "$CA" ] && [ -f "$CA" ] || die "HARBOR_CA_FILE ('${CA:-<unset>}') not found — the CA is written by 'make install-harbor' (secure mode)"
  CA_METHOD="$(engine_trust_ca "$ENGINE" "$HARBOR_URL" "$CA")"
  if [ "$ENGINE" = podman ]; then
    CERTD="$(mktemp -d)"; trap 'rm -rf "$CERTD"' EXIT
    cp "$CA" "${CERTD}/ca.crt"
    CERT_ARGS=(--cert-dir "$CERTD")
  fi
fi
log_info "CA method: ${CA_METHOD}"

TLS_ARGS=()
[ "$ENGINE" = podman ] && TLS_ARGS=(--tls-verify="$([ "${HARBOR_INSECURE:-0}" = "1" ] && echo false || echo true)" "${CERT_ARGS[@]}")

# --- 2. LOGIN — a real TLS handshake + auth, before anything expensive ------------------------------
engine_login_probe "$ENGINE" "$HARBOR_URL" "$HARBOR_USERNAME" "${TLS_ARGS[@]}" \
  || die "engine-trust-check FAILED at login (see the engine's own error above)"

# --- 3. PULL an image the mirror already put in Harbor ----------------------------------------------
BASE="${HARBOR_URL}/${PROJECT}/maven:3.9-eclipse-temurin-25"
log_info "pull  ${BASE}"
run "$ENGINE" pull "${TLS_ARGS[@]}" "$BASE"

# --- 4. BUILD (2 lines — we are testing the ENGINE, not a dependency cache) -------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" ${CERTD:-}' EXIT
printf 'FROM %s\nRUN true\n' "$BASE" > "${WORK}/Dockerfile"
TAG="${HARBOR_URL}/${PROJECT}/engine-probe:${ENGINE}-$(date -u +%Y%m%d%H%M%S)"
log_info "build ${TAG}"
run "$ENGINE" build -t "$TAG" "$WORK"

# --- 5. PUSH — the operation the whole air-gap flow depends on --------------------------------------
log_info "push  ${TAG}"
run "$ENGINE" push "${TLS_ARGS[@]}" "$TAG"

# --- 6. PULL IT BACK — a push that cannot be pulled is not a push (the Harbor lesson of 2026-07-13:
#        a registry that HEAD-200s a blob it does not have makes a push a silent no-op that exits 0).
run "$ENGINE" rmi "$TAG" >/dev/null 2>&1 || true
log_info "pull-back ${TAG}"
run "$ENGINE" pull "${TLS_ARGS[@]}" "$TAG"

# --- 7. THE PRECONDITION ROW — this is the deliverable ----------------------------------------------
# Read the counter from the FILE, not a variable: engine_trust_ca runs inside a command substitution,
# so anything it assigned to a shell variable died with the subshell. (This printed `sudo=NO` for a leg
# that had just prompted the operator for a password — the single most misleading thing this harness
# could possibly do, since the sudo column IS the deliverable.)
N_SUDO="$(engine_sudo_calls)"
SUDO_TXT="NO"
[ "$N_SUDO" -gt 0 ] && SUDO_TXT="YES (${N_SUDO} call(s))"
printf '\n'
printf 'LEG %-16s engine=%-6s mode=%-16s CA=%-42s sudo=%s\n' \
  "${JUMPBOX_OS:-host}" "$ENGINE" "$MODE" "$CA_METHOD" "$SUDO_TXT"
printf '\n'
log_info "engine-trust-check PASSED: ${ENGINE} (${MODE}) can login+pull+build+push+pull-back against ${HARBOR_URL}"
