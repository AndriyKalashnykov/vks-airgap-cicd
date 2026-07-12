#!/usr/bin/env bash
# classify-changes.sh — read a list of changed files on STDIN, print `code=<bool>` and
# `docs=<bool>`: which CI gates does this change actually need?
#
# WHY IT IS A SCRIPT AND NOT INLINE YAML
# --------------------------------------
# Runner minutes are BILLED. CI used to decide this with dorny/paths-filter and a "deny-list"
# (`'**'` followed by `'!**/*.md'`), which DOES NOT WORK — paths-filter ORs its globs, so `'**'`
# matched on its own and the `!` lines subtracted nothing. Every docs-only PR reported
# `code = true` (with an empty "Matching files:" list — the tell) and paid ~2 minutes of billed
# runner time for a full Java + Go build it did not need. It never failed, so nothing surfaced
# it; it just quietly cost money.
#
# Logic that costs money is logic that gets a unit test (tests/test-classify-changes.sh, run by
# `make test-scripts` in static-check). Inline YAML cannot be tested.
#
# The DENY-LIST semantics are deliberate and must be preserved: anything that is NOT pure docs
# counts as code. An allow-list would let a root-config-only change (renovate.json, .trivyignore,
# a new Makefile include) match neither filter, skip BOTH gates, and go green having run nothing.
set -euo pipefail

code=false
docs=false

while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.md|docs/*) docs=true ;;
    *)           code=true ;;
  esac
done

# An EMPTY list means we could not determine what changed (workflow_dispatch, a tag, a first
# push to a new branch). Run everything: never guess cheap when the answer is unknown.
if [ "$code" = false ] && [ "$docs" = false ]; then
  code=true
  docs=true
fi

echo "code=${code}"
echo "docs=${docs}"
