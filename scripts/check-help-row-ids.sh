#!/usr/bin/env bash
# ============================================================================
# No `make help` text may cite a BACKLOG ROW ID.
#
# `make help` is a first-contact surface: the Makefile sets `.DEFAULT_GOAL := help`, so a bare
# `make` prints it, and README + docs/kind-local.md + docs/make-targets.md all point at it. A row
# id (`B28`, `B50`, `C13`) is decipherable by nobody outside this repo's private backlog -- it is
# the same leak as putting internal vocabulary in the scenario docs, on a surface that is reached
# by typing `make` and nothing else.
#
# SCOPE, deliberately NARROW. This gate does NOT flag script paths, `apps/registry.tsv`, or
# provenance words. An adversary round measured that (a) the scenario docs themselves name
# `scripts/*.sh` paths TO OPERATORS, so a path is not categorically internal here, and (b) a
# broad word-blocklist trips 35.6% of recent help-line churn -- a gate people disable. A row id is
# the one token with no legitimate operator meaning, and it had ZERO false positives over ~140
# operator targets.
#
# The id keeps its real home: the script headers (CLAUDE.md calls that load-bearing provenance)
# and BACKLOG.md. Only the `##` help text is off limits.
#
# NOTE for anyone reimplementing the match in awk: `\b` DOES NOT EXIST there -- it is a backspace
# escape, and an awk `/\bB[0-9]+\b/` matches NOTHING while looking correct. That exact mistake
# made an adversary's first tally report a clean group that was not clean. Explicit character
# classes below.
# ============================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

MK="${1:-Makefile}"
[ -f "$MK" ] || { printf "check-help-row-ids: %s not found\n" "$MK" >&2; exit 1; }

checked=0
hits=""
while IFS= read -r line; do
  case "$line" in *"##"*) ;; *) continue ;; esac
  checked=$((checked + 1))
  printf %s "$line" | grep -qE '\#\#.*(^|[^A-Za-z0-9])[A-Z][0-9]{2,3}[a-z]?([^A-Za-z0-9]|$)' \
    && hits="${hits}  ${line}"$'\n'
done < "$MK"

if [ "$checked" -eq 0 ]; then
  printf "check-help-row-ids: examined ZERO help lines in %s -- this gate cannot pass by not looking.\n" "$MK" >&2
  exit 1
fi

if [ -n "$hits" ]; then
  printf "check-help-row-ids: a backlog row id is reachable from \`make help\`:\n" >&2
  printf "%s" "$hits" >&2
  printf "  A bare \`make\` prints this. A row id means nothing to whoever typed it.\n" >&2
  printf "  Move it to the script header or BACKLOG.md, and say what the target DOES instead.\n" >&2
  exit 1
fi
printf "check-help-row-ids: OK -- no backlog row id in any of %d help line(s) in %s\n" "$checked" "$MK"
