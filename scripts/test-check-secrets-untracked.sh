#!/usr/bin/env bash
# RED-proof for scripts/check-secrets-untracked.sh.
#
# The gate reads .gitleaks.toml's allowlist and fails if any TRACKED file is matched by it. A green
# on the real tree proves nothing on its own -- the tree is clean, so a gate that parsed zero
# patterns would be green too. Every case below therefore either DEMANDS A RED or demands a green
# for a stated reason.
#
# CASE 5 IS THE ONE THAT PROVES THE FIX. Cases 1-4 exercise the mechanism; case 5 is the
# DISCRIMINATOR -- it is the exact configuration the OLD hardcoded gate PASSED (it never looked at
# `^bundle/`) and the new derived gate must FAIL. Without it, this suite would be green against
# both the fixed and the broken implementation, which is the vacuity it exists to prevent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${ROOT}/scripts/check-secrets-untracked.sh"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  PASS  $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }
# `if/then/else`, never `grep -q X && ok || bad` -- SC2015: in `A && B || C`, C also runs when A is
# TRUE and B fails, so a passing assertion can be recorded as a failure. In a TEST harness that is
# the worst direction: it reports a red over a green.
has()  { if grep -qE "$1" /tmp/csu-out.txt; then ok "$2"; else bad "$3"; fi; }

# A throwaway repo, so nothing here can touch the real one.
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
git -C "$TD" init -q
git -C "$TD" config user.email t@t; git -C "$TD" config user.name t
mkdir -p "$TD/scripts" "$TD/bundle" "$TD/secrets"
cp "$GATE" "$TD/scripts/"
echo 'tracked' > "$TD/README.md"
echo 'tracked-in-bundle' > "$TD/bundle/manifest.txt"
git -C "$TD" add -A >/dev/null 2>&1
git -C "$TD" commit -qm init

mkcfg() { printf '[allowlist]\npaths = [\n%s\n]\n' "$1" > "$TD/.gitleaks.toml"; }
run()   { ( cd "$TD" && ./scripts/check-secrets-untracked.sh >/tmp/csu-out.txt 2>&1 ); }

# 1. GREEN: patterns that match nothing tracked.
mkcfg "  '''^secrets/''',
  '''^\.env\$''',"
if run; then ok "clean tree with 2 patterns -> rc=0"; else bad "clean tree should pass; got: $(cat /tmp/csu-out.txt)"; fi
has 'none matched by any of the 2 allowlist patterns' "prints the DENOMINATOR (2 patterns) so a parse collapse is visible" "no denominator in output: $(cat /tmp/csu-out.txt)"

# 2. RED, the round's prescribed proof: a 7th entry pointing at a TRACKED file.
mkcfg "  '''^secrets/''',
  '''^README\.md\$''',"
if run; then bad "an allowlist entry matching a TRACKED file must FAIL"; else ok "allowlisted+tracked -> rc!=0"; fi
has 'README.md'                  "names the offending FILE" "does not name the file"
has '\^README'                   "names the offending PATTERN" "does not name the pattern"

# 3. VACUITY GUARD 1: an unparseable paths block must FAIL, not silently pass.
printf '[allowlist]\npaths = [\n  "double-quoted-not-triple"\n]\n' > "$TD/.gitleaks.toml"
if run; then bad "zero parsed patterns must FAIL (else the gate passes by not looking)"; else ok "0 patterns parsed -> rc!=0"; fi
has 'parsed ZERO'                "says WHY (parser/config diverged)" "unhelpful message"

# 4. VACUITY GUARD 2: no tracked files must FAIL, not report OK over an empty set.
EMPTY="$(mktemp -d)"; git -C "$EMPTY" init -q; mkdir -p "$EMPTY/scripts"; cp "$GATE" "$EMPTY/scripts/"
mkcfg "  '''^secrets/''',"; cp "$TD/.gitleaks.toml" "$EMPTY/.gitleaks.toml"
if ( cd "$EMPTY" && ./scripts/check-secrets-untracked.sh >/tmp/csu-out.txt 2>&1 ); then
  bad "an empty tracked-file list must FAIL"; else ok "0 tracked files -> rc!=0"; fi
rm -rf "$EMPTY"

# 5. THE DISCRIMINATOR: `^bundle/` allowlisted, a bundle file TRACKED.
#    The OLD gate hardcoded {.env, secrets, .env.state, .jumpbox} and never looked at bundle/, so
#    it returned 0 here. If this case ever goes green again, the derivation has been undone.
mkcfg "  '''^secrets/''',
  '''^\.env\$''',
  '''^\.env\.state''',
  '''^\.jumpbox/''',
  '''^bundle/''',"
if run; then
  bad "DISCRIMINATOR: ^bundle/ allowlisted + bundle/manifest.txt tracked must FAIL (the OLD gate passed this)"
else
  ok "DISCRIMINATOR: catches the tracked bundle/ file the hardcoded gate could not see"
fi
has 'bundle/manifest.txt'        "names the tracked bundle file" "does not name bundle/manifest.txt"

echo
echo "check-secrets-untracked tests: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
