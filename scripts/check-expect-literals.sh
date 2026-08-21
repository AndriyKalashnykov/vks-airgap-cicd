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
#   - A COMMENT MENTIONING THE LITERAL KEEPS IT GREEN — MEASURED RATE 3 of 48 (6.25%) of currently
#     PASSING literals are satisfied ONLY by comment lines. Two are prose (one of them a comment
#     quoting the runbook's own command, which is circular); the third was a real allowlist case
#     hiding in plain sight — its printer interpolates a variable, so the literal can never appear
#     in the source at all, and it is now an ALLOW entry with that reason rather than silently green.
#     Separately: Found while RED-proving this gate: the string
#     one Expect literal occurs TWICE in 28-harbor-admin-password.sh — once in the log line that
#     actually prints it (:54) and once in a comment ABOUT that line (:39). Rewording only the log
#     line leaves the comment satisfying the search, and the gate stays green over a claim the code
#     can no longer make. That is the same "prose in the searched tree satisfies the search" class as
#     the allowlist-encoding problem above, and it is NOT fixed by stripping comments: a literal
#     legitimately lives in a heredoc, a usage string, or a `printf` format, and a comment-stripper
#     would have to model shell quoting to tell those apart. Recorded, not papered over.
#
# WIRING, stated correctly. An earlier version of this header claimed static-check-fast is "gated on
# `code`, so a docs-only PR would never run it". THAT IS FALSE — ci.yml gives static-check-fast no
# `if:` and no `needs:`, with a comment saying so on purpose; the job gated on `code` is
# static-check. Dual-wiring is still right (docs-lint is the local docs path, and belt-and-braces
# costs nothing), but the REASON matters: a false rationale invites a future session to "fix" gating
# that does not exist.
#
# ⚠️ SCOPE IS `scripts/`, DELIBERATELY, AND WIDENING IT IS A VACUITY BUG. Both literals B102 proposes
# also appear in BACKLOG.md — BECAUSE B102 QUOTES THEM. A future "improvement" to `grep -rF -- "$lit" .`
# would go PERMANENTLY GREEN off the backlog row that specifies this gate: the specification would
# satisfy the gate. Do not widen the search root.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# ── THE DOCUMENT SET IS DERIVED, NOT LISTED ──────────────────────────────────────────────────────
# An earlier version hardcoded three paths. That is falsely GREEN on exactly the shape walk-include
# exists to create: add `<!-- walk-include: new-steps.md -->` to a runbook and the walker executes
# that file's Expect lines while this gate never extracts them. The FLOOR cannot catch it either —
# 56 is far above 40, so losing one document's literals still passes.
#
# So the ROOTS are the two documents the matrix actually walks, and their includes are RESOLVED with
# walk-doc.sh's OWN sed (:333) so the include grammar has one definition, not two. DEPTH 1 ONLY,
# matching walk-doc.sh:395, which REFUSES a nested include — going deeper here would check literals
# the walker would never reach.
#
# ⚠️ `"$@"`, NOT `${1:-…}`. The `${1:-…}` form SILENTLY IGNORES `$2..$n`, so the natural multi-arg
# invocation `check-expect-literals.sh docs/scenario-1.md docs/scenario-2.md` checked only the FIRST
# document and reported `44 checked, OK` — above the floor, so nothing complained.
if [ "$#" -gt 0 ]; then ROOTS="$*"; else ROOTS="docs/scenario-1.md docs/scenario-2.md"; fi

# ⚠️ THE ROOT LIST IS ITSELF A HARDCODED LIST, and this header's own anti-hardcoding argument applies
# to it. The assertion below is what stops it rotting: EVERY document carrying a column-0 `**Expect`
# must be a ROOT, or resolved as an include, or named here WITH A REASON. A new runbook that is
# none of those is a RED, not an invisible gap. MEASURED: without this, adding `docs/scenario-3.md`
# with an unsatisfiable claim reports `56 checked, OK` — and the floor cannot see it either, because
# scenario-1 ALONE is 43, which clears 40.
#
# NOT_WALKED is a DECISION, not an oversight. These carry Expect lines and are not walked by the
# six-row matrix, so their literals are prose rather than assertions the harness will enforce:
#   docs/lab-validation-plan.md  a runbook for a manual lab trip; steps are performed by a human
#   docs/sneakernet.md           the two-box flow; not one of the six rows
#   docs/kind-local.md           the KinD stand-in, exercised by `make e2e-kind`, not by a walk
# ⚠️ They are NOT clean: measured, they carry 5 literals nothing under scripts/ satisfies — two are
# REAL doc defects, one is third-party text that would be an ordinary ALLOW entry, and two are a
# DIFFERENT defect class (an `**Expect:**` whose literal is a SOURCE CITATION such as a file:line or
# a line range, which is not a claim about output at all). Widening ROOTS to them is a scope
# decision with a known price, not a free win — see the backlog.
NOT_WALKED="docs/lab-validation-plan.md docs/sneakernet.md docs/kind-local.md"

