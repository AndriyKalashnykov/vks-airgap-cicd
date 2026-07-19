#!/usr/bin/env bash
# check-doc-novels.sh — a reference/runbook doc states the current FACT (measured/cited), never
# re-litigates the ARC. "This page used to say X … that was FALSE … here's the whole story" is a
# NOVEL: the arc belongs in git history + docs/reviews/*, NOT in the operator-facing doc body.
#
# WHY THIS IS A GATE AND NOT A RULE:
#   The "facts-not-novels" rule was written down and still got violated — four reference cards
#   (docs/vks-services/*) grew multi-paragraph blockquotes re-litigating corrected beliefs. Prose
#   loaded at the start of a session does not fire at the moment text is generated. A check that runs
#   does. This one catches the dominant shape: a MULTI-LINE BLOCKQUOTE that both carries a
#   retrospective marker ("used to say", "was FALSE for …") and a "wrong/false" word.
#
# NOT a semantic judge — a heuristic. A deliberate, reviewed one-line dated correction is legitimate
# (version-discipline: keep a concise anti-re-retraction note). Tag such a block by adding a
# `<!-- arc-ok: YYYY-MM-DD -->` comment as a `>`-prefixed line INSIDE the blockquote; the gate then
# accepts it. That tag is the honest human call the grep cannot make.
#
# SCOPE / KNOWN RESIDUAL: catches the DOMINANT shape — a multi-line BLOCKQUOTE. A re-litigation written
# as a normal (non-blockquote) PARAGRAPH is not caught. Reference-card corrections use blockquotes by
# convention, so this covers the common case; paragraph-form is a phase-2 extension. Fenced code blocks
# (``` / ~~~) are skipped so `>`-prefixed example output (shell prompts, transcripts) is not misread.
#
# PORTABILITY: matches on tolower() of the text, NOT gawk IGNORECASE — the box/CI awk is often mawk
# (mawk IGNORES IGNORECASE, which would make matching case-sensitive and MISS uppercase "FALSE"). All
# patterns below are lowercase for this reason. Verified: mawk 1.3.4 flags all four seed NOVELs.
#
# EXEMPT (skip entirely):
#   - CLAUDE.md          — agent instructions; the anti-re-retraction guard has value there.
#   - docs/reviews/*     — the verbatim arc archive; those files ARE the arc.
#   - docs/decisions/*   — ADR bodies. version-discipline: "append to ADR history, never rewrite it" —
#                          recording the decision arc is what an ADR is for.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# Retrospective RE-LITIGATION markers (a doc TALKING ABOUT WHAT IT USED TO SAY), all lowercase.
# Deliberately EXCLUDED:
#   - 'we then'  — 24/24 hits are the structural '**We then:**' step label in lab-validation-plan.md.
#   - bare 'used to be' — too generic ("this value used to be optional"); the retrospective sense is
#     carried by the stronger verbs below.
#   - bare 'no longer' / 'previously' / 'historically' / 'superseded' — they overwhelmingly describe
#     CURRENT behavior ("X no longer route-checks Y"), not re-litigation.
MARK='used to (say|give|add|list|carry|skip|present|claim|argue|route)|this (table|page|section|note|column|list) (used to|claimed|argued|originally|was)|originally (said|argued|claimed|presented)|earlier (claim|note|session|grading)|a prior session|the premise was|both halves were wrong|for a false reason|once claimed|that (inference|correction|claim|premise|grade) was (wrong|false)'
# A "this was wrong" word that, TOGETHER with a marker in the SAME blockquote, marks re-litigation.
WRONG='wrong|false|misdiagnos|not true|incorrect|a lie'

# Docs to scan: README.md + docs/**/*.md, tracked OR untracked-not-ignored (so a brand-new doc is not
# invisible). Exemptions are applied per-file below.
mapfile -t DOCS < <(git ls-files --cached --others --exclude-standard -- 'README.md' 'docs/*.md' 'docs/**/*.md' 2>/dev/null | sort -u)

