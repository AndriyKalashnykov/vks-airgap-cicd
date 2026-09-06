#!/usr/bin/env bash
# RED-proof for 24-vks-k8s-version.sh's NON-DESTRUCTIVE pin guard. Offline; no cluster.
#
# THE BUG THIS PINS (measured 2026-09-06, found by a vks-adversary idea round): the guard read the
# ENVIRONMENT. Under SKIP_DOTENV=1 `load_env` does not read .env, so the variable is UNSET while the
# file still holds a deliberate pin -- and the script WRITES to that file. It therefore clobbered the
# pin in exactly the mode whose whole purpose is to behave like a fresh box.
#
# It is the third of three sites in this class. vks-shape.sh reads the file (fixed, and records the
# same measurement for VKS_STORAGE_CLASS); 22-harbor-robot.sh refuses outright under SKIP_DOTENV.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT

# `_pin_of` as shipped, parameterised on the file so the test can point it at a fixture.
_pin_of() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -1 || true; }

decide() {  # decide <newest> -> prints PRESERVE|WRITE
  local v="$1" _pin
  _pin="$(_pin_of VKS_K8S_VERSION)"
  # is_placeholder: empty or a <...> template value
  case "${_pin:-}" in ''|'<'*'>') printf 'WRITE'; return ;; esac
  if [ "${_pin}" != "$v" ]; then printf 'PRESERVE'; else printf 'WRITE'; fi
}

echo "== a deliberate pin in .env SURVIVES, in BOTH dotenv modes =="
ENVF="$TD/.env"
printf 'VKS_K8S_VERSION=v1.34.9+vmware.2-vkr.4\n' > "$ENVF"

# The discriminator: the ENVIRONMENT is what SKIP_DOTENV=1 leaves unset. Reading the FILE must give
# the same answer either way -- that equality IS the fix.
for mode in "normal" "skip-dotenv"; do
  if [ "$mode" = normal ]; then export VKS_K8S_VERSION=v1.34.9+vmware.2-vkr.4; else unset VKS_K8S_VERSION; fi
  got="$(decide 'v1.36.2+vmware.2-vkr.3')"
  if [ "$got" = PRESERVE ]; then ok "$mode: pin preserved"; else bad "$mode: got $got, wanted PRESERVE"; fi
done
unset VKS_K8S_VERSION

echo
echo "== and the OLD, environment-reading form is RED on the same fixture =="
# This is the shipped-before shape. It must DISAGREE across the two modes -- if it does not, the
# test is not measuring the bug and its green above means nothing.
decide_old() {
  local v="$1"
  case "${VKS_K8S_VERSION:-}" in ''|'<'*'>') printf 'WRITE'; return ;; esac
  if [ "${VKS_K8S_VERSION}" != "$v" ]; then printf 'PRESERVE'; else printf 'WRITE'; fi
}
export VKS_K8S_VERSION=v1.34.9+vmware.2-vkr.4
old_normal="$(decide_old 'v1.36.2+vmware.2-vkr.3')"
unset VKS_K8S_VERSION
old_skip="$(decide_old 'v1.36.2+vmware.2-vkr.3')"
if [ "$old_normal" = PRESERVE ] && [ "$old_skip" = WRITE ]; then
  ok "old form: PRESERVE normally but WRITE (clobber) under SKIP_DOTENV — the bug reproduces"
else
  bad "old form did not reproduce the bug (normal=$old_normal skip=$old_skip) — this test proves nothing"
fi

echo
echo "== no pin, or a template placeholder, still WRITES =="
: > "$ENVF";                                        if [ "$(decide v1.36.2)" = WRITE ]; then ok "empty .env -> WRITE"; else bad "empty .env"; fi
printf 'VKS_K8S_VERSION=<set-me>\n' > "$ENVF";      if [ "$(decide v1.36.2)" = WRITE ]; then ok "placeholder -> WRITE"; else bad "placeholder"; fi
printf 'VKS_K8S_VERSION=v1.36.2\n' > "$ENVF";       if [ "$(decide v1.36.2)" = WRITE ]; then ok "pin == newest -> WRITE (no-op)"; else bad "pin == newest"; fi

echo
echo "== the LAST occurrence wins, as sed|tail does =="
printf 'VKS_K8S_VERSION=v1.33.1\nVKS_K8S_VERSION=v1.34.9\n' > "$ENVF"
if [ "$(_pin_of VKS_K8S_VERSION)" = 'v1.34.9' ]; then ok "duplicate keys -> last wins"; else bad "duplicate keys"; fi

echo
echo "== a MISSING .env must not kill the caller (sed exits 2, pipefail promotes it) =="
# MEASURED: without `|| true` this took out 3 arms of test-tkr-classify.sh with rc=2 and no message
# of its own -- the harness runs in a temp dir with no .env. `2>/dev/null` hides sed's stderr, NOT
# its exit status, and 2 is "could not read the file", not "no match".
ENVF="$TD/definitely-absent.env"
if out="$( set -euo pipefail; _pin_of VKS_K8S_VERSION )"; then
  if [ -z "$out" ]; then ok "absent .env -> empty, rc=0 (did NOT trip set -e)"; else bad "absent .env returned [$out]"; fi
else
  bad "absent .env KILLED the caller (rc=$?) — the || true guard is missing"
fi

echo
printf 'vks-version-pin: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
