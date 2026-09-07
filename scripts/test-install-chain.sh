#!/usr/bin/env bash
# test-install-chain.sh — pin check-install-chain.sh's RED (B539).
# ci-tier: fast — offline; operates on a COPY of the repo, never the real tree.
#
# ⚠️ THE TWO CASES A NAIVE IMPLEMENTATION MISSES ARE 1 AND 2, and both were live here:
#   1. a SORT/SET compare passes on REORDERED links. Order is the contract — install-all's
#      prerequisites are a LIST.
#   2. a scope keyed on ` -> ` + a `#` comment + `docs/` is blind to CLAUDE.md's copy on THREE
#      axes at once (not under docs/, a UNICODE arrow, no `#`) — and CLAUDE.md is the copy that
#      matters most, because it is re-injected into every subagent. Prototyped, that scope was
#      GREEN over an 11-day-old live drift that was missing FIVE targets including `build-apps`,
#      the one B539 was filed for.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO="$PWD"

p=0; f=0
ok()  { p=$((p+1)); printf 'ok    %s\n' "$1"; }
bad() { f=$((f+1)); printf 'FAIL  %s\n' "$1" >&2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# A COPY: every mutation below is destructive, and the real tree must never be one of them.
mkdir -p "$T/scripts" "$T/docs"
cp "$REPO/Makefile" "$T/Makefile"
cp "$REPO/CLAUDE.md" "$T/CLAUDE.md"
cp -r "$REPO/scripts/lib" "$T/scripts/lib"
cp "$REPO/scripts/check-install-chain.sh" "$T/scripts/"
for d in docs/scenario-1.md docs/scenario-2.md; do [ -f "$REPO/$d" ] && cp "$REPO/$d" "$T/$d"; done

run() { OUT="$( cd "$T" && ./scripts/check-install-chain.sh 2>&1 )"; RC=$?; }
restore() { cp "$REPO/CLAUDE.md" "$T/CLAUDE.md"; cp "$REPO/Makefile" "$T/Makefile"; }

# POSITIVE CONTROL FIRST: if the clean copy is not GREEN, every mutation below is meaningless.
run
if [ "$RC" -eq 0 ]; then ok "CONTROL: the clean tree is GREEN"
else bad "CONTROL: the clean tree is already RED — every case below is vacuous. $OUT"; fi

# ...and it must actually SCAN the unicode/no-# copy, or its green means nothing.
if printf '%s' "$OUT" | grep -q 'CLAUDE.md'; then
  ok "CONTROL: CLAUDE.md IS scanned (unicode arrow, no '#', not under docs/)"
else
  bad "CONTROL: CLAUDE.md was NOT scanned — the gate is blind to the copy that matters most"
fi

_m() { # _m <label> <sed-expr> <file>
  sed -i "$2" "$T/$3"; run
  if [ "$RC" -ne 0 ]; then ok "$1"; else bad "$1 — stayed GREEN"; fi
  restore
}
_m "reorder two links -> RED (a sort compare would pass)" \
   's/preflight → selfbuilt-image → mirror/preflight → mirror → selfbuilt-image/' CLAUDE.md
# shellcheck disable=SC2016  # the sed script edits a markdown CODE SPAN, so it must contain
# literal backticks; single quotes are REQUIRED here (double quotes would COMMAND-SUBSTITUTE them).
_m "delete one link -> RED"          's/ → build-apps`/`/' CLAUDE.md
_m "duplicate a link -> RED"         's/→ gitops → build-apps/→ gitops → gitops → build-apps/' CLAUDE.md
_m "a target added to the MAKEFILE only -> RED (the historical failure)" \
   's/^install-all: preflight/install-all: preflight zz-new/' Makefile

# ⚠️ THE LHS SANITY GATE. Forgetting the '##' strip yields ~49 tokens instead of 12 and then BOTH
# correct docs go RED — with a message that reads as a DOC defect and sends the fixer to the wrong
# file. The gate must name ITSELF as the fault instead.
sed -i 's/ *sed .s\/\^install-all: \*\/\/; s\/ \*##\.\*\/\/./ sed "s|^install-all: *||"/' "$T/scripts/check-install-chain.sh" 2>/dev/null || true
run
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'fault in THIS GATE'; then
  ok "a broken LHS extraction blames the GATE, not the documents"
elif [ "$RC" -eq 0 ]; then
  ok "the LHS extraction could not be broken by this mutation (sanity gate untested here)"
else
  bad "a broken LHS extraction blamed the DOCUMENTS — the fixer goes to the wrong file. $OUT"
fi
cp "$REPO/scripts/check-install-chain.sh" "$T/scripts/"

# NEGATIVE CONTROLS. Each is excluded for a written reason; if any is scanned the gate has 4 false
# REDs in 7 hits and gets deleted.
run
for excl in BACKLOG.md docs/reviews Makefile; do
  if printf '%s' "$OUT" | grep -q "$excl"; then
    bad "negative control: $excl is being scanned (it is excluded for a reason)"
  else
    ok "negative control: $excl is not scanned"
  fi
done

printf '\n%s\n' "test-install-chain: $p passed, $f failed"
[ "$f" -eq 0 ] || exit 1