is_exempt() {
  case "$1" in
    docs/reviews/*|docs/decisions/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit "<file>:<startline>" for every MULTI-LINE (>=2 line) blockquote block that carries a marker AND
# a wrong-word AND is not arc-ok-tagged. A blockquote block = a maximal run of consecutive lines each
# beginning (after optional spaces) with '>'. Fenced code is skipped. Match on tolower() for mawk.
# Also emits a final `@@BLOCKS:<n>` line — the number of multi-line blockquote BLOCKS this file
# actually offered up for judging. That is the ITEM count, and it is the one that matters: see the
# guard below for why `scanned` (a FILE count) is not enough.
scan_one() {
  awk -v MARK="$MARK" -v WRONG="$WRONG" -v FILE="$1" '
    BEGIN { bn = 0; bq = ""; bstart = 0; infence = 0; blocks = 0 }
    function flush() {
      if (bn >= 2) {
        blocks++
        if (bq ~ MARK && bq ~ WRONG && bq !~ /arc-ok/)
          printf "%s:%d\n", FILE, bstart
      }
      bn = 0; bq = ""; bstart = 0
    }
    /^[[:space:]]*(```|~~~)/ { flush(); infence = !infence; next }
    infence { next }
    /^[[:space:]]*>/ { if (bn == 0) bstart = FNR; bq = bq "\n" tolower($0); bn++; next }
    { flush() }
    END { flush(); printf "@@BLOCKS:%d\n", blocks }
  ' "$1"
}

scanned=0; novels=0; blocks=0
declare -a HITS=()
for f in "${DOCS[@]}"; do
  [ -f "$f" ] || continue
  is_exempt "$f" && continue
  scanned=$((scanned + 1))
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    case "$hit" in
      @@BLOCKS:*) blocks=$(( blocks + ${hit#@@BLOCKS:} )); continue ;;
    esac
    HITS+=("$hit")
    novels=$((novels + 1))
  done < <(scan_one "$f")
done

# A gate that scanned nothing is a BROKEN gate, not a green one — README.md always matches the pathspec,
# so scanned==0 means git ls-files / the pathspec broke (the "passes by not looking" failure mode).
[ "$scanned" -gt 0 ] || die "check-doc-novels: scanned 0 docs — git ls-files/pathspec is broken (README.md must always match)."

# B49 — THE FILE COUNT IS NOT THE ITEM COUNT, and guarding only the former left this gate BLIND.
# MEASURED: empty every tracked .md (leaving them tracked) and the guard above still passed — it
# reported `OK — scanned 21 doc(s)` with rc=0 over a corpus containing NOTHING. `scanned` counts files
# OPENED; `blocks` counts the blockquotes actually EXAMINED, which is the quantity this gate's verdict
# is about. Zero of them across the whole corpus does not mean "clean", it means the extractor found
# nothing to judge — a broken awk, a fence-handling regression, or an empty corpus.
# If a future corpus legitimately has no multi-line blockquotes at all, this dies LOUDLY and someone
# makes a deliberate decision. That is the correct direction for a gate to fail.
[ "$blocks" -gt 0 ] || die "check-doc-novels: examined 0 blockquote block(s) across ${scanned} doc(s) — the file count is healthy but the ITEM count is zero, so this gate judged nothing. Suspect the awk extractor (fences, the '>' match) or an empty corpus."

if [ "$novels" -gt 0 ]; then
  log_error "check-doc-novels: $novels re-litigation blockquote(s) in operator/reference docs (scanned $scanned):"
  for h in "${HITS[@]}"; do printf '  - %s\n' "$h"; done
  echo "  A reference doc states the current FACT, not the ARC. For each: keep the corrected fact and"
  echo "  collapse the 'used to say … that was FALSE …' blockquote to a one-line dated pointer to"
  echo "  git/docs/reviews/*; OR, if it is a deliberate reviewed one-line correction, add a"
  echo "  '<!-- arc-ok: YYYY-MM-DD -->' comment as a '>'-prefixed line INSIDE that blockquote."
  exit 1
fi

log_info "check-doc-novels: OK — examined $blocks blockquote block(s) across $scanned doc(s); no un-tagged re-litigation (docs/reviews/* + docs/decisions/* exempt)."
exit 0