DOCS="$ROOTS"
for _r in $ROOTS; do
  [ -f "$_r" ] || { echo "check-expect-literals: no such document: $_r"; exit 1; }
  [ -r "$_r" ] || { echo "check-expect-literals: document is not readable: $_r"; exit 1; }
  _incs="$(sed -nE 's|^[[:space:]]*<!--[[:space:]]*walk-include:[[:space:]]*([^[:space:]]+)[[:space:]]*-->[[:space:]]*$|\1|p' "$_r" || true)"
  for _i in $_incs; do
    _p="$(dirname "$_r")/${_i}"
    [ -f "$_p" ] || { echo "check-expect-literals: walk-include names a missing file: ${_i} (from ${_r})"; exit 1; }
    # G2: the SAME mechanism the root `[ -r ]` closes. Measured before this line existed:
    # `chmod 000 docs/common-bootstrap.md` gave `55 checked, 0 MISSING, OK` rc=0 — one literal
    # silently dropped, above the floor, from the file BOTH runbooks share.
    [ -r "$_p" ] || { echo "check-expect-literals: walk-include names an unreadable file: ${_i} (from ${_r})"; exit 1; }
    case " $DOCS " in *" $_p "*) ;; *) DOCS="$DOCS $_p" ;; esac
  done
done

# THE COVERAGE ASSERTION. Only meaningful for the DEFAULT root set — an explicit argument list is a
# deliberate narrowing, so it must not demand whole-tree coverage.
# ⚠️ THE RATIONALE USED TO SAY "the tests use it". THAT WAS FALSE — measured: the ONLY invocation in
# the repo is the bare `make check-expect-literals`. The guard is kept because a future fixture-based
# harness WILL pass roots, not because one does today. And the skip is made AUDIBLE: a silent
# disappearing assertion is the shape this repo bans.
if [ "$#" -ne 0 ]; then
  echo "check-expect-literals: NOTE — explicit roots given, so the whole-tree coverage assertion is SKIPPED"
