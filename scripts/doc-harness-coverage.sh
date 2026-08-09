#!/usr/bin/env bash
# doc-harness-coverage.sh — which commands a RUNBOOK tells an operator to run does anything
# actually EXECUTE? PRINTS, never gates. Always exits 0.
#
# WHY THIS IS A PRINTER AND NOT A GATE
# ------------------------------------
# Two sibling gates already close the directions that CAN be closed:
#   check-doc-make-targets.sh    doc -> Makefile   (every `make X` in a doc EXISTS)
#   check-doc-target-coverage.sh Makefile -> doc   (every operator target IS mentioned)
# Neither asks the third question, and it is the one that decides whether an instruction is
# TRUE: does any test, e2e or workflow ever RUN it? Measured 2026-08-09 on docs/scenario-1.md:
# 26 make targets named, 13 exercised, 13 never executed by anything -- including the whole
# `.env` lifecycle (env-init/env-populate/env-validate) and the guest-cluster path
# (vks-cluster-create/status). A green e2e therefore covers half the runbook and is silent
# about the rest.
#
# It does NOT gate, deliberately, and the reason is not squeamishness:
#   * Many of these CANNOT be exercised in CI by construction -- they need a real Supervisor,
#     an entitlement, or 60 minutes of hardware. A gate would be a permanent false RED, and a
#     gate that is always red gets deleted or `|| true`-ed, taking the signal with it.
#   * The remedy for a genuine gap is to EXTEND THE HARNESS, not to satisfy a checker. This
#     repo already records that lesson: a doc-vs-code parser goes green over the covered half
#     and thereby LICENSES trust in the uncovered half -- strictly worse than no gate.
# So: it reports, a human decides, and the number is visible in CI output instead of nowhere.
#
# WHAT IT DOES NOT CATCH (say it here, or the green reads as coverage):
#   * whether an exercised command is exercised MEANINGFULLY (a target named in a comment in
#     an e2e script counts as exercised here -- it is a name match, not an execution trace)
#   * anything that is not a `make` target: raw kubectl/vcf/curl/getent instructions are
#     invisible to it, and those are exactly where a wrong EXPECTED OUTPUT hides
#   * whether the doc's promised OUTPUT matches reality (see docs/EVIDENCE-DNS.md for a
#     `getent hosts` that succeeds and returns ::1)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

DOCS=${1:-docs/scenario-1.md}
HARNESS_GLOBS=(scripts/*e2e* scripts/*test* .github/workflows/*.yml Makefile)

printf '\n== doc -> harness coverage: %s ==\n' "$DOCS"
[ -f "$DOCS" ] || { printf '  (no such doc; nothing to report)\n'; exit 0; }

# every `make <target>` the doc tells the operator to run
mapfile -t TARGETS < <(grep -oE '\bmake [a-z][a-z0-9-]*' "$DOCS" | sed 's/^make //' | sort -u)
[ "${#TARGETS[@]}" -gt 0 ] || { printf '  (doc names no make targets)\n'; exit 0; }

run=0; unrun=0; missing=0
declare -a UNRUN=()
for t in "${TARGETS[@]}"; do
  # a name that is not a real target is the sibling gate's job, but report it rather than
  # silently counting it as "not exercised" -- different problem, different fix.
  if ! grep -qE "^${t}:" Makefile 2>/dev/null; then
    missing=$((missing+1)); continue
  fi
  if grep -rqE "(make|\\\$\(MAKE\))[[:space:]]+(-[^[:space:]]+[[:space:]]+)*${t}\b" "${HARNESS_GLOBS[@]}" 2>/dev/null; then
    run=$((run+1))
  else
    unrun=$((unrun+1)); UNRUN+=("$t")
  fi
done

printf '  %d target(s) named  |  %d exercised somewhere  |  %d NEVER executed\n' \
       "$((run+unrun))" "$run" "$unrun"
[ "$missing" -eq 0 ] || printf '  (%d name(s) are not Makefile targets — check-doc-make-targets owns that)\n' "$missing"

if [ "$unrun" -gt 0 ]; then
  printf '\n  Never executed by any test, e2e or workflow:\n'
  printf '    %s\n' "${UNRUN[@]}"
  printf '\n  These instructions are UNVERIFIED. Some cannot be exercised without real hardware;\n'
  printf '  for the rest, the fix is to extend the harness, not to silence this list.\n'
fi
printf '\n'
exit 0
