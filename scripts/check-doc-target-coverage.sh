#!/usr/bin/env bash
# check-doc-target-coverage.sh — a target an OPERATOR can invoke must be FINDABLE IN A DOC.
#
# WHY THIS GATE EXISTS (it is the mechanical form of a rule that failed twice in one day)
# --------------------------------------------------------------------------------------
# CLAUDE.md already says, in the author's own words: "a capability change is not done until the
# operator docs say so." It did not hold. `make builder-build` / `builder-push` / `e2e-sneakernet-both`
# shipped, were merged, and appeared in NO document a user reads. The sibling failure the same day:
# docs/sneakernet.md existed and was reachable from the README only as a mid-sentence aside in a
# feature bullet — absent from both navigation tables, so nobody could find it.
#
# The cause is always the same: the author writes into the file they are standing in, and never asks
# "which reader does this change, and which of their documents must now say something different?"
# Prose cannot enforce that. A gate can:
#
#   every `##`-documented target in an OPERATOR-FACING `##@` group must be named in README.md or a
#   doc under docs/.
#
# SCOPE BY GROUP, NOT BY A HAND-TYPED LIST OF TARGETS. A list of exempt target NAMES would rot on the
# next rename — the exact defect this repo keeps re-learning (check-image-alignment's hand-typed var
# list slept through a real outage). The `##@` group is a structural property the Makefile already
# carries, so a new CI-internal gate lands in an exempt GROUP automatically and a new operator
# capability does not.
#
# NOT COVERED, deliberately: whether the mention is any GOOD (a bare name in a table is not a runbook
# entry). That is judgment, and a gate that pretends to measure it would be worse than none. This gate
# measures only the floor: it EXISTS somewhere a reader can find it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

# Groups whose targets are CI/gate/test plumbing — an operator never invokes them, and documenting them
# would be noise. The exempt set is the `case` below (one place, not a duplicated variable).

# (group, target, help-text) for every ##-documented target, in Makefile order.
#
# A target whose OWN HELP TEXT declares it a gate or a negative test is exempt — derived from the
# Makefile, not from a hand-typed list of names (which would rot on the next rename, the way
# check-image-alignment's did while a real outage sailed through it). `## Gate: …` is a self-declaration,
# and CI gates are not operator capabilities.
pairs="$(awk '
  # g must NEVER be empty: a target defined BEFORE the first ##@ (like `help:`) would otherwise emit a
  # LEADING TAB, and `read` strips leading IFS whitespace — so the fields shift and the TARGET column
  # silently becomes the help text. (It did: `make help` was reported as an undocumented target named
  # "Show this help".) A field that can be empty is a field that will misalign a tab-separated read.
  BEGIN { g = "ungrouped" }
  /^##@/ { g = substr($0, 5); next }
  /^[a-z][a-z0-9-]*:.*##[^@]/ {
    split($0, a, ":"); i = index($0, "##"); help = substr($0, i + 2)
    sub(/^[ \t]+/, "", help)
    print g "\t" a[1] "\t" help
  }
' Makefile)"
[ -n "$pairs" ] || { echo "ERROR check-doc-target-coverage: parsed ZERO targets out of the Makefile — the gate has gone BLIND."; exit 1; }

missing=0
checked=0
skipped=0
while IFS=$'\t' read -r group target help; do
  [ -n "$target" ] || continue
  case "$group" in
    *"Quality gates"*|*"Offline script tests"*|*"Diagrams"*|*"Renovate"*) skipped=$((skipped + 1)); continue ;;
  esac
  # Self-declared CI plumbing: `## Gate: …`, `## NEGATIVE test …`. Not an operator capability.
  case "$help" in
    Gate:*|"NEGATIVE test"*) skipped=$((skipped + 1)); continue ;;
  esac
  checked=$((checked + 1))
  # A mention is `make <target>` or `<target>` in a code span, anywhere a reader reads.
  if grep -rqE "\`?make ${target}\`?([^a-z0-9-]|$)|\`${target}\`" README.md docs/*.md docs/*/*.md 2>/dev/null; then
    continue
  fi
  printf 'MISSING  %-28s (group: %s) — an operator can run it, and no doc mentions it\n' "$target" "$group"
  missing=$((missing + 1))
done <<< "$pairs"

echo "         (checked ${checked} operator-facing targets; ${skipped} CI/gate/test targets exempt by group)"

if [ "$missing" -gt 0 ]; then
  echo
  echo "ERROR check-doc-target-coverage: ${missing} operator-invocable target(s) appear in NO document."
  echo "  A capability the operator cannot find is a capability that does not exist for them. Put each"
  echo "  one where it CHANGES WHAT A READER DOES — the runbook step that needs it, not a target list."
  echo "  If it is really CI-only plumbing, move it under an exempt ##@ group instead of documenting it."
  exit 1
fi
echo "check-doc-target-coverage: OK — every operator-invocable target is documented somewhere."
