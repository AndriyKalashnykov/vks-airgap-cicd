#!/usr/bin/env bash
# test-tree-stability.sh — pin the detector that refuses a gate's verdict when the tree moved
# underneath it, and pin the two classes of FALSE RED that would get it deleted.
#
# WHY THE FALSE-RED CASES MATTER MORE THAN THE RED ONE. A control that fires on a clean run is a
# control someone turns off, so the cases below are not symmetry -- they are the reason it can ship.
# Both were MEASURED firing on the first implementation:
#
#   .claude/  — Rule Zero MANDATES `isolation:"worktree"` on every adversary, which nests a 467-file
#               checkout under .claude/worktrees/, and adversary-first-gate.py writes a receipt into
#               .claude/state/ on EVERY spawn (31 are already in this checkout). Rule Zero-0's hook
#               demands an adversary be started in the same turn as a long background job -- i.e.
#               exactly during a static-check. Both produced a false RED.
#   nested build output — the first prune list was PATH-ANCHORED (`-path ./node_modules`), so it
#               matched only the root one. In scope on this repo: 1210 files under
#               apps/rust/rustwebapp/target, 601 under apps/nodejs/nodejswebapp/node_modules, 63
#               dotnet obj+bin. An LSP writes into those continuously, with no `make` involved.
#
# HONESTY: this drives the script directly against a THROWAWAY tree. It does not run `make
# static-check`, so it proves the detector's own logic and its prune list -- not the Makefile wiring
# that decides WHEN it runs. That wiring's own property (the verify must still run when a gate
# FAILS) was RED-proven by hand: forcing `lint` to exit 1 and touching a file mid-run still produced
# `THE TREE CHANGED`. Re-prove it the same way if the recipe is edited.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)" || exit 1
# ⚠️ THE CAPTURE FILE LIVES OUTSIDE THE SCANNED TREE. A first version put it at "$OUT", i.e. INSIDE
# the tree under test, so every single run rewrote a file the detector was watching and EVERY case
# false-fired -- including all six prune cases, which then read as "the prunes do not work". The
# instrument was the defect, not the product.
OUT="$(mktemp)"
trap 'rm -rf "$T" "$OUT"' EXIT
mkdir -p "$T/scripts" "$T/src"
cp "$SCRIPT_DIR/tree-stability.sh" "$T/scripts/"
printf 'x\n' > "$T/src/a.txt"

# REPO_ROOT pins the scanned tree; TREE_STABILITY_ID pins the snapshot key so these cases cannot
# collide with each other or with a real run in this checkout.
run() {  # run <record|verify> [--required] -> sets RC
  ( cd "$T" && REPO_ROOT="$T" TREE_STABILITY_ID="test-$$" bash scripts/tree-stability.sh "$@" ) \
    > "$OUT" 2>&1; RC=$?
}

run record
run verify
if [ "$RC" -eq 0 ]; then ok "an UNCHANGED tree passes"
else bad "a tree nobody touched was reported as changed: $(cat "$OUT")"; fi
if grep -q 'file(s) unchanged' "$OUT"; then ok "...and prints its DENOMINATOR (a silent green is indistinguishable from not having run)"
else bad "the pass prints no denominator"; fi

for c in modified:touch added:new removed:gone; do
  what=${c%%:*}
  run record
  case "$what" in
    modified) sleep 0.01; printf 'y\n' >> "$T/src/a.txt" ;;
    added)    : > "$T/src/added.txt" ;;
    removed)  rm -f "$T/src/added.txt" ;;
  esac
  run verify
  if [ "$RC" -ne 0 ]; then ok "a ${what} file is CAUGHT"
  else bad "a ${what} file was NOT caught — the detector is blind to it"; fi
  if grep -q "$what" "$OUT"; then ok "...and the report NAMES it ${what}"
  else bad "the report does not say what happened: $(cat "$OUT")"; fi
done

# ── THE TWO FALSE-RED CLASSES. These are the cases that decide whether it can ship. ───────────────
for d in .claude/state .claude/worktrees/agent-x src/node_modules apps/x/target apps/y/obj secrets; do
  run record
  mkdir -p "$T/$d"; : > "$T/$d/probe"
  run verify
  if [ "$RC" -eq 0 ]; then ok "writing $d does NOT fire (a control that fires on a clean run gets deleted)"
  else bad "$d fired a FALSE RED — this is the class that kills the control: $(cat "$OUT")"; fi
  # Remove ONLY the directory this case made. A first version removed its TOP-LEVEL parent, so the
  # `src/node_modules` case deleted `src/` and took the fixture file with it. `${T:?}` keeps this
  # from ever becoming `rm -rf /…` (SC2115).
  rm -rf "${T:?}/${d}"
done

# ...while a REAL edit beside them still fires, so the prunes did not blind it.
run record
mkdir -p "$T/.claude/state"; : > "$T/.claude/state/receipt"
printf 'z\n' >> "$T/src/a.txt"
run verify
if [ "$RC" -ne 0 ] && grep -q 'a.txt' "$OUT"; then ok "a REAL edit is still caught alongside a pruned write"
else bad "the prunes blinded it: a real source edit went unreported"; fi
rm -rf "${T:?}/.claude"

# ── FAIL-CLOSED WHERE IT MATTERS. ────────────────────────────────────────────────────────────────
# A missing snapshot is benign by hand and a FAILURE from the gate's recipe: there it means the
# record never ran, or ran under a different key, so the verdict cannot be trusted.
rm -f "${TMPDIR:-/tmp}"/.tree-stability-*-"test-$$"
run verify
if [ "$RC" -eq 0 ]; then ok "no snapshot, invoked BY HAND: warns, does not fail"
else bad "a hand invocation with no snapshot failed"; fi
run verify --required
if [ "$RC" -ne 0 ]; then ok "no snapshot, invoked BY THE GATE (--required): FAILS rather than passing silently"
else bad "--required passed with no snapshot — the vacuous green this file exists to prevent"; fi

# The evidence must survive a RED, or the failure cannot be examined.
run record
printf 'q\n' >> "$T/src/a.txt"
run verify
if ls "${TMPDIR:-/tmp}"/.tree-stability-*-"test-$$" >/dev/null 2>&1; then ok "the starting snapshot SURVIVES a RED, so it can be inspected"
else bad "the RED deleted its own evidence"; fi
rm -f "${TMPDIR:-/tmp}"/.tree-stability-*-"test-$$"

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
