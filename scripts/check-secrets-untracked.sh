#!/usr/bin/env bash
# Gate: no TRACKED file may be hidden from gitleaks by the .gitleaks.toml allowlist.
#
# WHY DERIVED. This gate once hardcoded four paths while .gitleaks.toml allowlisted SIX, so
# `^bundle/` and `^\.claude/worktrees/` were allowlisted-and-unchecked -- and the config's own
# comment claimed otherwise. An allowlisted path is SKIPPED by the working-tree scan, so a
# `git add -f bundle/creds.env` was invisible to gitleaks AND to the gate built to close that hole.
#
# WHY PYTHON, AND NOT sed+grep. The first derived version parsed with
# `sed -n '/^paths = \[/,/^]/p' | grep -oE "'''[^']*'''"` and matched with `grep -E`. An adversary
# round MEASURED two false greens in that design, both one config edit away, both silent:
#
#   1. ENGINE GAP. gitleaks matches `paths` with Go RE2; grep -E is POSIX ERE. Measured against a
#      real `openssl genrsa` key, with a positive control:
#        (?i)^secrets/      gitleaks: SKIPS Secrets/creds.key | grep -E: "? at start of expression",
#                                                               rc=1 -- indistinguishable from no-match
#        ^(?:secrets|vault)/  gitleaks: SKIPS secrets/creds.key | grep -E: matches vault/ but MISSES
#                                                               secrets/ -- so the gate still looks
#                                                               functional while blind to the first
#      Python's `re` expresses both. Where it CANNOT express an RE2 construct (`\pL`, and RE2 rejects
#      the lookarounds Python allows) it RAISES -- so the disagreement is LOUD, never a silent skip.
#      That asymmetry is the whole reason for the engine choice: the failure direction is a die, not
#      a pass.
#   2. QUOTING GAP. `paths = ['''^zzz/''', "^bundle/"]` is valid TOML and gitleaks honours BOTH.
#      The old parser saw only the triple-quoted one and reported OK over a tracked key -- the
#      ORIGINAL bug, reintroduced by a one-line edit, with the denominator quietly 2 instead of 1.
#      A zero-pattern guard cannot see that; it only fires at zero. tomllib deletes the whole class
#      (mixed quoting, apostrophes, `paths=[` spacing, multi-line literals) and additionally picks
#      up the `[[allowlists]]` plural form gitleaks now prefers, which the old parser ignored.
#
# WHAT IT ASSERTS: for every pattern P in the allowlist, NO git-tracked file matches P. It tests the
# TRACKED FILES against the PATTERNS rather than translating each pattern into a path -- a
# regex->path translation is a second thing to get wrong and would under-match on any entry shape
# nobody anticipated.
#
# RED-PROOF, runnable: scripts/test-check-secrets-untracked.sh (in the fast per-PR tier).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# NO env override for the config path. There was a GITLEAKS_CONFIG knob; `git grep` found it in
# exactly ONE place -- this line. Nothing set it, and `make secrets` hardcodes `--config
# .gitleaks.toml`, so its only achievable effect was to point this gate at a DIFFERENT list than the
# scanner reads: a false green with no upside.
CFG="${ROOT}/.gitleaks.toml"

[ -f "$CFG" ] || { echo "ERROR: no gitleaks config at ${CFG} -- this gate reads its patterns from there" >&2; exit 1; }

TRACKED="$(git -C "$ROOT" ls-files || true)"
# VACUITY GUARD: no tracked files means we are not where we think we are (not a repo, wrong cwd) --
# it does not mean the repo is clean. Refusing beats reporting OK over an empty set.
printf '%s' "$TRACKED" | grep -q . || { echo "ERROR: git ls-files returned NOTHING under ${ROOT} -- refusing to report OK over an empty file list" >&2; exit 1; }

printf '%s' "$TRACKED" | python3 -c '
import sys, re
try:
    import tomllib
except ModuleNotFoundError:                      # py<3.11
    # DIE rather than fall back to a hand parser: a silent fallback would reintroduce the exact
    # quoting gap this file exists to close, and it would do it invisibly.
    sys.exit("ERROR: python3 >= 3.11 required (tomllib). Do NOT substitute a hand-written TOML parser.")

cfg, = sys.argv[1:]
with open(cfg, "rb") as fh:
    doc = tomllib.load(fh)

pats = list(doc.get("allowlist", {}).get("paths", []))          # singular, what we use today
for al in doc.get("allowlists", []):                            # plural, the form gitleaks prefers
    pats += al.get("paths", [])

# VACUITY GUARD: a parser that silently returns nothing turns this gate into exit 0 forever --
# green, measuring the empty set.
if not pats:
    sys.exit(f"ERROR: parsed ZERO allowlist patterns from {cfg} -- the parser and the config have "
             f"diverged; this gate would otherwise pass by not looking")

tracked = [ln for ln in sys.stdin.read().splitlines() if ln]

bad = []
for p in pats:
    try:
        rx = re.compile(p)
    except re.error as e:
        # LOUD, by design. gitleaks uses RE2; anything Python cannot compile is a construct we
        # cannot faithfully evaluate, and guessing would be a silent skip.
        sys.exit(f"ERROR: allowlist pattern {p!r} does not compile in python re: {e}\n"
                 f"       gitleaks uses Go RE2. This gate cannot faithfully evaluate it, so it "
                 f"refuses rather than skip it silently.")
    hits = [f for f in tracked if rx.search(f)]
    if hits:
        bad.append((p, hits))

if bad:
    print("ERROR: files that gitleaks SKIPS (allowlisted) are TRACKED by git -- they are UNSCANNED:", file=sys.stderr)
    for p, hits in bad:
        print(f"  pattern {p} hides these TRACKED files:", file=sys.stderr)
        for h in hits:
            print(f"    {h}", file=sys.stderr)
    print("       Untrack with: git rm --cached -r <path>   (and ROTATE anything that leaked)", file=sys.stderr)
    print(f"       Or, if the file genuinely belongs in git, narrow the pattern in {cfg}.", file=sys.stderr)
    sys.exit(1)

print(f"check-secrets-untracked: OK -- {len(tracked)} tracked files, none matched by any of the {len(pats)} allowlist patterns")
' "$CFG"
