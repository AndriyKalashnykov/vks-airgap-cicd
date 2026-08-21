#!/usr/bin/env bash
# check-doc-prereq-order — a prerequisite must be declared BEFORE the command that needs it.
#
# THE DEFECT THIS EXISTS FOR (README.md, found 2026-08-21 by the owner, not by any gate):
# the bootstrap section told the reader to run `curl -fsSL ... | bash` at line 105, and warned that
# `curl` "must already be present ... Ubuntu 22.04/24.04/26.04 do NOT" at line 129. MEASURED on the
# stock images: bash IS on all three, curl is ABSENT on both Ubuntus. So an Ubuntu reader ran the
# first command, got `curl: command not found`, and met the explanation 24 lines LATER - after the
# wall, which is the one place a prerequisite is worth nothing.
#
# WHY A GATE AND NOT A NOTE: this is ORDERING, which is invisible to every other check here.
# markdownlint sees valid markdown; the link checkers see resolvable links; check-doc-make-targets
# sees real targets. Every gate was green on a doc whose first instruction could not run.
#
# THE INVARIANT, and it is deliberately narrow: when a doc DECLARES a tool prerequisite in its own
# words, the declaration must precede the first fenced use of that tool IN THE SAME DOC.
#
# NOT ENUMERATED: the tool name is extracted FROM the declaration, so this does not rot as tools are
# added. It only fires on docs that already make the claim - it never invents a prerequisite.
#
# ⚠️ WHAT IT DOES NOT CATCH, said plainly so a green is not over-read: a tool the doc needs and
# NEVER declares (there is nothing to order against), a prerequisite stated in a phrasing outside the
# pattern below, and ordering across DIFFERENT documents. It is a floor, not a proof.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# The declaration shapes actually used in this repo's docs. Adding a shape is a deliberate act.
DECL='must already be present|must be installed first|needs .* before you can|is NOT on a bare'

rc=0; checked=0; docs=0
while IFS= read -r doc; do
  [ -n "$doc" ] || continue
  docs=$((docs+1))
  # Each declaration line: its number, and the tool it names (first backticked token on the line).
  while IFS=: read -r dline dtext; do
    [ -n "$dline" ] || continue
    # shellcheck disable=SC2016  # the backticks are LITERAL markdown, not command substitution
    tool="$(printf '%s' "$dtext" | grep -oE '`[a-z][a-z0-9_.-]*`' | head -1 | tr -d '`')"
    [ -n "$tool" ] || continue
    checked=$((checked+1))
    # First use of that tool INSIDE a fenced block, as a command word.
    use="$(awk -v t="$tool" '
      /^```/ { inb = !inb; next }
      inb && $0 ~ ("(^|[;&|(]|[[:space:]])" t "([[:space:]]|$)") { print NR; exit }
    ' "$doc")"
    [ -n "$use" ] || continue
    if [ "$use" -lt "$dline" ]; then
      echo "ERROR: ${doc}: '${tool}' is USED in a command at line ${use}, but the doc does not declare"
      echo "       it as a prerequisite until line ${dline} - ${dline}-${use} lines too late."
      echo "       A reader who lacks it hits the wall first and finds the explanation afterwards."
      echo "       Fix: move the prerequisite ABOVE the first block that needs it."
      rc=1
    fi
  done < <(grep -nE "$DECL" "$doc" 2>/dev/null || true)
done < <(git ls-files '*.md' | grep -vE '^docs/reviews/' || true)

# A denominator, and a vacuity guard: parsing zero declarations means the extractor is blind, not
# the docs clean - the extract-then-compare class this repo has been bitten by before.
if [ "$checked" -eq 0 ]; then
  echo "ERROR: parsed ZERO prerequisite declarations across ${docs} doc(s) - the extractor is blind."
  exit 1
fi
[ $rc -eq 0 ] && echo "check-doc-prereq-order: OK - ${checked} declared prerequisite(s) across ${docs} doc(s), each declared before first use"
exit $rc
