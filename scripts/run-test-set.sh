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
    printf '  ok    %-50s %3ds\n' "$(basename "$t")" "$((SECONDS - t0))"
  else
    printf '  FAIL  %-50s %3ds  (rc=%s)\n' "$(basename "$t")" "$((SECONDS - t0))" "$rc"
    sed 's/^/        | /' "$log" | tail -25
    failed=$((failed + 1)); failures="${failures}  ${t} (rc=${rc})"$'\n'
  fi
done

printf '\nrun-test-set [%s]: %d test(s) run in %ds, %d failed\n' \
  "$label" "$total" "$((SECONDS - start))" "$failed"
[ "$failed" -eq 0 ] || { printf 'FAILED:\n%s' "$failures"; exit 1; }
exit 0
