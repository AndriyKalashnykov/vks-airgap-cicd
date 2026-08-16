#!/usr/bin/env bash
# ============================================================================
# assert_env_effective — "I wrote it" is not "it took effect".
#
# `.env` is the LOWEST-precedence sink load_env reads (.env.example -> .env -> .env.state ->
# legacy .env.kind, LAST wins), so a writer that publishes to `.env` while a higher sink already
# holds that key reports success and changes nothing the next process sees.
#
# CASE 3 IS THE POINT. HARBOR_USERNAME/HARBOR_PASSWORD are in load_env's SELECTOR SNAPSHOT, which
# RESTORES the caller's exported value after sourcing — so a re-resolve WITHOUT the `unset` returns
# what the parent already had, and the assert passes unconditionally on exactly the box where the
# bug is live. ABLATION-PROVEN: deleting the `unset` from os.sh flips case 3 from rc=1 to rc=0
# while cases 1 and 2 stay green. A test whose green survives deleting the mechanism is not a test.
# ============================================================================
# RED/GREEN for assert_env_effective, including the VACUITY case that would make it useless.
set -uo pipefail
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s: want %s got %s\n' "$1" "$2" "$3"; fi; }

run() { # run <env-line> <state-line> <expected-arg> [exported?]
  local T; T="$(mktemp -d)"
  cp "$REPO/.env.example" "$T/.env.example"
  printf '%s\n' "$1" > "$T/.env"
  [ -n "$2" ] && printf '%s\n' "$2" > "$T/.env.state"
  ( cd "$T" || exit 9
    export REPO_ROOT="$T"
    # shellcheck disable=SC1090
    . "$REPO/scripts/lib/os.sh" >/dev/null 2>&1
    [ "${4:-}" = exported ] && export HARBOR_PASSWORD="$3"
    assert_env_effective HARBOR_PASSWORD "$3" "test" >/dev/null 2>&1
  ); local rc=$?
  rm -rf "$T"; printf '%s' "$rc"
}

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
chk 'no shadow -> the .env write took effect (rc 0)' 0 "$(run 'HARBOR_PASSWORD=robotsecret' '' robotsecret)"
chk 'overlay SHADOWS the .env write (rc 1) -- the real bug' 1 "$(run 'HARBOR_PASSWORD=robotsecret' 'HARBOR_PASSWORD=adminpw' robotsecret)"
chk 'VACUITY: shadowed AND exported must still FAIL (the unset is what makes this work)' 1 "$(run 'HARBOR_PASSWORD=robotsecret' 'HARBOR_PASSWORD=adminpw' robotsecret exported)"
printf '\n  %d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1
