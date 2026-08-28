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
# ⚠️ EVERY PRUNE GETS A CASE. A first version pinned 5 of 10, and a mutation sweep proved the gap:
# neutering `.git`, `bundle`, `bin`, `.env.state` or `*.tsbuildinfo` left the suite at 18/18 GREEN.
# `bin` is the one that mattered -- it is the broadest name the prune list carries and `bin/` is a
# conventional SOURCE directory, so deleting it cost nothing red.
for d in .claude/state .claude/worktrees/agent-x src/node_modules apps/x/target apps/y/obj secrets \
         .git bundle src/bin; do
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

for f in .env.state x.tsbuildinfo; do
  run record
  : > "$T/$f"
  run verify
  if [ "$RC" -eq 0 ]; then ok "writing $f does NOT fire"
  else bad "$f fired a FALSE RED: $(cat "$OUT")"; fi
  rm -f "${T:?}/$f"
done

# ⚠️ THE EXCLUSION MUST NOT OVERSHOOT. A `-name .claude` prune blinded the two TRACKED files under
# there -- including `.claude/hooks/adversary-first-gate.py`, the BLOCKING control that gates every
# write in this repo and which `test-adversary-gate-rearm.sh` executes, parses and awks INSIDE
# `test-scripts`. MEASURED: touching it mid-run reported OK, rc=0. The two classes that actually
# false-fire are root-anchored, so the prune is path-anchored and `hooks/` stays in scope.
run record
mkdir -p "$T/.claude/hooks"; : > "$T/.claude/hooks/adversary-first-gate.py"
run verify
if [ "$RC" -ne 0 ]; then ok ".claude/HOOKS is still WATCHED — the exclusion did not swallow the blocking control"
else bad "a write to .claude/hooks went unseen; the prune overshot and the detector certifies a run whose security-control input was rewritten"; fi
rm -rf "${T:?}/.claude"

# An unknown argument must FAIL, not be silently ignored: the old bare-positional read made a typo
# (`--requred`) fall through to the by-hand path and exit 0 -- fail-OPEN, from the recipe.
run verify --requred
if [ "$RC" -eq 2 ]; then ok "an unknown argument is REFUSED (a typo used to fail open)"
else bad "verify --requred returned $RC; a typo silently degrades to the by-hand path"; fi

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

# ── THE DENOMINATOR MUST COUNT FILES, NOT LINES. `find -printf '%p'` does not escape a newline in a
# filename, so `wc -l` over-counts -- measured, 3 files reported as 4. The verdict is unaffected
# (`cmp` is byte-exact); the denominator is the only number this control prints, and one that can
# disagree with reality is what this repo keeps getting caught by.
if printf 'a\nb' > "$T/src/$(printf 'two\nline')" 2>/dev/null; then
  run record
  run verify
  # ⚠️ COMPUTE THE EXPECTATION WITH THE BUG ABSENT. A first version used `find … -print | wc -l`,
  # which has the IDENTICAL newline flaw — so it expected 4 and the correct answer 3 read as a
  # failure. `-printf 'x\n'` emits one line per file whatever the name contains.
  _want=$(cd "$T" && find . -type f -printf 'x\n' 2>/dev/null | wc -l | tr -d ' ')
  _got=$(grep -oE 'OK — [0-9]+' "$OUT" | grep -oE '[0-9]+')
  if [ "${_got:-0}" = "$_want" ]; then ok "the denominator counts FILES ($_want) even with a newline in a filename"
  else bad "the denominator says ${_got:-none} for $_want files — it is counting LINES"; fi
  rm -f "$T/src/$(printf 'two\nline')"
else
  printf '  skip  denominator-vs-newline: this filesystem refuses a newline in a filename\n'
fi

# ── THE REAPER IS BOUNDED. `verify` deliberately KEEPS the snapshot on a RED (it is the only
# evidence of the starting tree), so nothing removed them and they accumulated -- measured, 364 KB.
# The reap must take OLD snapshots, leave TODAY's (a RED you may still want to inspect), and be
# unable to touch anything that is not one.
_old="${TMPDIR:-/tmp}/.tree-stability-REAPCASE-old"; _new="${TMPDIR:-/tmp}/.tree-stability-REAPCASE-new"
_other="${TMPDIR:-/tmp}/tree-stability-REAPCASE-not-ours"
: > "$_old"; touch -d '3 days ago' "$_old"; : > "$_new"; : > "$_other"; touch -d '3 days ago' "$_other"
run record
# `if`, not `A && B || C` — that form runs C when B fails too, and this repo bans it outright.
if [ -e "$_old" ];   then bad "a 3-day-old snapshot was NOT reaped; they accumulate"
                    else ok "an OLD snapshot is reaped"; fi
if [ -e "$_new" ];   then ok "TODAY's snapshot survives — a RED stays inspectable"
                    else bad "the reaper destroyed today's evidence"; fi
if [ -e "$_other" ]; then ok "a file that is not one of ours is untouched (the prefix bounds it)"
                    else bad "the reaper deleted a file outside its own prefix"; fi
rm -f "$_old" "$_new" "$_other"

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
