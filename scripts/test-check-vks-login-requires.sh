#!/usr/bin/env bash
# test-check-vks-login-requires.sh — RED/GREEN for the gate's `vcf context create … </dev/null` check (B734).
#
# The gate used `[^\n]*`, which in ERE means "not a backslash and not the LETTER n": a correct create line
# with a redirect naming a file that contains an `n` BEFORE </dev/null read as missing it (false red).
# Runs the real gate against copies of the repo with 30-vks-login.sh's create line mutated.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); printf 'ok    %s\n' "$1"; }
bad() { n=$((n+1)); printf 'FAIL  %s\n' "$1" >&2; fail=1; }

gate_on() {  # gate_on <label> <sed-expr on 30's create line> -> sets R
  rm -rf "$T/r"; mkdir -p "$T/r"; cp -a "$REPO/scripts" "$T/r/"
  if [ -n "$2" ]; then
    sed -i "$2" "$T/r/scripts/30-vks-login.sh"
    grep -q 'MUTATED' "$T/r/scripts/30-vks-login.sh" || { bad "$1: the mutation did not apply"; R=99; return; }
  fi
  R=0; bash "$T/r/scripts/check-vks-login-requires.sh" >/dev/null 2>&1 || R=$?
}

gate_on "unchanged tree" ""
[ "$R" = 0 ] && ok "the real tree passes" || bad "the real tree fails the gate (rc=$R)"

# a redirect naming a file with an `n` BEFORE </dev/null — the old class false-redded exactly this
gate_on "n-bearing redirect" 's#vcf context create "${create_args\[@\]}" </dev/null 2>"$_vcf_err"#vcf context create "${create_args[@]}" 2>"$errn" </dev/null \# MUTATED#'
[ "$R" = 0 ] && ok "a redirect with an 'n' before </dev/null still passes" || bad "false red on a correct create line (rc=$R)"

# </dev/null removed — the gate must go red
gate_on "no </dev/null" 's#vcf context create "${create_args\[@\]}" </dev/null 2>"$_vcf_err"#vcf context create "${create_args[@]}" 2>"$_vcf_err" \# MUTATED#'
[ "$R" != 0 ] && [ "$R" != 99 ] && ok "a create without </dev/null is red (rc=$R)" || bad "the gate missed a create that can prompt (rc=$R)"

if [ "$fail" = 0 ]; then echo "test-check-vks-login-requires: ALL PASS ($n)"; else echo "test-check-vks-login-requires: FAILED" >&2; exit 1; fi
