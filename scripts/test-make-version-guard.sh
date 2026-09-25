#!/usr/bin/env bash
# ci-tier: fast — offline; runs `make -n` on the repo's own Makefile, no network, no cluster.
# test-make-version-guard.sh — the Makefile must REFUSE a GNU make without `.oneshell` (< 3.82).
#
# Apple's /usr/bin/make is 3.81, which has no .SHELLFLAGS: every recipe would silently lose
# `-e -o pipefail`, so a green under it is not a green (B735). Makefile:89-91 refuses it at parse
# time. Nothing tested that guard, so a refactor that dropped it would ship silently.
#
# 3.81 itself is not available on a Linux runner, so this simulates it: `.FEATURES` set on the
# command line overrides make's own value, and removing `oneshell` from it is exactly what 3.81
# reports. MEASURED 2026-09-25 on the Mac: real /usr/bin/make 3.81 -> rc=2 with the same message.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# control: the real make must parse the Makefile, or the RED arm below proves nothing.
if make -n help >/dev/null 2>&1; then ok "control: a make WITH oneshell parses the Makefile"
else bad "control: make -n help failed on this host -- the refusal arm below would be vacuous"; fi

out="$(make -n help .FEATURES='target-specific order-only' 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'GNU make >= 3.82 is required'; then
  ok "a make WITHOUT oneshell is refused with the 3.82 message (rc=$rc)"
else
  bad "a make WITHOUT oneshell was NOT refused (rc=$rc): ${out:0:200}"
fi

# the message must tell a Mac user what to do, not only what is wrong.
if printf '%s' "$out" | grep -q 'gmake'; then ok "the refusal names gmake (the macOS fix)"
else bad "the refusal does not name gmake"; fi

printf 'test-make-version-guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
