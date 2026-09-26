#!/usr/bin/env bash
# test-short-sha-in.sh — short_sha_in decides whether build-apps' push reached the deploy repo (B742).
# `git rev-parse --short` has no fixed length, so a match is a prefix in either direction; an empty
# value (an unreadable deploy repo) must never count as deployed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0; checks=0
t() {  # t <label> <want 0|1> <sha> <candidates...>
  local label="$1" want="$2" got; shift 2
  short_sha_in "$@" && got=0 || got=1
  checks=$((checks+1))
  if [ "$got" = "$want" ]; then printf '  ok   %s\n' "$label"; else rc=1; printf '  FAIL %s (got %s, want %s)\n' "$label" "$got" "$want"; fi
}
t "same length"                         0 abc1234 abc1234
t "deploy repo longer than ours"        0 abc12345 abc1234
t "deploy repo shorter than ours"       0 abc1234 abc12345
t "second candidate (the re-fire sha)"  0 def5678 abc1234 def5678
t "no candidate matches"                1 fff0000 abc1234 def5678
t "EMPTY value never matches"           1 "" abc1234
t "the seeded placeholder never matches" 1 unknown abc1234
t "empty candidate is skipped, not a wildcard" 1 abc1234 ""
echo "test-short-sha-in: ${checks} checks, rc=$rc"
exit "$rc"
