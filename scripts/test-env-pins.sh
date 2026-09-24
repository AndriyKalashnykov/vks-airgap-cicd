#!/usr/bin/env bash
# test-env-pins.sh — B738: an old version pin must not freeze a REPO pin (whether it sits in .env, in
# an overlay, or is left exported in the shell by `set -a; . ./.env`), a LAB pin must follow .env, and
# PIN_OVERRIDE is the only per-run override. Also: env-init writes repo pins commented, and
# check-pin-classes goes RED on an unowned pin, a marker over a non-version key, and a dangling marker.
#
# Offline, in a scratch REPO_ROOT holding this tree's scripts/lib, 02-env.sh and .env.example, so the
# operator's real .env is never read. Values come from .env.example itself (not typed here), so a
# Renovate bump cannot rot the test.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
mkdir -p "$T/scripts/lib"
if ! { cp "$SRC"/scripts/lib/*.sh "$T/scripts/lib/" && cp "$SRC/scripts/02-env.sh" "$SRC/scripts/check-pin-classes.sh" "$T/scripts/" \
       && cp "$SRC/.env.example" "$T/"; }; then
  echo "test-env-pins: could not build the scratch repo"; exit 1
fi
[ -s "$T/.env.example" ] && [ -s "$T/scripts/lib/os.sh" ] || { echo "test-env-pins: scratch repo is incomplete"; exit 1; }

fail=0; n=0
ok()  { n=$((n+1)); printf '  ok    %s\n' "$1"; }
bad() { n=$((n+1)); fail=1; printf '  FAIL  %s\n' "$1"; }
ex()  { grep -E "^$1=" "$T/.env.example" | head -1 | cut -d= -f2-; }
REPO_PIN=ISTIO_VERSION; LAB_PIN=VCF_CLI_VERSION
REPO_X="$(ex "$REPO_PIN")"; LAB_X="$(ex "$LAB_PIN")"
[ -n "$REPO_X" ] && [ -n "$LAB_X" ] || { echo "test-env-pins: could not read the pins from .env.example"; exit 1; }

# le [VAR=value ...] — load_env in the scratch repo; prints "<repo>|<lab>", warnings to $T/err.
# The given VAR=value pairs are the CALLER'S environment (e.g. a stale export from `. ./.env`).
le() {
  (cd "$T" && env -u "$REPO_PIN" -u "$LAB_PIN" -u _VKS_PIN_STALE_WARNED -u _VKS_PIN_OVERRIDE_WARNED -u PIN_OVERRIDE "$@" \
     bash -c '. scripts/lib/os.sh; load_env; printf "%s|%s\n" "$'"$REPO_PIN"'" "$'"$LAB_PIN"'"') 2>"$T/err"
}
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$2] got [$3]"; fi; }
err_has() { grep -q -- "$1" "$T/err"; }
STALE_SHELL=("$REPO_PIN=0.0.1" "$LAB_PIN=0.0.2")   # what `set -a; . ./.env` leaves exported

echo "== no .env: both pins come from .env.example, no warning"
rm -f "$T/.env"
chk "no .env" "${REPO_X}|${LAB_X}" "$(le)"
if err_has IGNORED; then bad "warned with no .env"; else ok "no warning"; fi

echo "== .env holds OLD values: repo pin follows .env.example (named in a warning), lab pin is held"
printf '%s=0.0.1\n%s=0.0.2\n' "$REPO_PIN" "$LAB_PIN" > "$T/.env"
chk "old .env" "${REPO_X}|0.0.2" "$(le)"
if err_has "${REPO_PIN}=0.0.1 (repo: ${REPO_X})"; then ok "warning names the ignored line"; else bad "no/wrong warning: $(cat "$T/err")"; fi
if err_has "$LAB_PIN"; then bad "warned about a LAB pin, which .env legitimately holds"; else ok "lab pin not warned about"; fi

echo "== a stale value EXPORTED in the shell is never an override (the review's HIGH finding)"
chk "stale shell + stale .env" "${REPO_X}|0.0.2" "$(le "${STALE_SHELL[@]}")"
rm -f "$T/.env"
chk "stale shell, .env line DELETED (as the warning says)" "${REPO_X}|${LAB_X}" "$(le "${STALE_SHELL[@]}")"
(cd "$T" && bash scripts/02-env.sh init >/dev/null 2>&1)
chk "stale shell, fresh env-init .env" "${REPO_X}|${LAB_X}" "$(le "${STALE_SHELL[@]}")"
chk "stale shell, SKIP_DOTENV=1 (e2e reproducing a fresh box)" "${REPO_X}|${LAB_X}" "$(le SKIP_DOTENV=1 "${STALE_SHELL[@]}")"
printf '%s=0.0.9\n' "$LAB_PIN" > "$T/.env"
chk "lab pin EDITED in .env beats a stale shell" "${REPO_X}|0.0.9" "$(le "${STALE_SHELL[@]}")"

echo "== PIN_OVERRIDE is the per-run override, for both classes, and it is announced"
printf '%s=0.0.1\n%s=0.0.2\n' "$REPO_PIN" "$LAB_PIN" > "$T/.env"
chk "PIN_OVERRIDE" "9.9.9|7.7.7" "$(le "PIN_OVERRIDE=${REPO_PIN}=9.9.9 ${LAB_PIN}=7.7.7")"
if err_has "PIN_OVERRIDE in effect for this run: ${REPO_PIN}=9.9.9 ${LAB_PIN}=7.7.7"; then ok "announced"; else bad "not announced: $(cat "$T/err")"; fi
le "PIN_OVERRIDE=NOT_A_PIN=1" >/dev/null
if err_has "NOT_A_PIN(NOT a version pin"; then ok "a non-pin key in PIN_OVERRIDE is named, not silently used"; else bad "non-pin key not reported: $(cat "$T/err")"; fi

echo "== PIN_OVERRIDE parsing (round-2 review): tab/newline separators, KEY=, duplicates, globs"
TWO_REPO="$(grep -B1 -E '^[A-Z_]+_VERSION=' "$T/.env.example" | grep -A1 '^# renovate:' | grep -oE '^[A-Z_]+_VERSION' | grep -v "^${REPO_PIN}$" | head -1)"
chk_pair() {   # chk_pair <label> <PIN_OVERRIDE value>: want REPO_PIN=1.1.1 and TWO_REPO=v9, no whitespace
  local got
  got="$(cd "$T" && env -u "$REPO_PIN" -u "$TWO_REPO" -u _VKS_PIN_OVERRIDE_WARNED PIN_OVERRIDE="$2" \
         bash -c '. scripts/lib/os.sh; load_env; printf "[%s][%s]" "$'"$REPO_PIN"'" "$'"$TWO_REPO"'"' 2>"$T/err")"
  chk "$1" "[1.1.1][v9]" "$got"
}
rm -f "$T/.env"
chk_pair "tab-separated"     "${REPO_PIN}=1.1.1"$'\t'"${TWO_REPO}=v9"
chk_pair "newline-separated" "${REPO_PIN}=1.1.1"$'\n'"${TWO_REPO}=v9"
chk "KEY= is ignored (repo value kept)" "${REPO_X}|${LAB_X}" "$(le "PIN_OVERRIDE=${REPO_PIN}=")"
if err_has "${REPO_PIN}=(no value"; then ok "KEY= is named, not silently dropped"; else bad "KEY= not reported: $(cat "$T/err")"; fi
chk "duplicate KEY: the LAST value wins" "2.2.2|${LAB_X}" "$(le "PIN_OVERRIDE=${REPO_PIN}=1.1.1 ${REPO_PIN}=2.2.2")"
if err_has "given twice"; then ok "the duplicate is announced"; else bad "duplicate not reported: $(cat "$T/err")"; fi
le "PIN_OVERRIDE=*" >/dev/null
if err_has "\*(no value"; then ok "a glob is not expanded against the current directory"; else bad "glob handling: $(cat "$T/err")"; fi

echo "== a stale repo pin in the legacy .env.kind overlay is caught too"
rm -f "$T/.env"; printf '%s=0.0.3\n' "$REPO_PIN" > "$T/.env.kind"
chk "legacy overlay" "${REPO_X}|${LAB_X}" "$(le)"
if err_has "${REPO_PIN}=0.0.3"; then ok "overlay value named in the warning"; else bad "overlay not warned: $(cat "$T/err")"; fi
rm -f "$T/.env.kind"

echo "== warn once per process tree"
printf '%s=0.0.1\n' "$REPO_PIN" > "$T/.env"
le _VKS_PIN_STALE_WARNED=1 >/dev/null
if err_has IGNORED; then bad "warned again with _VKS_PIN_STALE_WARNED=1"; else ok "silent when already warned"; fi
le _VKS_PIN_OVERRIDE_WARNED=1 >/dev/null
if err_has IGNORED; then ok "a parent's PIN_OVERRIDE notice does not silence a stale-pin warning"; else bad "stale warning suppressed by the override flag"; fi

echo "== env-init: repo pins written commented, lab pins active"
rm -f "$T/.env"
(cd "$T" && bash scripts/02-env.sh init >/dev/null 2>&1)
if grep -qE "^# ${REPO_PIN}=" "$T/.env" && ! grep -qE "^${REPO_PIN}=" "$T/.env" && grep -qE "^${LAB_PIN}=" "$T/.env"; then
  ok "repo pin commented, lab pin active in the new .env"
else bad "env-init output: $(grep -nE "${REPO_PIN}|${LAB_PIN}" "$T/.env" | head -3 | tr '\n' ' ')"; fi

echo "== check-pin-classes"
gate() { (cd "$T" && PIN_CLASSES_FILE="$1" bash scripts/check-pin-classes.sh) >"$T/gate" 2>&1; }
gate_red() {   # gate_red <label> <file> <message>
  if gate "$2"; then bad "$1 passed"; elif grep -q -- "$3" "$T/gate"; then ok "RED: $1"; else bad "$1 failed for another reason: $(tail -1 "$T/gate")"; fi
}
if gate "$T/.env.example"; then ok "the shipped .env.example passes"; else bad "shipped file fails: $(tail -2 "$T/gate")"; fi
printf '# renovate: datasource=x depName=y\nA_VERSION=1\n# pin: lab\nB_VERSION=2\nC_TAG=3\n' > "$T/f1"
gate_red "an unowned pin" "$T/f1" 'C_TAG is a version pin with no owner'
printf '# renovate: datasource=x depName=y\nA_VERSION=1\n# pin: lab\n# a comment in between\nB_VERSION=2\n' > "$T/f2"
gate_red "a dangling '# pin: lab'" "$T/f2" 'marks no key'
printf '# pin: lab\nB_VERSION=2\n# renovate: datasource=x depName=y\n\nA_VERSION=1\n' > "$T/f3"
gate_red "a dangling '# renovate:'" "$T/f3" 'marks no key'
printf '# renovate: datasource=x depName=y\nA_VERSION=1\n# renovate: datasource=x depName=z\nSOME_IMAGE=r:1\n' > "$T/f4"
gate_red "'# renovate:' over a non-version key" "$T/f4" 'SOME_IMAGE has a'

echo "test-env-pins: ${n} checks"
[ "$fail" -eq 0 ] && { echo "test-env-pins: OK"; exit 0; }
echo "test-env-pins: FAILED"; exit 1
