#!/usr/bin/env bash
# check-doc-robot-quoting.sh — a shell assignment of a Harbor ROBOT USERNAME (in the operator docs OR
# in .env.example, the file load_env actually sources) must be SINGLE-QUOTED. Scanning only the docs
# would license false trust in the sourced file, so .env.example is in scope too.
# A robot username is ALWAYS `robot$<name>` (goharbor), and `load_env` sources `.env`
# with `set -a`, so an unquoted or double-quoted `HARBOR_USERNAME=robot$vks-cicd` expands `$vks` away
# -> `robot-cicd` -> Harbor 401. The class recurs BY CONSTRUCTION (every robot name carries a `$`),
# so this is a preventive gate: there are zero violations in the tree today.
#
# WHY A GATE AND NOT A RULE:
#   The "single-quote a robot credential" rule is documented (detailed-steps.md, .env.example) and
#   would still be re-typed unquoted in the next doc. Prose loaded at session start does not fire at
#   the moment text is generated; a check that runs does.
#
# THE CLASSIFIER IS A PURE FUNCTION (`doc_robot_line_is_bad` in lib/os.sh) so its test can EXECUTE it
# rather than grep for it (the esc_sq/engine_packages pattern) — and so no bad-form example string
# needs to live in a scanned `.md`. This script is only the SCANNER: enumerate docs, run the function
# per line, report file:line. See lib/os.sh for the discriminator + its accepted residuals.
#
# NARROW SCOPE, deliberately: `robot$` only (the refuted v1 was a general env-quoting scanner). A
# robot SECRET is [a-zA-Z0-9] (no `$`), so `robot$` is the complete key for the credential class.
#
# EXEMPT (skip entirely):
#   - docs/reviews/*   — the verbatim arc archive.
#   - docs/decisions/* — ADR bodies.
#   A deliberate bad-form example anywhere is exempted per-line with a `# env-quote-ok:` marker.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# Files to scan: README.md + docs/**/*.md AND .env.example — the last is the file load_env ACTUALLY
# sources with `set -a`, so it is the substance, not just the docs that teach the pattern (scanning
# only the docs would license false trust in the sourced file). Tracked OR untracked-not-ignored (so
# a brand-new doc is not invisible). No fenced-code tracking: the `^\s*KEY=` anchor (in
# doc_robot_line_is_bad) already excludes prose, `>`-prompts, and yaml/json `value:` forms — an
# assignment is what carries the risk.
mapfile -t DOCS < <(git ls-files --cached --others --exclude-standard -- 'README.md' 'docs/*.md' 'docs/**/*.md' '.env.example' 2>/dev/null | sort -u)

is_exempt() {
  case "$1" in
    docs/reviews/*|docs/decisions/*) return 0 ;;
    *) return 1 ;;
  esac
}

scanned=0; bad=0
declare -a HITS=()
for f in "${DOCS[@]}"; do
  [ -f "$f" ] || continue
  is_exempt "$f" && continue
  scanned=$((scanned + 1))
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if doc_robot_line_is_bad "$line"; then
      HITS+=("${f}:${lineno}")
      bad=$((bad + 1))
    fi
  done < "$f"
done

# A gate that scanned nothing is a BROKEN gate, not a green one — README.md always matches the
# pathspec, so scanned==0 means git ls-files / the pathspec broke ("passes by not looking").
[ "$scanned" -gt 0 ] || die "check-doc-robot-quoting: scanned 0 files — git ls-files/pathspec is broken (README.md must always match)."

if [ "$bad" -gt 0 ]; then
  log_error "check-doc-robot-quoting: $bad unquoted Harbor robot credential(s) in docs/.env.example (scanned $scanned):"
  for h in "${HITS[@]}"; do printf '  - %s\n' "$h"; done
  echo "  A robot username is 'robot\$<name>'; load_env sources .env with 'set -a', so an unquoted or"
  echo "  double-quoted value expands \$<name> away -> robot-<rest> -> Harbor 401. SINGLE-QUOTE it:"
  echo "      HARBOR_USERNAME='robot\$vks-cicd'"
  echo "  A deliberate 'don't do this' example is exempted with a '# env-quote-ok:' marker on the line."
  exit 1
fi

log_info "check-doc-robot-quoting: OK — scanned $scanned file(s); every Harbor robot credential in docs/.env.example is single-quoted (docs/reviews/* + docs/decisions/* exempt)."
exit 0
