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

# ── THE EXCLUSIONS MUST BE TESTED WITH THE FILES PRESENT AND STALE ──────────────────────────────
# ⚠️ CORRECTED 2026-09-07 by a session-end round: the previous "negative controls" never copied
# BACKLOG.md or docs/reviews/ into the fixture, so they asserted the ABSENCE OF A FILE, not the
# exclusion — they passed identically with every exclusion DELETED. A control that passes when the
# thing it guards is removed is not a control. These plant a DELIBERATELY STALE chain in each.
mkdir -p "$T/docs/reviews"
# ⚠️ EACH PLANTED LINE MUST CONTAIN THE LITERAL `install-all`. The producer is
# `grep -rnI 'install-all'`, so a line without it is never a hit and the control is VACUOUS —
# measured: the first version of these two lines omitted it, and the case passed with the
# BACKLOG.md exclusion DELETED (verified the deletion landed, 1 -> 0 occurrences, before believing
# the green). A control that passes when the thing it guards is removed is not a control.
printf 'B999: install-all used to read preflight -> mirror -> gitops -> build-apps; it drifted.\n' > "$T/BACKLOG.md"
printf 'On 2026-07-14 install-all read preflight -> mirror -> gitops -> build-apps (stale).\n' > "$T/docs/reviews/audit.md"
run
if [ "$RC" -eq 0 ]; then ok "a STALE chain in BACKLOG.md and docs/reviews/ is excluded (files PRESENT)"
else bad "the exclusions must hold with the files present and stale — rc=$RC:
$(tail -3 "$T/.out" 2>/dev/null)"; fi
rm -f "$T/BACKLOG.md" "$T/docs/reviews/audit.md"

# ── AN UNRELATED ARROW CHAIN ON AN install-all LINE MUST BE SKIPPED, NOT ACCUSED ────────────────
# The gate triggers on "mentions install-all AND carries 4 arrow-joined tokens", which is NOT the
# same as "is a copy of install-all's prerequisite list". Measured false REDs before the fix:
#   "the demo flow is push -> tekton -> argocd -> browser", the sneakernet sequence, an ingress
#   sequence. Their only remedy would be rewriting a CORRECT sentence into a wrong one.
printf 'After install-all, the demo flow is push -> tekton -> argocd -> browser.\n' > "$T/unrelated.md"
run
if [ "$RC" -eq 0 ]; then ok "an UNRELATED arrow chain beside install-all is skipped, not accused"
else bad "a chain that does not start with install-all's first prereq must be SKIPPED — rc=$RC:
$(tail -3 "$T/.out" 2>/dev/null)"; fi
rm -f "$T/unrelated.md"

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

# NEGATIVE CONTROLS — kept, but they are the WEAK half and now say so. They assert the exclusions
# are not scanned; the STRONG version (files present and STALE) is the case above, which is what
# actually fails if an exclusion is deleted.
# ⚠️ `Makefile` is NOT listed. It was, and it measured NOTHING: the producer is
# `grep --include='*.md'`, so a Makefile can never be a hit, and the gate's dead `*/Makefile` arm
# has been removed. A control over an unreachable path is not a control.
# ⚠️ The figure here used to read "4 false REDs in 7 hits". It did not reproduce: applying the
# gate's own extractor tree-wide gives 6 chain-bearing hits, 3 of them excluded — 3 in 6.
run
for excl in BACKLOG.md docs/reviews; do
  if printf '%s' "$OUT" | grep -q "$excl"; then
    bad "negative control: $excl is being scanned (it is excluded for a reason)"
  else
    ok "negative control: $excl is not scanned (weak arm — the stale-file case above is the strong one)"
  fi
done

printf '\n%s\n' "test-install-chain: $p passed, $f failed"
[ "$f" -eq 0 ] || exit 1
