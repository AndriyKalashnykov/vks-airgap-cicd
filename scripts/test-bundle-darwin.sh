#!/usr/bin/env bash
# test-bundle-darwin.sh — B735 item 11: `make bundle` refuses on macOS before doing any work, because it
# would stage darwin binaries for a Linux air-gap box. Offline: a faked uname answers Darwin.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
# shellcheck disable=SC2016  # $1 belongs to the generated script
printf '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$T/uname"; chmod +x "$T/uname"
# shellcheck disable=SC2031  # os.sh assigns PATH on macOS only; this per-command PATH is intended
PATH="$T:$PATH" SKIP_DOTENV=1 BUNDLE_DIR="$T/bundle" bash "$SCRIPT_DIR/11-bundle.sh" > "$T/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'not supported on macOS' "$T/out" && [ ! -e "$T/bundle" ]; then
  echo "  ok    make bundle refuses on macOS, naming why, before creating anything"
  echo "test-bundle-darwin: OK"; exit 0
fi
echo "  FAIL  want a refusal on macOS; rc=$rc"; sed 's/^/      /' "$T/out" | tail -5
echo "test-bundle-darwin: FAILED"; exit 1
