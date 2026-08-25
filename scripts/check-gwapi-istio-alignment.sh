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

# --fail is LOAD-BEARING, not hygiene: without it an HTTP error is rc=0 WITH THE ERROR PAGE AS THE
# BODY, so the `[ -z "$gomod" ]` guard below never fires and the GWAPI_REQUIRE_FETCH branch is DEAD
# CODE. The script then falls through to the "no sigs.k8s.io/gateway-api line" exit at the bottom and
# blames the BRANCH NAME for what is actually an unreachable server -- failing CLOSED (so not a fake
# green) while naming the WRONG cause, which sends the reader to the wrong file.
#
# MEASURED 2026-08-17 against a LOCAL http.server returning 500 with a 4000-byte body (no external
# network, so this is reproducible during an outage):
#   curl -sSL   -> rc=0, body=4026 bytes  -> guard does NOT fire   <- the defect
#   curl -fsSL  -> rc=0, body=0 bytes     -> guard FIRES           <- the fix
#   curl -fsSL against a 200 -> body intact, 1 gateway-api line    <- happy path unaffected
# Note the DISCRIMINATOR is the BODY, not the rc: `|| true` below zeroes the status either way.
gomod="$(curl -fsSL --max-time "${GWAPI_FETCH_TIMEOUT_SECONDS:-15}" "$url" 2>/dev/null || true)"
if [ -z "$gomod" ]; then
  # GWAPI_REQUIRE_FETCH=1 turns the skip into a FAILURE. CI sets it, because CI has network by
  # definition and this gate is in the fast set that CI's green now stands for: a rate-limited
  # raw.githubusercontent would otherwise make that job green while this gate covered NOTHING.
  # MEASURED 2026-08-16 (adversary round on the CI split): with a blackholed proxy this script
  # exited 0 with three WARN lines — the exact "passes by not looking" shape, in the only gate
  # standing between us and a guessed CRD version.
  # Locally (and on a plane) the loud SKIP is still the right behaviour, so the default is unchanged.
  if [ "${GWAPI_REQUIRE_FETCH:-0}" = 1 ]; then
    log_error "check-gwapi-istio-alignment: could not fetch ${url} and GWAPI_REQUIRE_FETCH=1."
    log_error "  Refusing to report a green this gate did not earn. Re-run when the fetch works."
    exit 1
  fi
  log_warn "check-gwapi-istio-alignment: SKIPPED — could not fetch ${url} (offline?)."
  log_warn "  This check is the ONLY thing standing between us and a guessed CRD version. It must"
  log_warn "  run in CI. A green static-check WITHOUT it does not prove the pin is right."
  log_warn "  (CI sets GWAPI_REQUIRE_FETCH=1 so this path is a FAILURE there, not a skip.)"
  exit 0
fi

vendored="$(printf '%s' "$gomod" | grep -E '^[[:space:]]+sigs\.k8s\.io/gateway-api v' | head -1 | awk '{print $2}')"
if [ -z "$vendored" ]; then
  log_error "check-gwapi-istio-alignment: istio ${minor} go.mod has no sigs.k8s.io/gateway-api line."
  log_error "  Either the branch name is wrong (ISTIO_VERSION=${ISTIO_VERSION} -> ${minor}) or Istio"
  log_error "  restructured. Re-derive by hand: curl -sSL ${url} | grep gateway-api"
  exit 1
fi

