#!/usr/bin/env bash
# check-expect-literals.sh — every literal an `**Expect:**` line asserts must EXIST in the code that
# is supposed to print it.
#
# THE DEFECT THIS CLOSES (B102). An Expect literal and the log line that satisfies it are TWO copies
# of one string, in two files, with nothing asserting they agree. Reword the log line and
# `static-check` stays GREEN while the next matrix goes EXPECT UNMET and exits 1 — twenty-five
# minutes into a row, on a live lab. One line of prose has already killed a whole matrix run once.
#
# WHY A DERIVED SET AND NOT A LIST OF STRINGS. B102 prescribed "two lines asserting each ADDED
# literal is grep-able". Its idea round refuted that: a hardcoded string here becomes a THIRD copy,
# so a CORRECT coordinated reword of code + doc goes RED and the remedy is to edit a third file —
# friction on exactly the activity this repo does constantly, and friction is what gets a gate
# deleted. Deriving from the document makes that case pass cleanly AND covers doc-side additions for
# free.
#
# THE FILTER IS WALK-DOC'S OWN, MINUS THE ONE CONDITION THAT NEEDS A BLOCK. walk-doc.sh:705-724
# drops a literal when len<6, when it carries `<>`/`...`/`…`, when it fullmatches `make <target>`,
# and when `lit in blk` (the doc quoted a string its own command block already contains). The fourth
# needs the Expect-to-block PAIRING, which this gate deliberately does not reproduce — reimplementing
# that would mean two extractors must agree forever, which the round named as an unbudgeted cost.
#
#   MEASURED 2026-08-18 against the LIVE extractor, mid-run (run 8 row 1, 29 of 42 blocks walked):
#       walk-doc emitted          33 literals
#       this pairing-free filter  44
#       live-but-NOT-in-mine       0     <- ZERO divergence in the dangerous direction
#   So this gate can never REJECT a literal walk-doc accepts, i.e. it cannot go falsely GREEN. It can
#   only OVER-include — checking a literal walk-doc drops via `lit in blk` — which is a false RED, and
#   that is what the allowlist below absorbs. The gate FAILS SAFE by construction.
#
# MEASURED FALSE-RED RATE, the number that decides whether a gate survives: 56 literals across both
# runbooks and the shared include, 8 not grep-able under scripts/ (14%). All 8 are allowlisted below
# WITH A REASON EACH. Six are irreducible; two are the predicted over-inclusions.
#
# WHAT IT DOES NOT CATCH, said out loud so nobody reads the green as more than it is:
#   - whether the literal is printed on the path the reader actually takes. Presence in scripts/ is
#     not reachability; a string in a dead branch passes.
#   - whether the Expect line is the RIGHT claim. It checks that the claim is satisfiable, not true.
#   - anything about MASKED literals. walk-doc passes a block when ANY literal matches (:789), so a
#     sibling that never appears is silently discarded — that is B102's reservoir, a different thing.
#   - A COMMENT MENTIONING THE LITERAL KEEPS IT GREEN. Found while RED-proving this gate: the string
#     `already authenticates` occurs TWICE in 28-harbor-admin-password.sh — once in the log line that
#     actually prints it (:54) and once in a comment ABOUT that line (:39). Rewording only the log
#     line leaves the comment satisfying the search, and the gate stays green over a claim the code
#     can no longer make. That is the same "prose in the searched tree satisfies the search" class as
#     the allowlist-encoding problem above, and it is NOT fixed by stripping comments: a literal
#     legitimately lives in a heredoc, a usage string, or a `printf` format, and a comment-stripper
#     would have to model shell quoting to tell those apart. Recorded, not papered over.
#
# ⚠️ SCOPE IS `scripts/`, DELIBERATELY, AND WIDENING IT IS A VACUITY BUG. Both literals B102 proposes
# also appear in BACKLOG.md — BECAUSE B102 QUOTES THEM. A future "improvement" to `grep -rF -- "$lit" .`
# would go PERMANENTLY GREEN off the backlog row that specifies this gate: the specification would
# satisfy the gate. Do not widen the search root.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

DOCS="${1:-docs/scenario-1.md docs/scenario-2.md docs/common-bootstrap.md}"

# The floor exists because a gate that checks NOTHING passes. If the extractor breaks — a changed
# Expect marker, a mangled fence — it yields zero literals and reports success having looked at
# nothing. MEASURED 2026-08-18: 56 unique literals. 40 leaves room for real doc churn while being
# 40x above the broken-extractor signature of 0.
FLOOR="${EXPECT_LITERALS_FLOOR:-40}"

