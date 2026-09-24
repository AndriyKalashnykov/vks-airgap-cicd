#!/usr/bin/env bash
# test-env-pins.sh — B738: an old version pin in .env must not freeze a REPO pin, must still hold a
# LAB pin, and a per-run override must beat both. Also: env-init writes repo pins commented, and
# check-pin-classes goes RED on an unowned pin and on a dangling marker.
#
# Offline, in a scratch REPO_ROOT holding this tree's scripts/lib, 02-env.sh and .env.example, so the
# operator's real .env is never read. Values come from .env.example itself (not typed here), so a
# Renovate bump cannot rot the test.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
mkdir -p "$T/scripts/lib"
cp "$SRC"/scripts/lib/*.sh "$T/scripts/lib/" && cp "$SRC/scripts/02-env.sh" "$T/scripts/" \
  && cp "$SRC/.env.example" "$T/" || { echo "test-env-pins: could not build the scratch repo"; exit 1; }
[ -s "$T/.env.example" ] && [ -s "$T/scripts/lib/os.sh" ] || { echo "test-env-pins: scratch repo is incomplete"; exit 1; }

fail=0; n=0
ok()  { n=$((n+1)); printf '  ok    %s\n' "$1"; }
bad() { n=$((n+1)); fail=1; printf '  FAIL  %s\n' "$1"; }
ex()  { grep -E "^$1=" "$T/.env.example" | head -1 | cut -d= -f2-; }
REPO_PIN=ISTIO_VERSION; LAB_PIN=VCF_CLI_VERSION
REPO_X="$(ex "$REPO_PIN")"; LAB_X="$(ex "$LAB_PIN")"
[ -n "$REPO_X" ] && [ -n "$LAB_X" ] || { echo "test-env-pins: could not read the pins from .env.example"; exit 1; }

# le [VAR=value ...] — run load_env in the scratch repo with a clean pin environment; prints
# "<repo>|<lab>" on stdout, warnings to $T/err
le() {
  (cd "$T" && env -u "$REPO_PIN" -u "$LAB_PIN" -u _VKS_PIN_WARNED "$@" \
     bash -c '. scripts/lib/os.sh; load_env; printf "%s|%s\n" "$'"$REPO_PIN"'" "$'"$LAB_PIN"'"') 2>"$T/err"
}
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }
warned() { grep -q "IGNORED old version pins in .env:.*$1" "$T/err"; }

echo "== no .env: both pins come from .env.example, no warning"
rm -f "$T/.env"
chk "no .env" "${REPO_X}|${LAB_X}" "$(le)"
if grep -q IGNORED "$T/err"; then bad "warned with no .env"; else ok "no warning"; fi

echo "== .env holds OLD values: repo pin follows .env.example (named in a warning), lab pin is held"
printf '%s=0.0.1\n%s=0.0.2\n' "$REPO_PIN" "$LAB_PIN" > "$T/.env"
chk "old .env" "${REPO_X}|0.0.2" "$(le)"
if warned "${REPO_PIN}=0.0.1 (repo: ${REPO_X})"; then ok "warning names the ignored line"; else bad "no/wrong warning: $(cat "$T/err")"; fi
if grep -q "$LAB_PIN" "$T/err"; then bad "warned about a LAB pin, which .env legitimately holds"; else ok "lab pin not warned about"; fi

echo "== per-run override beats .env for both classes"
chk "override" "9.9.9|7.7.7" "$(le "$REPO_PIN=9.9.9" "$LAB_PIN=7.7.7")"

echo "== a caller value EQUAL to the .env line is .env leaking in (set -a; . ./.env), not an override"
chk "leaked .env" "${REPO_X}|0.0.2" "$(le "$REPO_PIN=0.0.1" "$LAB_PIN=0.0.2")"

echo "== warn once per process tree"
le _VKS_PIN_WARNED=1 >/dev/null
if grep -q IGNORED "$T/err"; then bad "warned again with _VKS_PIN_WARNED=1"; else ok "silent when already warned"; fi

echo "== env-init: repo pins written commented, lab pins active; the result loads repo values"
rm -f "$T/.env"
(cd "$T" && SKIP_DOTENV=0 bash scripts/02-env.sh init >/dev/null 2>&1)
if grep -qE "^# ${REPO_PIN}=" "$T/.env" && ! grep -qE "^${REPO_PIN}=" "$T/.env" && grep -qE "^${LAB_PIN}=" "$T/.env"; then
  ok "repo pin commented, lab pin active in the new .env"
else bad "env-init output: $(grep -nE "${REPO_PIN}|${LAB_PIN}" "$T/.env" | head -3 | tr '\n' ' ')"; fi
chk "fresh .env loads" "${REPO_X}|${LAB_X}" "$(le)"

echo "== check-pin-classes"
cp "$SRC/scripts/check-pin-classes.sh" "$T/scripts/"
gate() { (cd "$T" && PIN_CLASSES_FILE="$1" bash scripts/check-pin-classes.sh) >"$T/gate" 2>&1; }
if gate "$T/.env.example"; then ok "the shipped .env.example passes"; else bad "shipped file fails: $(tail -2 "$T/gate")"; fi
printf '# renovate: datasource=x depName=y\nA_VERSION=1\n# pin: lab\nB_VERSION=2\nC_TAG=3\n' > "$T/f1"
if gate "$T/f1"; then bad "an unowned C_TAG passed"; elif grep -q 'C_TAG is a version pin with no owner' "$T/gate"; then ok "RED on an unowned pin"; else bad "failed for another reason: $(tail -1 "$T/gate")"; fi
printf '# renovate: datasource=x depName=y\nA_VERSION=1\n# pin: lab\n# a comment in between\nB_VERSION=2\n' > "$T/f2"
if gate "$T/f2"; then bad "a dangling marker passed"; elif grep -q "marks no key" "$T/gate"; then ok "RED on a dangling '# pin: lab'"; else bad "failed for another reason: $(tail -1 "$T/gate")"; fi

echo "test-env-pins: ${n} checks"
[ "$fail" -eq 0 ] && { echo "test-env-pins: OK"; exit 0; }
echo "test-env-pins: FAILED"; exit 1
