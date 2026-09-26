#!/usr/bin/env bash
# test-macos-refusals.sh — B735: targets that cannot work on macOS refuse there, by name and with the
# reason, instead of failing later with an error that names something else. Offline: a faked uname
# answers Darwin (lib/os.sh reads it; on a real Mac it is Darwin anyway).
#   make bundle            -> would stage darwin binaries for a Linux air-gap box
#   make engine-trust-check-> podman remote has no pull/push --cert-dir (measured, podman 6.1.2)
#   make trust-harbor      -> would install a CA the engine VM never reads
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
# shellcheck disable=SC2016  # $1 belongs to the generated script
printf '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$T/uname"; chmod +x "$T/uname"
fail=0; n=0
check() {   # check <script> <message>
  local out rc
  # shellcheck disable=SC2031  # os.sh assigns PATH on macOS only; this per-command PATH is intended
  out="$(PATH="$T:$PATH" SKIP_DOTENV=1 BUNDLE_DIR="$T/bundle" bash "$SCRIPT_DIR/$1" 2>&1)"; rc=$?
  n=$((n+1))
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "$2"; then echo "  ok    $1 refuses on macOS"
  else fail=1; echo "  FAIL  $1: want a refusal naming '$2'; rc=$rc"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /'; fi
}
check 11-bundle.sh            'not supported on macOS'
check 16-engine-trust-check.sh 'Linux-only for now'
check 19-trust-harbor.sh       'Linux-only for now'
# 17's OWN sentence: on a Linux box that really has rootless docker, an unguarded 17 runs through and
# hands off to 16, whose "Linux-only" refusal made a looser match pass on main (measured).
check 17-engine-rootless-docker-check.sh 'engine-trust-check-rootless is Linux-only'
# The library function itself fails closed, and spends NO sudo, for any future caller that skips the refusal.
printf 'x' > "$T/ca.crt"
out="$(PATH="$T:$PATH" SKIP_DOTENV=1 ENGINE_SUDO_COUNT_FILE="$T/sudo" bash -c '. "$1/lib/os.sh"; . "$1/lib/engine.sh"; engine_trust_ca docker 10.0.0.5 "$2"; echo "rc=$?"; echo "sudo=$(engine_sudo_calls)"' _ "$SCRIPT_DIR" "$T/ca.crt" 2>&1)"
n=$((n+1))
if printf '%s' "$out" | grep -q 'rc=1' && printf '%s' "$out" | grep -q 'sudo=0' && printf '%s' "$out" | grep -q 'not supported on macOS'; then
  echo "  ok    engine_trust_ca refuses on macOS with 0 sudo"
else fail=1; echo "  FAIL  engine_trust_ca on macOS: $out" | tail -4; fi
echo "test-macos-refusals: ${n} checks"
[ "$fail" -eq 0 ] && { echo "test-macos-refusals: OK"; exit 0; }
echo "test-macos-refusals: FAILED"; exit 1
