#!/usr/bin/env bash
# RED-proof for scripts/check-secrets-untracked.sh.
#
# The gate reads .gitleaks.toml's allowlist and fails if any TRACKED file is matched by it. A green
# on the real tree proves nothing alone -- the tree is clean, so a gate that parsed zero patterns
# would be green too. Every case here either DEMANDS A RED or demands a green for a stated reason.
#
# WHAT PINS THE DERIVATION -- corrected 2026-08-17 after an adversary MEASURED my labelling wrong.
# I had labelled the bundle/ case "THE DISCRIMINATOR". It is not: under a mutation replacing the
# derivation with a hardcoded six-list, that case still PASSED (bundle/ is one of the six). The real
# pin is cases 2-4, which use ^README\.md$ -- a pattern ABSENT from the real six, so a hardcoded
# gate fails them. Do not trim cases 2-4 as redundant; they are load-bearing and the bundle/ case
# is not. The bundle/ case earns its place for a different reason: it is the exact configuration
# the ORIGINAL hardcoded gate passed.
#
# Cases 8-11 exist because an adversary measured two FALSE GREENS in the sed+grep implementation
# this replaced. Each is one config edit away, so each is pinned here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${ROOT}/scripts/check-secrets-untracked.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
# if/then/else, never `grep -q X && ok || bad` -- SC2015: in `A && B || C`, C also runs when A is
# TRUE and B fails, so a PASSING assertion gets recorded as a FAILURE. Worst direction in a harness.
has() { if grep -qE "$1" /tmp/csu-out.txt; then ok "$2"; else bad "$3"; fi; }

TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
git -C "$TD" init -q
git -C "$TD" config user.email t@t; git -C "$TD" config user.name t
mkdir -p "$TD/scripts" "$TD/bundle" "$TD/secrets"
cp "$GATE" "$TD/scripts/"
echo tracked            > "$TD/README.md"
echo tracked-in-bundle  > "$TD/bundle/manifest.txt"
git -C "$TD" add -A >/dev/null 2>&1
git -C "$TD" commit -qm init

# Write an arbitrary allowlist body, so a case can use ANY valid TOML string form.
cfg()  { printf '[allowlist]\npaths = [\n%s\n]\n' "$1" > "$TD/.gitleaks.toml"; }
run()  { ( cd "$TD" && ./scripts/check-secrets-untracked.sh >/tmp/csu-out.txt 2>&1 ); }
# demands a RED, and reports the gate's own message when it wrongly passes
red()  { if run; then bad "$1 (gate PASSED; said: $(head -1 /tmp/csu-out.txt))"; else ok "$1"; fi; }

# 1. GREEN: patterns matching nothing tracked.
cfg "  '''^secrets/''',
  '''^\.env\$''',"
if run; then ok "clean tree, 2 patterns -> rc=0"; else bad "clean tree should pass: $(cat /tmp/csu-out.txt)"; fi
has 'none matched by any of the 2 allowlist patterns' \
    "prints the DENOMINATOR, so a silent parse collapse is visible" "no denominator in output"

# 2-4. THE DERIVATION PIN: ^README\.md$ is NOT one of the repo's six, so a hardcoded gate fails here.
cfg "  '''^secrets/''',
  '''^README\.md\$''',"
red "DERIVATION PIN: an allowlist entry matching a TRACKED file -> rc!=0"
has 'README.md' "names the offending FILE"    "does not name the file"
has '\^README'  "names the offending PATTERN" "does not name the pattern"

# 5. VACUITY GUARD: zero parsed patterns must FAIL, not silently pass.
printf '[allowlist]\ndescription = "no paths key at all"\n' > "$TD/.gitleaks.toml"
red "0 patterns parsed -> rc!=0 (else the gate passes by not looking)"
has 'parsed ZERO' "says WHY (parser/config diverged)" "unhelpful message"

# 6. VACUITY GUARD: no tracked files must FAIL, not report OK over the empty set.
EMPTY="$(mktemp -d)"; git -C "$EMPTY" init -q; mkdir -p "$EMPTY/scripts"; cp "$GATE" "$EMPTY/scripts/"
cfg "  '''^secrets/''',"; cp "$TD/.gitleaks.toml" "$EMPTY/.gitleaks.toml"
if ( cd "$EMPTY" && ./scripts/check-secrets-untracked.sh >/tmp/csu-out.txt 2>&1 ); then
  bad "an empty tracked-file list must FAIL"; else ok "0 tracked files -> rc!=0"; fi
rm -rf "$EMPTY"

# 7. The configuration the ORIGINAL hardcoded gate passed: ^bundle/ allowlisted, a bundle file
#    tracked. NOT the derivation pin (see the header) -- it pins the 4-of-6 regression specifically.
cfg "  '''^secrets/''',
  '''^\.env\$''',
  '''^\.env\.state''',
  '''^\.jumpbox/''',
  '''^bundle/''',"
red "the 4-of-6 regression: ^bundle/ allowlisted + bundle/manifest.txt tracked -> rc!=0"
has 'bundle/manifest.txt' "names the tracked bundle file" "does not name bundle/manifest.txt"

# 8. QUOTING GAP (measured false green in the sed+grep version). Mixed quote styles: valid TOML,
#    gitleaks honours BOTH, the old parser saw only the triple-quoted one and reported OK.
cfg "  '''^zzz/''',
  \"^bundle/\","
red "MIXED QUOTING: a double-quoted entry must be parsed, not silently dropped"
has 'of the 2 allowlist patterns|bundle/manifest.txt' \
    "sees BOTH entries (denominator 2, not 1)" "silently dropped the double-quoted entry"

# 9-10. ENGINE GAP (measured false greens). RE2 constructs grep -E cannot express.
cfg "  '''(?i)^readme''',"
red "RE2 (?i): case-insensitive entry must match tracked README.md"
cfg "  '''^(?:bundle|vault)/''',"
red "RE2 (?:...): non-capturing group must match the FIRST alternative too"

# 11. A pattern this gate cannot faithfully evaluate must DIE LOUDLY, never be skipped.
cfg "  '''^\pL+/''',"
red "an uncompilable pattern must FAIL rather than be silently skipped"
has 'does not compile|RE2' "says the engine could not evaluate it" "no explanation of the refusal"

echo
echo "check-secrets-untracked tests: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
