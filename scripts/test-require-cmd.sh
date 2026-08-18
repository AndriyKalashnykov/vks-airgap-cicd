#!/usr/bin/env bash
# test-require-cmd.sh — offline, hermetic. Pins the CONTRACT of lib/os.sh's require_cmd.
#
# WHY THIS EXISTS, and it is the most expensive lesson of the night. `require_cmd` is called from 93
# sites and its contract was changed TWICE in one session, each time on a premise that was measured
# only AFTER the change shipped:
#
#   1. It began as `local cmd="$1" hint="${2:-…}"`, so `require_cmd jq curl kubectl` checked ONLY jq,
#      turned "curl" into the hint and DISCARDED "kubectl" — it returned SUCCESS with two of three
#      commands absent.
#   2. The fix was a plain `for cmd in "$@"`, whose comment asserted "SEVEN callers … every one of
#      them was checking a single command". THAT PREMISE WAS FALSE. Measured across scripts/:
#          64 single-arg   ·   21 `<cmd> "<hint>"`   ·   ~8 several BARE command names
#      so the HINT was then checked AS A COMMAND. `require_cmd vcf "install the VCF CLI (make
#      install-vcf-clis) on this jump box"` died with
#          required command 'install the VCF CLI (make install-vcf-clis) on this jump box' not found
#      on a box where vcf was installed and printing its version two blocks earlier.
#
# It was caught by a LIVE six-row certification run, not by any gate — `make vks-login` failed at
# scenario-1 Step 3 and cascaded through the walk. Nothing offline could see it, because no test
# asserted this contract. That is what this file is for.
#
# THE CONTRACT: an argument containing WHITESPACE is the HINT for the command preceding it; every
# other argument is a command that must exist. No command name contains a space and all 21 hints do.
# A single-WORD hint would be misread as a command — there are none, and case 6 pins that boundary.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

BIN="$(mktemp -d)"; trap 'rm -rf "$BIN"' EXIT
mkdir -p "$BIN/bin"
for t in vcf jq; do printf '#!/bin/sh\nexit 0\n' > "$BIN/bin/$t"; chmod +x "$BIN/bin/$t"; done

OUT="$(mktemp)"; trap 'rm -rf "$BIN" "$OUT"' EXIT
# CAPTURE, THEN DECIDE. `require_cmd` calls `die`, which EXITS — so it runs in a subshell whose rc we
# read on its own line. Never `|| rc=$?`: a trailing `||` makes the subshell the LEFT operand of an
# AND-OR list and bash suppresses errexit inside it (see gates.md).
run() { ( export PATH="$BIN/bin:/usr/bin:/bin"; require_cmd "$@" ) >"$OUT" 2>&1; }

echo
echo "════════ require_cmd — the contract, both forms ════════"
echo

# 1. THE REGRESSION that broke a live certification run.
run vcf "install the VCF CLI (make install-vcf-clis) on this jump box"; rc=$?
if [ "$rc" -eq 0 ]; then ok "hint form, command PRESENT -> rc=0 (the hint is NOT checked as a command)"
else bad "hint form must pass when the command exists" "rc=$rc: $(head -1 "$OUT")"; fi

# 2. The hint must still reach the operator — it is the whole reason the second argument exists.
run nosuchtool-xyz "install the thing (make deps)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'install the thing (make deps)' "$OUT"; then
  ok "hint form, command ABSENT -> fails AND quotes the hint"
else bad "must fail and quote the hint" "rc=$rc: $(head -1 "$OUT")"; fi

# 3. THE ORIGINAL BUG: several bare commands, one missing, must NOT silently pass.
run jq curl-absent-xyz; rc=$?
if [ "$rc" -ne 0 ] && grep -q "required command 'curl-absent-xyz'" "$OUT"; then
  ok "multi-command, one ABSENT -> fails and NAMES the missing one"
else bad "a missing later command must not pass" "rc=$rc: $(head -1 "$OUT")"; fi

# 4/5. The unremarkable directions, so a mutant cannot pass by failing everything.
run vcf jq;   rc=$?; if [ "$rc" -eq 0 ]; then ok "multi-command, all present -> rc=0"; else bad "all-present must pass" "rc=$rc"; fi
run jq;       rc=$?; if [ "$rc" -eq 0 ]; then ok "single-arg, present -> rc=0";        else bad "single present"        "rc=$rc"; fi
run nope-xyz; rc=$?; if [ "$rc" -ne 0 ]; then ok "single-arg, absent  -> fails";       else bad "single absent"         "rc=$rc"; fi

# 6. THE BOUNDARY the contract rests on, pinned so a future single-word hint fails HERE and not on a
#    lab. A space-less second argument IS a command by this contract — that is deliberate.
run jq single-word-hint-xyz; rc=$?
if [ "$rc" -ne 0 ]; then ok "a space-LESS second arg is treated as a COMMAND (documented boundary)"
else bad "the boundary moved" "a space-less arg must still be read as a command"; fi

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
