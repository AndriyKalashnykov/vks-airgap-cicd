#!/usr/bin/env bash
# ============================================================================
# Run a DISCOVERED set of offline unit tests and print a denominator.
#
#   run-test-set.sh <label> <script> [<script> ...]
#
# WHY A RUNNER AT ALL. `test-scripts` used to be a hand-typed prereq list, and it had drifted:
# 51 scripts/test-*.sh on disk, 48 reachable. The 3 missing were excluded ON PURPOSE (container
# engine / registry / a 12 GB bundle) but nothing said so -- so a 4th omission would have been
# invisible, and an omission from a test list is the quietest way to lose coverage there is.
# The set is now discovered by glob and filtered by a `# ci-tier:` marker in each file.
#
# WHY IT PRINTS A COUNT. A test runner that cannot tell you how many tests it ran cannot be
# trusted to have run any. If the glob ever stops matching, ZERO is a FAILURE here, not a silent
# pass -- the whole point of replacing the enumerated list is that the failure mode moves from
# "silently smaller" to "loudly zero".
#
# WHY IT DOES NOT STOP AT THE FIRST FAILURE. A fail-fast composite shows exactly ONE red reason,
# so fixing it merely uncovers the next -- measured repeatedly in this repo. Running all of them
# and listing every failure at the end turns N debugging cycles into one.
# ============================================================================
set -uo pipefail

label="${1:-set}"; shift || true
if [ "$#" -eq 0 ]; then
  printf 'run-test-set: no test scripts given for the "%s" set -- the glob matched NOTHING.\n' "$label" >&2
  exit 1
fi

total=0; failed=0; failures=""; start=$SECONDS
# ⚠️ SKIPPED ARMS WERE INVISIBLE, AND THAT MADE THIS RUNNER A FAKE-GREEN FOR EVERY GATE IT JUDGES.
# `bash "$t" > "$log" 2>&1` captures the test's output and the log is cat'd ONLY in the rc!=0
# branch, so a test that deliberately writes a LOUD skip to >&2 -- because its own header says "a
# skipped case that says nothing is indistinguishable from a passing one" -- had that line
# DISCARDED on the green path. `ok test-X.sh 7s` read identically whether 5 arms ran or 2 did.
# MEASURED 2026-08-18: 32 of 79 scripts/test-*.sh carry a skip path.
#
# ⚠️ THE DETECTOR IS ANCHORED, and the first version was not. Matching the word "skip" anywhere
# counted PASS messages -- `ok ... blob validation cannot be silently skipped`, `cache-skip
# eligible`, `two conditional jobs skipped` -- and reported 11 of 70 on a suite where the real
# number is far lower. The tests announce a skip as a line-start MARKER (`SKIP  ...` or `SKIP: ...`,
# both measured in the corpus), so that is what this matches, case-SENSITIVELY. An unanchored
# detector here would be the same defect it exists to catch: a number that looks like a measurement
# and is an artifact of the question.
#
# ⚠️ AND THE OBVIOUS FIX IS WRONG. An adversary prescribed "gate the SUCCESS banner on zero skips";
# that would turn every LEGITIMATE skip into a failure across a third of the suite (a test that
# correctly skips its live-cluster arm on a laptop is not a defect). So this SURFACES, and never
# gates -- the gates.md "print the denominator" discipline, not a new red.
skipped=0; skipnotes=""
log=$(mktemp); trap 'rm -f "$log"' EXIT

for t in "$@"; do
  if [ ! -f "$t" ]; then
    printf '  MISSING  %s\n' "$t" >&2
    failed=$((failed + 1)); failures="${failures}  ${t} (missing)"$'\n'
    continue
  fi
  total=$((total + 1))
  t0=$SECONDS
  rc=0
  bash "$t" > "$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    # Count the test's OWN skip lines. `grep -c` prints 0 and exits 1 on no match, which under
    # `set -e` would kill the runner -- hence `|| true`, the documented capture-then-test form.
    _sk="$(grep -cE '^[[:space:]]*SKIP[:[:space:]]' "$log" 2>/dev/null || true)"
    case "$_sk" in ''|*[!0-9]*) _sk=0 ;; esac
    if [ "$_sk" -gt 0 ]; then
      skipped=$((skipped + 1))
      skipnotes="${skipnotes}  $(basename "$t") (${_sk} skip line(s))"$'\n'
      printf '  ok    %-50s %3ds  [%s SKIP line(s) -- see below]\n' \
        "$(basename "$t")" "$((SECONDS - t0))" "$_sk"
      grep -E '^[[:space:]]*SKIP[:[:space:]]' "$log" | sed 's/^/        | /' | head -6
    else
      printf '  ok    %-50s %3ds\n' "$(basename "$t")" "$((SECONDS - t0))"
    fi
  else
    printf '  FAIL  %-50s %3ds  (rc=%s)\n' "$(basename "$t")" "$((SECONDS - t0))" "$rc"
    sed 's/^/        | /' "$log" | tail -25
    failed=$((failed + 1)); failures="${failures}  ${t} (rc=${rc})"$'\n'
  fi
done

printf '\nrun-test-set [%s]: %d test(s) run in %ds, %d failed, %d with skipped arm(s)\n' \
  "$label" "$total" "$((SECONDS - start))" "$failed" "$skipped"
# NOT a failure -- a DENOMINATOR. A green whose coverage shrank silently is the thing this prints.
[ "$skipped" -eq 0 ] || printf 'SKIPPED ARMS (green, but these tests did not measure everything):\n%s' "$skipnotes"
[ "$failed" -eq 0 ] || { printf 'FAILED:\n%s' "$failures"; exit 1; }
exit 0