# THE SECOND INSTALL PATH. ISTIO_INSTALL_METHOD=package installs a DIFFERENT Istio -- the VKS
# Standard Package, whose version this file never sees, while 43-install-istio-package.sh calls the
# same istio_ensure_gwapi_crds and therefore inherits the SAME GATEWAY_API_VERSION. So this gate was
# validating the helm pin's requirement and reporting OK for a run that would install neither that
# Istio nor its gateway-api. MEASURED 2026-08-25: release-1.28 (the package) vendors gateway-api
# v1.4.1 while release-1.30 (helm) vendors v1.5.1 -- the CRDs-newer-than-client direction, which is
# the crash-looping one.
#
# It can only be checked when the package version is PINNED. Unset, it floats to whatever the cluster
# offers newest, which is not knowable offline -- so say that out loud rather than imply coverage.
# This gate's own header records why that distinction matters: it exists because a COMMENT saying
# "keep this coupled" was not a control.
# Initialised, NOT left to default: load_env's `set -a` exports every uncommented .env line, so an
# uninherited bare name could be forced on from the environment and print "HELM PATH ONLY" under a
# fully-checked package pin, with no warning above it to explain the caveat.
gwapi_pkg_unchecked=0
if [ -n "${ISTIO_PACKAGE_VERSION:-}" ]; then
  pkg_minor="release-$(printf '%s' "$ISTIO_PACKAGE_VERSION" | cut -d. -f1,2)"
  pkg_url="https://raw.githubusercontent.com/istio/istio/${pkg_minor}/go.mod"
  pkg_gomod="$(curl -fsSL --max-time "${GWAPI_FETCH_TIMEOUT_SECONDS:-15}" "$pkg_url" 2>/dev/null || true)"
  if [ -z "$pkg_gomod" ]; then
    if [ "${GWAPI_REQUIRE_FETCH:-0}" = 1 ]; then
      log_error "check-gwapi-istio-alignment: could not fetch ${pkg_url} (the PACKAGE pin) and GWAPI_REQUIRE_FETCH=1."
      exit 1
    fi
    log_warn "check-gwapi-istio-alignment: the PACKAGE pin ${ISTIO_PACKAGE_VERSION} was NOT checked."
    log_warn "  could not fetch ${pkg_url}"
    log_warn "  If that URL looks wrong, the PIN is the suspect, not the network: the branch is derived"
    log_warn "  as release-<major>.<minor> from ISTIO_PACKAGE_VERSION, so a malformed pin yields a 404."
    # The OK line MUST carry the caveat here too. A fetch failure is the MOST LIKELY not-checked
    # path in the wild (a proxy, a rate-limit, a malformed pin), and it previously warned and then
    # printed an unqualified "OK" -- so the reader saw a full pass over a half-run gate.
    gwapi_pkg_unchecked=1
  else
    pkg_vendored="$(printf '%s' "$pkg_gomod" | grep -E '^[[:space:]]+sigs\.k8s\.io/gateway-api v' | head -1 | awk '{print $2}')"
    if [ -n "$pkg_vendored" ] && [ "$pkg_vendored" != "$GATEWAY_API_VERSION" ]; then
      log_error "check-gwapi-istio-alignment: GATEWAY_API_VERSION=${GATEWAY_API_VERSION} does not match the"
      log_error "  PACKAGE pin. istio ${ISTIO_PACKAGE_VERSION} (${pkg_minor}) vendors gateway-api ${pkg_vendored}."
      log_error "  ISTIO_INSTALL_METHOD=package installs THAT Istio and then istio_ensure_gwapi_crds installs"
      log_error "  ${GATEWAY_API_VERSION} against it. Newer CRDs than the client is the crash-looping direction."
      log_error "  One GATEWAY_API_VERSION cannot serve two Istio minors: pin the package to the same minor"
      log_error "  as ISTIO_VERSION, or give the package path its own CRD version."
      exit 1
    fi
    if [ -z "$pkg_vendored" ]; then
      # FAIL CLOSED, exactly as the helm arm above does on the same condition. `release-1.8/go.mod`
      # is a real HTTP 200 with ZERO sigs.k8s.io/gateway-api lines, so a fetch can succeed and the
      # extraction still yield nothing -- and warning-and-continuing there made this gate LESS
      # informative when a pin was set-but-uncheckable than when it was unset.
      log_error "check-gwapi-istio-alignment: fetched ${pkg_url} but found no sigs.k8s.io/gateway-api"
      log_error "  requirement in it. Either ${pkg_minor} does not vendor gateway-api (so the PACKAGE"
      log_error "  pin ${ISTIO_PACKAGE_VERSION} is for an Istio that predates it), or the go.mod format"
      log_error "  changed and this gate's matcher is stale. Both need a human; neither is a pass."
      exit 1
    fi
    log_info "check-gwapi-istio-alignment: the PACKAGE pin ${ISTIO_PACKAGE_VERSION} also vendors ${pkg_vendored}."
  fi
else
  # WARN, not INFO: ISTIO_PACKAGE_VERSION is commented in .env.example, so this is the DEFAULT path
  # and every real run takes it. An INFO line saying "this gate covers half of what you think" is the
  # kind of disclosure nobody reads. Not "offline" -- this gate is online and just made two HTTPS
  # fetches; the reason is that an unpinned package version is chosen at INSTALL time, on a cluster.
  log_warn "check-gwapi-istio-alignment: ISTIO_PACKAGE_VERSION is unset, so the package path's Istio"
  log_warn "  version FLOATS -- it is chosen from the cluster's offer at install time and CANNOT be"
  log_warn "  checked here. This gate covers the HELM path only. Set ISTIO_PACKAGE_VERSION to cover both."
  gwapi_pkg_unchecked=1
fi

if [ "$GATEWAY_API_VERSION" = "$vendored" ]; then
  if [ "${gwapi_pkg_unchecked:-0}" = 1 ]; then
    log_info "check-gwapi-istio-alignment: OK (HELM PATH ONLY — the package path is UNCHECKED, see the warning above) — istio ${ISTIO_VERSION} (${minor}) vendors gateway-api ${vendored}, and that is our pin"
  else
    log_info "check-gwapi-istio-alignment: OK — istio ${ISTIO_VERSION} (${minor}) vendors gateway-api ${vendored}, and that is our pin"
  fi
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
