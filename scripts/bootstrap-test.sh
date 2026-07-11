#!/usr/bin/env bash
# bootstrap-test.sh — validate bootstrap-jumpbox.sh on LITERALLY BARE jump-box images.
#
# Builds jumpbox/Dockerfile.bootstrap (just the script on top of a bare base — nothing
# pre-installed) for each target OS and runs the from-nothing bootstrap inside, asserting
# it installs everything and exits 0 with all core tools present. Also confirms an
# UNSUPPORTED OS is rejected. This is the real proof that the curl|bash bootstrap works
# on a fresh box, not one pre-loaded with the toolchain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd docker
DF="${REPO_ROOT}/jumpbox/Dockerfile.bootstrap"
# Bare jump-box targets. Broad by default (release-level differences — package
# availability, glibc for downloaded tkn/argocd binaries, default curl/bash — do vary);
# narrow it for a quick check, e.g. BOOTSTRAP_TEST_OSES="ubuntu:26.04 photon:5.0".
# NOTE: each OS runs a full `make deps` (~8-12 min) — the default matrix is thorough+slow.
# Photon OS 5 only (Photon 4 is EOL / out of scope — its older package set fails `make deps`).
OSES="${BOOTSTRAP_TEST_OSES:-ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 photon:5.0}"
UNSUPPORTED_OS="${BOOTSTRAP_UNSUPPORTED_OS:-fedora:latest}" # must be rejected by the OS gate

img_tag() { printf 'vks-boot:%s' "$(printf '%s' "$1" | tr ':/.' '___')"; }

fails=0

for base in $OSES; do
  tag="$(img_tag "$base")"; log="$(mktemp)"
  log_info "=== BARE ${base}: build + from-nothing bootstrap ==="
  docker build -q -f "$DF" --build-arg BASE="$base" -t "$tag" "$REPO_ROOT" >/dev/null \
    || { log_error "  build failed for $base"; fails=$((fails+1)); continue; }
  if docker run --rm "$tag" bash /bootstrap-jumpbox.sh >"$log" 2>&1; then
    if grep -q 'all core tools present' "$log"; then
      log_info "  OK   ${base}: bootstrapped from nothing, all core tools present"
    else
      log_error "  FAIL ${base}: exited 0 but not 'all core tools present' — MISSING:"
      grep -E 'MISSING' "$log" | sed 's/^/      /' >&2 || true
      fails=$((fails+1))
    fi
  else
    log_error "  FAIL ${base}: bootstrap exited non-zero. Tail:"
    tail -15 "$log" | sed 's/^/      /' >&2
    fails=$((fails+1))
  fi
  rm -f "$log"
done

# --- unsupported OS must be rejected by the gate (exit non-zero + UNSUPPORTED msg) ---
log_info "=== UNSUPPORTED ${UNSUPPORTED_OS}: OS gate must reject ==="
utag="$(img_tag "$UNSUPPORTED_OS")"; ulog="$(mktemp)"
# Build the unsupported-OS image with NO `|| true` mask: a masked pull/build failure would
# leave `$utag` missing/stale, so the `docker run` below fails for the WRONG reason and the
# reject leg reports a confusing "exited non-zero but without UNSUPPORTED" false-negative.
# Guard the build explicitly instead (mirror the supported-loop structure above).
if ! docker build -q -f "$DF" --build-arg BASE="$UNSUPPORTED_OS" -t "$utag" "$REPO_ROOT" >/dev/null; then
  log_error "  FAIL ${UNSUPPORTED_OS}: could not build the unsupported-OS test image — cannot exercise the reject path (transient pull/build failure? re-run)"
  fails=$((fails+1))
elif docker run --rm "$utag" bash /bootstrap-jumpbox.sh >"$ulog" 2>&1; then
  log_error "  FAIL ${UNSUPPORTED_OS}: bootstrap exited 0 — the OS gate did NOT reject it"
  fails=$((fails+1))
else
  if grep -q 'UNSUPPORTED' "$ulog"; then
    log_info "  OK   ${UNSUPPORTED_OS}: rejected by the OS gate (non-zero exit + UNSUPPORTED)"
  else
    log_error "  FAIL ${UNSUPPORTED_OS}: exited non-zero but without the UNSUPPORTED message"; fails=$((fails+1))
  fi
fi
rm -f "$ulog"

if [ "$fails" -ne 0 ]; then die "$fails bootstrap-test case(s) FAILED"; fi
log_info "SUCCESS — bootstrap-jumpbox.sh validated on bare $OSES + unsupported-OS reject"
