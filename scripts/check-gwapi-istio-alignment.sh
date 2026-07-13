#!/usr/bin/env bash
# check-gwapi-istio-alignment.sh — GATEWAY_API_VERSION must be the version the pinned ISTIO vendors.
#
# WHY THIS EXISTS: I GUESSED. I typed GATEWAY_API_VERSION=v1.2.1 from memory without checking what
# Istio actually vendors — inside a commit whose whole subject was "we shipped an unverified claim".
# Then Renovate solo-bumped it to v1.6.0 (NEWER than any Istio's client) and auto-merged it, because
# the "keep this coupled to ISTIO_VERSION" COMMENT was not a control.
#
# The pin is not free. Istio ships a Gateway API Go client compiled against ONE version:
#   * CRDs NEWER than that client  -> the supportedFeatures []string -> []object skew; controllers
#                                     crash-loop on an unmarshal error that names a Go struct field,
#                                     not the version skew.
#   * CRDs OLDER                   -> can be refused by the safe-upgrades admission policy.
#
# GROUND TRUTH is Istio's own go.mod for the pinned release branch — never a doc, never memory.
# Needs network (CI has it). Skips cleanly offline so a plane-mode `make static-check` is not a lie:
# it says SKIPPED, loudly, rather than silently passing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh
load_env

: "${ISTIO_VERSION:?ISTIO_VERSION must be set (.env.example)}"
: "${GATEWAY_API_VERSION:?GATEWAY_API_VERSION must be set (.env.example)}"

# release-1.30 from 1.30.2
minor="release-$(printf '%s' "$ISTIO_VERSION" | cut -d. -f1,2)"
url="https://raw.githubusercontent.com/istio/istio/${minor}/go.mod"

gomod="$(curl -sSL --max-time "${CURL_MAX_TIME_SECONDS:-15}" "$url" 2>/dev/null || true)"
if [ -z "$gomod" ]; then
  log_warn "check-gwapi-istio-alignment: SKIPPED — could not fetch ${url} (offline?)."
  log_warn "  This check is the ONLY thing standing between us and a guessed CRD version. It must"
  log_warn "  run in CI. A green static-check WITHOUT it does not prove the pin is right."
  exit 0
fi

vendored="$(printf '%s' "$gomod" | grep -E '^[[:space:]]+sigs\.k8s\.io/gateway-api v' | head -1 | awk '{print $2}')"
if [ -z "$vendored" ]; then
  log_error "check-gwapi-istio-alignment: istio ${minor} go.mod has no sigs.k8s.io/gateway-api line."
  log_error "  Either the branch name is wrong (ISTIO_VERSION=${ISTIO_VERSION} -> ${minor}) or Istio"
  log_error "  restructured. Re-derive by hand: curl -sSL ${url} | grep gateway-api"
  exit 1
fi

if [ "$GATEWAY_API_VERSION" = "$vendored" ]; then
  log_info "check-gwapi-istio-alignment: OK — istio ${ISTIO_VERSION} (${minor}) vendors gateway-api ${vendored}, and that is our pin"
  exit 0
fi

log_error "check-gwapi-istio-alignment: MISMATCH"
log_error "  ISTIO_VERSION=${ISTIO_VERSION} (${minor}) vendors gateway-api ${vendored}"
log_error "  GATEWAY_API_VERSION=${GATEWAY_API_VERSION}   <-- NOT what Istio's client is compiled against"
log_error ""
log_error "  NEWER than Istio's client re-introduces the supportedFeatures []string -> []object skew"
log_error "  (controllers crash-loop). OLDER can be refused by the safe-upgrades admission policy."
log_error ""
log_error "  Fix: set GATEWAY_API_VERSION=${vendored} in .env.example — do NOT guess, this IS the answer."
log_error "  If you are bumping Istio, bump BOTH (they are grouped in renovate.json for this reason)."
exit 1
