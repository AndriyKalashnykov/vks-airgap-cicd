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
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
load_env

# THIS SCRIPT PUSHES — so it takes the registry lock, exactly like 15-build-push-builder.sh. A matrix of
# engine legs is a QUEUE OF PUSHERS by construction, and a concurrent pusher is what this repo has already
# blamed for a wrecked Harbor. The second caller fails fast instead of racing.
if [ -z "${__REGISTRY_LOCK_HELD:-}" ]; then
  export __REGISTRY_LOCK_HELD=1
  with_registry_lock "$(basename "$0")" "$0" "$@"
  exit $?
fi

# ISOLATE the docker/podman CLI config: `login` writes an auth entry into the operator's SHARED
# ~/.docker/config.json. We do not touch their file.
if [ -z "${DOCKER_CONFIG:-}" ]; then
  DOCKER_CONFIG="$(mktemp -d)"; export DOCKER_CONFIG
  trap 'rm -rf "$DOCKER_CONFIG"' EXIT
fi

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

# --- 6. VERIFY THE PUSH SERVER-SIDE ------------------------------------------------------------------
# NOT with an engine pull-back. `$ENGINE rmi <tag>` removes the TAG; the LAYERS stay in the local content
# store, so a "pull-back" re-fetches the manifest and finds every blob already present LOCALLY — it never
# re-downloads one. A registry that HEAD-200s blobs it does not have (the exact failure that silently
# destroyed this Harbor on 2026-07-13) would PASS that check.
#
# `crane validate --remote` fetches the manifest AND every blob from the registry. It is what mirror-verify
# uses, for precisely this reason. (It also needs no engine, so it cannot be fooled by an engine's cache.)
log_info "verify ${TAG} is RETRIEVABLE from the registry (crane validate --remote — not an engine pull-back:"
log_info "  an engine pull-back would be satisfied by its own local layer cache and prove nothing)"
if have crane; then
  if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
    run crane validate --remote --insecure "$TAG"
  else
    # crane honours SSL_CERT_FILE, and it REPLACES Go's default pool — so the bundle must be
    # system CAs + our CA, or a public pull in the same process would start failing.
    CRANE_TMP="$(mktemp -d)"; ca_bundle_with_system "$CA" "${CRANE_TMP}/ca-bundle.crt"
    SSL_CERT_FILE="${CRANE_TMP}/ca-bundle.crt" run crane validate --remote "$TAG"
    rm -rf "$CRANE_TMP"
  fi
else
  log_warn "crane not installed — falling back to an engine pull-back, which CANNOT prove the blobs are"
  log_warn "  actually stored (it is satisfied by the local layer cache). Install crane: make deps"
  run "$ENGINE" rmi "$TAG" >/dev/null 2>&1 || true
  run "$ENGINE" pull "${TLS_ARGS[@]}" "$TAG"
fi

# --- 7. THE PRECONDITION ROW — this is the deliverable ----------------------------------------------
# Read the counter from the FILE, not a variable: engine_trust_ca runs inside a command substitution,
# so anything it assigned to a shell variable died with the subshell. (This printed `sudo=NO` for a leg
# that had just prompted the operator for a password — the single most misleading thing this harness
# could possibly do, since the sudo column IS the deliverable.)
N_SUDO="$(engine_sudo_calls)"
if ! engine_sudo_measurable; then
  # uid 0: engine_sudo escalated nothing (there was nothing to escalate to) and the /etc write succeeded
  # anyway. The counter therefore reads 0 — which is NOT "sudo=NO", it is "we could not measure this".
  # Printing NO here would resurrect the exact lie this harness exists to prevent, so we refuse.
  SUDO_TXT="UNMEASURABLE (running as root — re-run as a normal user)"
elif [ "$N_SUDO" -gt 0 ]; then
  SUDO_TXT="YES (${N_SUDO} call(s))"
else
  SUDO_TXT="NO"
fi
printf '\n'
printf 'LEG %-16s engine=%-6s mode=%-16s CA=%-42s sudo=%s\n' \
  "${JUMPBOX_OS:-host}" "$ENGINE" "$MODE" "$CA_METHOD" "$SUDO_TXT"
printf '\n'
log_info "engine-trust-check PASSED: ${ENGINE} (${MODE}) can login+pull+build+push+pull-back against ${HARBOR_URL}"
