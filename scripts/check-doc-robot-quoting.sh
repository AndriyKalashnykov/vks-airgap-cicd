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

scanned=0; bad=0; lines=0
declare -a HITS=()
for f in "${DOCS[@]}"; do
  [ -f "$f" ] || continue
  is_exempt "$f" && continue
  scanned=$((scanned + 1))
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    lines=$((lines + 1))
    if doc_robot_line_is_bad "$line"; then
      HITS+=("${f}:${lineno}")
      bad=$((bad + 1))
    fi
  done < "$f"
done

# A gate that scanned nothing is a BROKEN gate, not a green one — README.md always matches the
# pathspec, so scanned==0 means git ls-files / the pathspec broke ("passes by not looking").
[ "$scanned" -gt 0 ] || die "check-doc-robot-quoting: scanned 0 files — git ls-files/pathspec is broken (README.md must always match)."

# B49 — THE FILE COUNT IS NOT THE ITEM COUNT. MEASURED: empty every tracked .md (leaving them
# tracked) and the guard above still passed, reporting `OK — scanned 22 file(s)` with rc=0 over a
# corpus containing NOTHING. `scanned` counts files OPENED; `lines` counts the lines actually fed to
# the classifier, which is what the verdict is about. Zero lines across the corpus is not "clean" —
# it is "this gate judged nothing", and it is indistinguishable from clean without this check.
[ "$lines" -gt 0 ] || die "check-doc-robot-quoting: examined 0 line(s) across ${scanned} file(s) — the file count is healthy but the ITEM count is zero, so this gate judged nothing. Suspect an empty corpus or a broken read loop."

if [ "$bad" -gt 0 ]; then
  log_error "check-doc-robot-quoting: $bad unquoted Harbor robot credential(s) in docs/.env.example (scanned $scanned):"
  for h in "${HITS[@]}"; do printf '  - %s\n' "$h"; done
  echo "  A robot username is 'robot\$<name>'; load_env sources .env with 'set -a', so an unquoted or"
  echo "  double-quoted value expands \$<name> away -> robot-<rest> -> Harbor 401. SINGLE-QUOTE it:"
  echo "      HARBOR_USERNAME='robot\$vks-cicd'"
  echo "  A deliberate 'don't do this' example is exempted with a '# env-quote-ok:' marker on the line."
  exit 1
fi

log_info "check-doc-robot-quoting: OK — examined $lines line(s) across $scanned file(s); every Harbor robot credential is single-quoted (docs/reviews/* + docs/decisions/* exempt)."
# ── AND THE WRITER, not just the documents ───────────────────────────────────────────────────────
# This gate scanned README.md + docs/** + .env.example and reported OK — 6386 lines — while
# `make harbor-robot` published an UNQUOTED `robot$vks-cicd` into .env through set_env_var.
# MEASURED 2026-08-12, row 1 of the walk: the document's own `set -a; . ./.env; set +a` then died
# with `line 1450: vks: unbound variable`, and SEVEN of the run's eight failed blocks were that one
# line — Steps 10, 11, 12 and 13 in their entirety.
#
# .env is gitignored, so it can never be scanned. The WRITER can be, and it is the thing that
# decides. So: EXECUTE set_env_var with the credential shape that broke it, and source the result
# under `set -u` — the same round trip the reader performs.
_t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
# lib/os.sh is already sourced at the top of this file, so set_env_var is in scope.
# SC2016 is DELIBERATE and load-bearing: the literal `$vks` is the entire point. A robot name
# always contains `$`, and double quotes here would expand it away and test nothing — which is
# precisely how the first version of my own test for this reported the mode PRESERVED.
# shellcheck disable=SC2016
set_env_var HARBOR_USERNAME 'robot$vks-cicd'     "$_t/.env"
set_env_var HARBOR_PASSWORD "p@ss'w0rd \$x"      "$_t/.env"
set_env_var HARBOR_URL      harbor.env1.lab.test "$_t/.env"
# THE PROBE SET IS THE GATE'S COVERAGE. The three values above carry only `$`, `'` and a space —
# so this gate was GREEN while `set_env_var K 'a;id;b'` wrote an unquoted `;` and sourcing EXECUTED
# `id`, and `a>victim` TRUNCATED a file. A gate certifying a class it cannot see is worse than none.
# These two are the measured survivors of the old deny-list; keep them, and add to them.
set_env_var HARBOR_ADMIN_PASSWORD 'a;echo PWNED>x' "$_t/.env"   # command exec + redirection
# Built, not written literally: a bare '~/k.conf' trips SC2088 ("tilde does not expand in quotes"),
# which here is the ASSERTION rather than a bug — the `~` must survive the round trip UNEXPANDED.
_tilde='~'
set_env_var ARGOCD_KUBECONFIG     "${_tilde}/k.conf"  "$_t/.env"   # leading ~ silently expands

# shellcheck disable=SC2016
# `cd "$_t"` FIRST: if the writer regresses, sourcing performs the `>x` redirection for real, and it
# must land in the temp dir rather than the repo root.
if ( cd "$_t"; set -u; set -a; . "$_t/.env"; set +a
     [ "$HARBOR_USERNAME" = 'robot$vks-cicd' ] && [ "$HARBOR_PASSWORD" = "p@ss'w0rd \$x" ] \
     && [ "$HARBOR_ADMIN_PASSWORD" = 'a;echo PWNED>x' ] && [ "$ARGOCD_KUBECONFIG" = "${_tilde}/k.conf" ] \
     && [ ! -e x ] ) 2>/dev/null; then
  log_info "check-doc-robot-quoting: set_env_var round-trips a \$-bearing credential through .env"
else
  log_error "set_env_var wrote a .env that cannot be SOURCED, or mangled the value:"
  sed 's/^/    /' "$_t/.env" >&2
  log_error "  The document runs 'set -a; . ./.env; set +a' at Steps 3, 6, 8 and 10. A robot name"
  log_error "  always contains '\$' — unquoted, it kills every step after the one that wrote it."
  rc=1
fi

# ...and a value that does NOT need quoting must stay BARE, or make's -include breaks: Makefile:471
# expands $(HARBOR_URL), and make takes the quotes LITERALLY.
if grep -q "^HARBOR_URL=harbor.env1.lab.test$" "$_t/.env"; then
  log_info "check-doc-robot-quoting: a plain value is left unquoted (make's -include still reads it)"
else
  log_error "set_env_var quoted a value that did not need it — make's \$(HARBOR_URL) breaks:"
  grep '^HARBOR_URL=' "$_t/.env" | sed 's/^/    /' >&2
  rc=1
fi

exit "${rc:-0}"