fi
if [ "$#" -eq 0 ]; then
  # ⚠️ SCOPE, stated so nobody "fixes" either half. (a) The glob is docs/*.md — NOT recursive and NOT
  # repo-root; four subdirectories exist (decisions, diagrams, vks-services, reviews) and MEASURED
  # today none carries an Expect line, so this is latent, not live. (b) The anchor below is COLUMN-0
  # `^\*\*Expect`, deliberately MATCHING walk-doc.sh:440's `startswith('**Expect')`, while the
  # EXTRACTOR further down uses the wider `^[[:space:]]*`. That asymmetry is correct — the walker
  # decides which blocks are checkable by the strict anchor and which literals to pull by the loose
  # one — so do NOT align them.
  _uncovered=""
  for _d in docs/*.md; do
    grep -qE '^\*\*Expect' "$_d" 2>/dev/null || continue
    case " $DOCS $NOT_WALKED " in *" $_d "*) ;; *) _uncovered="${_uncovered} ${_d}" ;; esac
  done
  if [ -n "$_uncovered" ]; then
    echo "check-expect-literals: FAILED — document(s) carry Expect lines but are neither walked nor declared:${_uncovered}"
    echo "  A runbook this gate does not know about is a runbook whose Expect claims nothing checks."
    echo "  Either add it to ROOTS (if a walk executes it), reference it with a walk-include, or add"
    echo "  it to NOT_WALKED above WITH A REASON. An entry without a reason is a silenced gap."
    exit 1
  fi
fi

# The floor exists because a gate that checks NOTHING passes. If the extractor breaks — a changed
# Expect marker, a mangled fence — it yields zero literals and reports success having looked at
# nothing. MEASURED 2026-08-18: 56 unique literals. 40 leaves room for real doc churn while being
# 40x above the broken-extractor signature of 0.
# ⚠️ RAISED WITH B205, and the reason is that the OLD floor could not detect a regression of the
# capability B205 adds. MEASURED: 77 checked before widening, 94 after. At floor 40, a silent
# break of the continuation extraction drops 94 -> 77 and still passes at 1.9x the floor — the
# broken-extractor signature the old value was sized against (0) is NOT the signature this
# change introduces. 85 sits above the un-widened 77, so losing continuations now goes RED.
FLOOR="${EXPECT_LITERALS_FLOOR:-85}"

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
dmlydHVhbG1hY2hpbmVjbGFzcw==                                              # pairing drop: the VM-class
  #     resource named by its OWN fenced block in the scenario-1 VM-class step, so the
  #     lit-in-block filter drops it at runtime and _tot stays 0. It became visible OFFLINE only
  #     when B205 widened this gate to continuation lines; a false RED, not a doc/code
  #     disagreement. The storage-quota resource beside it is the same class and passes today
  #     off a circular comment. NO apostrophes, backticks, or plaintext copies of an encoded
  #     literal in this block: an apostrophe TERMINATES the single-quoted string (measured: it
  #     broke the parse at the done token), and a plaintext copy makes the gate satisfy itself
  #     (measured: the self-test below caught exactly that).
d3JpdGUgbWVjaGFuaXNtOiBhcGk=                                      # ours; the printer INTERPOLATES the mechanism, so this exact
#     string can never appear in the source. It is LIVE and load-bearing: 70-configure-argocd.sh:350
#     used to carry a sample-output comment that satisfied the search, so this entry was inert and
#     the literal was passing VACUOUSLY off a comment. That comment now names the mechanism as a
#     placeholder instead, so the vacuity is REMOVED rather than documented, and deleting this
#     entry gives one MISSING. Measured both ways. (No backticks here: this block is inside a
#     single-quoted string and shellcheck reads them as command substitution, SC2016.)
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
# shellcheck disable=SC2016  # the backticks below are MARKDOWN code-span delimiters we are
                            # searching FOR, not command substitution — single quotes are
                            # exactly right. Same rationale as walk-doc.sh:795, which carries
                            # this directive for the identical markdown-backtick search.
while IFS= read -r lit; do
  [ -n "$lit" ] || continue
  checked=$((checked + 1))
  # ── SELF-SATISFACTION CHECK, and it must come FIRST ─────────────────────────────────────────────
  # This runs BEFORE the scripts/ search on purpose: a literal that appears HERE would be "found in
  # scripts/" BECAUSE IT IS FOUND IN THIS FILE, and the search below would `continue` before any
  # check could notice. The allowlist self-test above covers only the 8 ALLOW entries; this covers
  # EVERY extracted literal, which is the same defect one level wider.
  #
  # MEASURED 2026-08-18: exactly 1 of 56 literals tripped this when it was added — a header sentence
  # that QUOTED an Expect literal while explaining the gate. Rewording that one sentence is the whole
  # remedy; there were zero other hits, so this costs nothing on an honest file.
  #
  # DO NOT "fix" a hit by excluding this file from the search. That blinds the gate to every future
  # real finding in the one file most likely to grow them (same argument as the ALLOW encoding).
  # Reword the prose so it DESCRIBES the literal instead of quoting it.
  # ⚠️ SOLE WITNESS, not "appears anywhere in this file". An earlier version tested only
  # `grep -qF -- "$lit" "${BASH_SOURCE[0]}"`, which ABORTS the whole gate on any literal that merely
  # OCCURS in 60 lines of English header prose — and prints a remedy ("stop quoting it") that does
  # not apply, because nothing was quoted. MEASURED: `docs/sneakernet.md`'s `static` fired it while
  # being satisfiable by 46 real scripts, and the abort HID two genuine missing literals in the same
  # document. 1 of 22 on a real corpus written without knowledge of this gate; 0 of 56 on the shipped
  # roots, so it was latent rather than live.
  #
  # ⚠️ A MINIMUM LENGTH IS REFUTED, twice, by measurement — do not reach for it. Length is not the
  # mechanism: gate-file substrings that are plausible literals run 6 to 26 characters. And DIVERGING
  # the two lengths REOPENS the hole this check exists to close — self-check at >=10 with the search
  # at >=6 lets a 7-character sole-witness literal through as `0 MISSING, OK`.
  #
  # The pipeline is CAPTURED and then TESTED rather than `grep -rlF … | grep -qv …`. That form was
  # measured clean here (160/160 rc=0, including pinned to one core with `taskset -c 0`), so this is
  # NOT a reproduced bug — it is simply the `cmd | grep -q` shape under `pipefail` that this
  # portfolio's shell rules forbid, and the capture form costs nothing.
  # ⚠️ EXACT PATH, NOT A SUBSTRING (G1). `grep -vF 'check-expect-literals.sh'` also removes any file
  # whose NAME CONTAINS this one — most obviously `scripts/test-check-expect-literals.sh`, the
  # RED-proof harness this repo builds for every gate (test-walk-doc.sh, test-ca-staleness-check.sh
  # and test-argocd-preflight-ns.sh all exist). With that harness present and a literal witnessed by
  # BOTH files, the substring form drops both, concludes "this gate's own source is the ONLY thing
  # that satisfies it", and prints a remedy naming the WRONG FILE — a false RED whose message is
  # factually untrue. `-vxF` on the exact path cannot do that.
  _witnesses="$(grep -rlF -- "$lit" scripts/ 2>/dev/null || true)"
  _self_path="scripts/$(basename -- "${BASH_SOURCE[0]}")"
  _others="$(printf '%s\n' "$_witnesses" | grep -vxF -- "$_self_path" || true)"
  if grep -qF -- "$lit" "${BASH_SOURCE[0]}" && [ -z "$_others" ]; then
    echo "check-expect-literals: FAILED — this gate's own source is the ONLY thing under scripts/ that"
    echo "  satisfies an Expect literal:"
    echo "    ${lit}"
    echo "  So that literal passes by finding ITSELF — a vacuous green for exactly one claim, and"
    echo "  invisible in the summary line. Reword the prose HERE to DESCRIBE the string rather than"
    echo "  quote it. Do NOT exclude this file from the search, and do NOT add a minimum length."
    exit 1
  fi
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
  # ── B205: read CONTINUATION lines too — OFFLINE ONLY, and the scope is the whole point ─────────
  # walk-doc.sh's PARSER stays single-line and MUST. Widening it was designed, then REFUTED by its
  # idea round as CERTIFICATION-BLOCKING: docs/scenario-2.md's discovery block flips from _tot=0
  # (not checkable) to _tot=3 with `harbor-nginx`/`HARBOR_URL`/`ARGOCD_SERVER`, none of which can
  # appear on the `else` branch EVERY scenario-2 matrix row takes -> EXPECT UNMET -> exit 1, ~25
  # minutes into a live lab. And that is not an accident: docs/scenario-2.md:216-224 is a dated
  # comment stating those literals are DELIBERATELY on continuation lines, naming PR #696 which got
  # it wrong once, and predicting this exact failure. The design decision lives in the DOCUMENT, not
  # the script — which is why a script-side review misses it.
  #
  # So this gate reads MORE than the parser ON PURPOSE, and the asymmetry is the design:
  #   walk-doc.sh (RUNTIME)          : HEAD only  -> what a matrix row ASSERTS. Unchanged.
  #   check-expect-literals (OFFLINE): head+cont  -> what a claim may REFER to. Widened here.
  # An offline MISSING costs a red gate on a laptop; a runtime UNMET costs a certification row.
  # ⚠️ Therefore the "BYTE-IDENTICAL to walk-doc's extraction" note further down is NO LONGER TRUE
  # for the LINE SET (it remains true for the per-line literal grammar), and test-expect-extraction
  # pins the difference so neither side can drift silently.
  for D in $DOCS; do
    awk '/^[[:space:]]*\*\*Expect/ { print; inx=1; next }
         inx && (/^[[:space:]]*$/ || /^[[:space:]]*```/) { inx=0 }
         inx { print }' "$D" 2>/dev/null
  # ⚠️ `-oE` WITH `+`, NOT `-o` WITH `*` — ONE CHARACTER, AND IT WAS A MEASURED FALSE GREEN.
  # walk-doc.sh:710 is `re.findall(r'`([^`]+)`')`. This started as `[^`]*` (zero-or-more), which on
  # a DOUBLE-backtick code span matches the EMPTY span between the two opening backticks, consumes
  # them, and emits NOTHING — so the literal is silently dropped and the gate goes GREEN while
  # walk-doc reports NOT SEEN. MEASURED by an implementation round: 646 literals missed across 800
  # generated Expect lines, and `checked` STAYED AT 56, so the summary line carried no signal.
  # A balanced double-backtick span is the standard CommonMark way to write a code span containing
  # a backtick, so this is reachable prose, not a fuzz artifact. After the fix the extracted set is
  # BYTE-IDENTICAL to walk-doc's over the real corpus, and 0 missed / 0 extra over the same fuzz.
  done | grep -oE '`[^`]+`' | sed 's/^`//; s/`$//' \
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
