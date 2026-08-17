#!/usr/bin/env bash
# test-check-tools-sentinel.sh — the .deps-failed sentinel must be surfaced on BOTH all-present paths.
#
# WHY: the sentinel is read in check-tools' MISSING-TOOLS branch, which is unreachable when nothing is
# missing. So on a warm box `make deps` could fail and this gate printed "all REQUIRED tools present."
# in total silence — having just been named BY deps as the thing that would say otherwise.
#
# ⚠️ THERE ARE TWO all-present messages, not one: `PRE-CARRY OK …` (a carried tool still absent) and
# `all REQUIRED tools present.`. Patching only the second leaves the AIR-GAP operator silent — the one
# least able to recover. Cases 3 and 4 exist for that half and are measurably reachable.
#
# ⚠️ Cases 1 and 3 (sentinel ABSENT -> no warning) are the ones people skip. Without them nothing stops
# the warning becoming unconditional, which is how a real signal gets ignored.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A git archive tree, so nothing here can touch the working repo. REPO_ROOT is honoured verbatim by
# lib/os.sh when pre-set, and SKIP_DOTENV=1 keeps .env out of it.
( cd "$REPO" && git archive HEAD ) | tar -x -C "$TMP" || { echo "cannot build the archive tree" >&2; exit 1; }
# ⚠️ OVERLAY THE WORKING TREE. `git archive HEAD` is the COMMITTED tree, so without this the harness
# measures a tree WITHOUT the change under test — measured: cases 2 and 4 failed for exactly that
# reason while the fix sat uncommitted. In CI HEAD == the tree, so the overlay is a no-op there; it is
# what makes the test usable locally, which is where a RED-proof actually gets run.
cp -a "$REPO/scripts/." "$TMP/scripts/" 2>/dev/null || true
[ -f "$REPO/.env.example" ] && cp "$REPO/.env.example" "$TMP/" 2>/dev/null || true

# ⚠️ A THIN shim dir DOES NOT WORK — lib/os.sh needs far more of coreutils than the tool list suggests
# (measured: `have: command not found`). Mirror the WHOLE PATH minus exactly one carried binary.
MINUS_CRANE="$TMP/bin-no-crane"; mkdir -p "$MINUS_CRANE"
( IFS=:; for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b="${f##*/}"; [ "$b" = crane ] && continue
      [ -e "$MINUS_CRANE/$b" ] || ln -sf "$f" "$MINUS_CRANE/$b" 2>/dev/null || true
    done
  done )
if PATH="$MINUS_CRANE" command -v crane >/dev/null 2>&1; then
  bad "the minus-crane PATH still resolves crane — cases 3/4 would be vacuous"
else
  ok "minus-crane PATH really hides crane (so the pre-carry arm is reachable)"
fi

_run() {   # _run <sentinel:yes|no> <phase:full|pre-carry> -> writes $OUT, sets $RC
  if [ "$1" = yes ]; then : > "$TMP/.deps-failed"; else rm -f "$TMP/.deps-failed"; fi
  local p="$PATH"; [ "$2" = pre-carry ] && p="$MINUS_CRANE"
  if [ "$2" = pre-carry ]; then
    OUT="$(cd "$TMP" && PATH="$p" REPO_ROOT="$TMP" SKIP_DOTENV=1 CHECK_TOOLS_PHASE=pre-carry \
           bash "$TMP/scripts/03-check-tools.sh" 2>&1)"; RC=$?
  else
    OUT="$(cd "$TMP" && PATH="$p" REPO_ROOT="$TMP" SKIP_DOTENV=1 \
           bash "$TMP/scripts/03-check-tools.sh" 2>&1)"; RC=$?
  fi
}
_has()  { printf '%s' "$OUT" | grep -qF "$1"; }
WARN='a previous '"'"'make deps'"'"' FAILED'

echo "== .deps-failed must be surfaced on BOTH all-present paths =="

# 1. sentinel ABSENT, full phase -> no warning, the Expect literal intact, rc=0
_run no full
if _has "$WARN"; then bad "1: warned with NO sentinel" "the warning is unconditional"; else ok "1: no sentinel -> no warning"; fi
if _has 'all REQUIRED tools present.'; then ok "1: the scenario-1 Expect literal is intact" \
                                   ; else bad "1: 'all REQUIRED tools present.' missing" "rc=$RC"; fi
if [ "$RC" -eq 0 ]; then ok "1: rc=0"; else bad "1: rc=$RC (must stay 0 — the tools ARE present)"; fi

# 2. sentinel PRESENT, full phase -> warning AND the literal still there (added, never reworded)
_run yes full
if _has "$WARN"; then ok "2: sentinel surfaced on the all-present path (the defect)" \
             ; else bad "2: sentinel NOT surfaced" "this is the silence the row is about"; fi
if _has 'all REQUIRED tools present.'; then ok "2: the Expect literal SURVIVES the added warning" \
                                   ; else bad "2: the warning replaced the literal" "every walk row would UNMET"; fi
if [ "$RC" -eq 0 ]; then ok "2: rc=0 (a present toolchain must not go red)"; else bad "2: rc=$RC" "false negative"; fi

# 3. sentinel ABSENT, pre-carry -> no warning, PRE-CARRY OK present
_run no pre-carry
if _has "$WARN"; then bad "3: warned with NO sentinel (pre-carry)"; else ok "3: pre-carry, no sentinel -> no warning"; fi
if _has 'PRE-CARRY OK'; then ok "3: the pre-carry path is genuinely reached" \
                    ; else bad "3: PRE-CARRY OK absent" "the arm is unreachable; cases 3/4 prove nothing"; fi

# 4. sentinel PRESENT, pre-carry -> warning, and it must NOT prescribe `make deps` on the air-gap box
_run yes pre-carry
if _has "$WARN"; then ok "4: sentinel surfaced on the PRE-CARRY path too (the air-gap operator)" \
             ; else bad "4: pre-carry stays silent" "the half the row's own fix would have missed"; fi
if _has "do NOT run 'make deps'"; then ok "4: pre-carry warning forbids 'make deps' rather than prescribing it" \
                             ; else bad "4: no air-gap caveat" "the sentinel travels with the tar copy; deps needs the internet"; fi
if _has 'PRE-CARRY OK'; then ok "4: PRE-CARRY OK still present"; else bad "4: PRE-CARRY OK lost"; fi

# 5. the doc contract itself, so finding 3 cannot regress silently
if grep -qF 'all REQUIRED tools present.' "$REPO/docs/scenario-1.md"; then
  ok "5: docs/scenario-1.md still carries the Expect literal this gate must keep emitting"
else
  bad "5: the Expect literal is gone from scenario-1.md" "then case 1/2's assertion guards nothing"
fi

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