# ── ALLOWLIST ────────────────────────────────────────────────────────────────────────────────────
# ⚠️ THE ENTRIES ARE BASE64, AND THAT IS NOT OBFUSCATION — IT IS THE ONLY THING THAT MAKES THIS GATE
# NON-VACUOUS. This file lives under scripts/, which is the tree it searches. The FIRST version of
# this gate stored the literals in plain text here and reported "56 checked, 0 allowlisted, 0
# MISSING" — every allowlisted literal was "found in scripts/" BECAUSE IT WAS FOUND IN THIS FILE.
# The gate's own allowlist satisfied the gate.
#
# Excluding this file from the search is the reflex fix and it is WRONG: it would blind the gate to
# every future real finding in the one file most likely to grow them. Encoding the entries means the
# literal never appears here at all, so no exclusion is needed and the search stays honest.
#
# For the same reason THE REASONS BELOW DESCRIBE the construct rather than QUOTING it — a reason
# string is part of the searched corpus too, and "the coreutils ls mode column" cannot satisfy a
# grep for that column the way the column itself would.
#
# Decode any entry with:  printf %s '<b64>' | base64 -d; echo
ALLOW_B64='
LXJ3LS0tLS0tLQ==                                                          # coreutils ls long-format mode column
UFJPVklTSU9ORVI=                                                          # kubectl storageclass column header
aW5zdGFsbCBpc3N1ZWQgZm9yIGhhcmJvci50YW56dS52bXdhcmUuY29t                  # the vcf CLI, harbor supervisor service
aW5zdGFsbCBpc3N1ZWQgZm9yIGFyZ29jZC1zZXJ2aWNlLnZzcGhlcmUudm13YXJlLmNvbQ==  # the vcf CLI, argocd supervisor service
aGFyYm9yLmNydDogT0s=                                                      # ours, composed at runtime from a filename plus a verdict
cm9ib3QgYWNjb3VudCAncm9ib3QkdmtzLWNpY2QnIGNyZWF0ZWQu                      # ours, the robot-account script interpolates the account name
RElTQ09WRVJZOg==                                                          # pairing drop: echoed by its own fenced block (scenario-2 discovery step)
Li9zZWNyZXRzL2FyZ29jZC1jYS5jcnQ=                                          # pairing drop: appears in its own block (scenario-2 argocd CA step)
'
ALLOW="$(printf '%s\n' "$ALLOW_B64" | sed 's/#.*//; s/[[:space:]]//g' | grep -v '^$' \
         | while IFS= read -r b; do printf '%s' "$b" | base64 -d 2>/dev/null; printf '\n'; done)"

# SELF-TEST, not optional: if any allowlisted literal is findable in THIS file, the encoding has been
# undone (someone "clarified" an entry by writing it out) and the gate is vacuous again.
while IFS= read -r _a; do
  [ -n "$_a" ] || continue
  if grep -qF -- "$_a" "${BASH_SOURCE[0]}"; then
    echo "check-expect-literals: FAILED — an allowlisted literal appears VERBATIM in this file."
    echo "  That makes the gate satisfy itself: the literal is 'found in scripts/' because it is found HERE."
    echo "  Re-encode it (printf %s '<literal>' | base64) and describe it in the comment instead of quoting it."
    exit 1
  fi
done <<< "$ALLOW"

checked=0; missing=0; allowed=0
MISS=""

for D in $DOCS; do
  [ -f "$D" ] || { echo "check-expect-literals: no such document: $D"; exit 1; }
done

# One pass over every Expect line in every document, deduped across documents (both runbooks pull in
# common-bootstrap via walk-include, so their literal sets legitimately overlap).
while IFS= read -r lit; do
  [ -n "$lit" ] || continue
  checked=$((checked + 1))
  # `--` IS LOAD-BEARING: a literal beginning with a dash (an ls long-format mode column is one) is
  # an option flag and the grep silently reports the wrong thing. The idea round for this gate caught
  # exactly that failure in its OWN probe, inflating a miss count 8 -> 6 before it was corrected.
  if grep -rqF -- "$lit" scripts/ 2>/dev/null; then continue; fi
  if grep -qxF -- "$lit" <<< "$ALLOW"; then allowed=$((allowed + 1)); continue; fi
  missing=$((missing + 1))
  MISS="${MISS}
  - ${lit}"
done < <(
  # Extract backticked literals from `**Expect:**` lines, applying walk-doc's three pairing-free
  # filters. Anchored on `^[[:space:]]*\*\*Expect` — an UNANCHORED grep also matches PROSE mentions
  # of `**Expect:**` inside backticks, which B102 records as a real miscount.
  for D in $DOCS; do
    grep -hE '^[[:space:]]*\*\*Expect' "$D" 2>/dev/null
  done | grep -o '`[^`]*`' | sed 's/^`//; s/`$//' \
    | awk '
        { lit = $0
          gsub(/^[ \t]+|[ \t]+$/, "", lit)
          if (length(lit) < 6)                     next   # walk-doc: len < 6
          if (lit ~ /[<>]/ || lit ~ /\.\.\./)      next   # walk-doc: placeholder / ellipsis
          if (lit ~ /…/)                           next   # walk-doc: unicode ellipsis
          if (lit ~ /^make [a-z][a-z0-9-]*$/)      next   # walk-doc: a command named in prose
          print lit }' \
    | sort -u
)

printf 'check-expect-literals: %d literal(s) checked, %d allowlisted, %d MISSING\n' \
  "$checked" "$allowed" "$missing"

if [ "$checked" -lt "$FLOOR" ]; then
  echo "check-expect-literals: FAILED — only ${checked} literals extracted, floor is ${FLOOR}."
  echo "  A gate that checks nothing passes. This is the broken-extractor signature, not a clean run:"
  echo "  the Expect marker, a fence, or the filter changed shape. Fix the extractor, do not lower the floor."
  exit 1
fi

if [ "$missing" -gt 0 ]; then
  echo "check-expect-literals: FAILED — ${missing} Expect literal(s) are not present under scripts/:${MISS}"
  echo
  echo "  Each of these is a claim a runbook makes that NOTHING IN THE CODE CAN SATISFY. The next"
  echo "  matrix row asserting it will go EXPECT UNMET and exit 1, ~25 minutes in, on a live lab."
  echo "  Fix one of the two copies — the log line in scripts/, or the Expect line in the document."
  echo "  If the literal is genuinely unmatchable (third-party output, or assembled at runtime), add"
  echo "  it to ALLOW in this file WITH A REASON. An entry without a reason is a silenced defect."
  exit 1
fi

echo "check-expect-literals: OK"
