#!/usr/bin/env bash
# Gate: no TRACKED file may be hidden from gitleaks by the .gitleaks.toml allowlist.
#
# WHY THIS IS DERIVED AND NOT A LIST. The previous version hardcoded four paths (.env, secrets,
# .env.state, .jumpbox) while .gitleaks.toml allowlisted SIX -- `bundle/` and `.claude/worktrees/`
# were allowlisted-and-unchecked. That is not cosmetic: an allowlisted path is SKIPPED by the
# working-tree scan, so a deliberate `git add -f bundle/creds.env` would be invisible to gitleaks
# AND invisible to this gate, on a job that runs on every PR.
#
# Worse, .gitleaks.toml's own comment asserted the coverage in as many words --
#   "`make check-secrets-untracked` fails if any of these paths is ever tracked by git"
# -- which was FALSE for 2 of 6. A false fact inside a control is the worst kind: it is the
# sentence a reviewer reads INSTEAD of checking.
#
# The two files could not be kept in agreement by care, because nothing compared them. So this
# gate does not restate the allowlist -- it READS it, and the enumerated list is gone.
#
# MEASURED 2026-08-17 (the drift, before this fix): allowlist 6, checked 4, unchecked
# `^bundle/` + `^\.claude/worktrees/` -- both untracked TODAY, so latent rather than a live leak.
# Found by an adversary round that had been asked about something else entirely.
#
# WHAT IT ASSERTS, precisely: for every pattern P in the `paths` allowlist, NO git-tracked file
# matches P. Note the DIRECTION -- it tests the TRACKED FILES against the patterns rather than
# translating each pattern into a path and asking git about it. That is deliberate: a regex->path
# translation is a second thing to get wrong (what is the path of `^\.env$`? of a character class?)
# and it would silently under-match on any entry shape nobody anticipated. Matching real paths
# against the real regexes has no such gap.
#
# RED-PROOF, runnable, not by hand: scripts/test-check-secrets-untracked.sh (`make test-scripts`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${GITLEAKS_CONFIG:-${ROOT}/.gitleaks.toml}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$CFG" ] || die "no gitleaks config at ${CFG} -- this gate reads its patterns from there"

# Parse `paths = [ ... ]`. Entries are '''<regex>''' with optional trailing comments.
# `|| true` on the grep: it exits 1 on no-match, and under `set -e` a non-zero inside $( ) kills
# the script with NO OUTPUT. The empty case is what the n_pat guard below reports, loudly.
PATTERNS="$(sed -n '/^paths = \[/,/^]/p' "$CFG" | grep -oE "'''[^']*'''" | sed "s/'''//g" || true)"

n_pat=$(printf '%s' "$PATTERNS" | grep -c . || true)
# VACUITY GUARD 1. A parser that silently returns nothing turns this gate into `exit 0` forever --
# green, measuring the empty set. If .gitleaks.toml ever grows a different quoting style, FAIL
# here rather than pass by not looking.
[ "$n_pat" -gt 0 ] || die "parsed ZERO allowlist patterns from ${CFG} -- the parser and the config have diverged; this gate would otherwise pass by not looking"

TRACKED="$(git -C "$ROOT" ls-files || true)"
n_files=$(printf '%s' "$TRACKED" | grep -c . || true)
# VACUITY GUARD 2. Same reasoning on the other input: no tracked files means we are not where we
# think we are (not a repo, wrong cwd) -- it does not mean the repo is clean.
[ "$n_files" -gt 0 ] || die "git ls-files returned NOTHING under ${ROOT} -- refusing to report OK over an empty file list"

bad=""
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  # Capture-then-test, NEVER `| grep -q`: under `set -o pipefail` grep -q exits at the first match
  # and SIGPIPEs the producer, so the pipeline can report a pattern ABSENT when it is PRESENT.
  hits="$(printf '%s\n' "$TRACKED" | grep -E "$pat" || true)"
  if [ -n "$hits" ]; then
    bad="${bad}"$'\n'"  pattern ${pat} hides these TRACKED files:"$'\n'"$(printf '%s\n' "$hits" | sed 's/^/    /')"
  fi
done <<< "$PATTERNS"

if [ -n "$bad" ]; then
  echo "ERROR: files that gitleaks SKIPS (allowlisted) are TRACKED by git -- they are UNSCANNED:" >&2
  printf '%s\n' "$bad" >&2
  echo "       Untrack with: git rm --cached -r <path>   (and ROTATE anything that leaked)" >&2
  echo "       Or, if the file genuinely belongs in git, narrow the pattern in ${CFG}." >&2
  exit 1
fi

echo "check-secrets-untracked: OK -- ${n_files} tracked files, none matched by any of the ${n_pat} allowlist patterns"
