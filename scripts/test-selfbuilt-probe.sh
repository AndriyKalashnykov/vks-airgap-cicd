#!/usr/bin/env bash
# test-selfbuilt-probe.sh — REGRESSION GUARD for the go_get verification probe in
# scripts/14-selfbuilt-build.sh and the go_get validation in scripts/lib/selfbuilt.sh.
#
# WHAT IT GUARDS
# ---------------------------------------------------------------------------
# The probe proves a `go_get` dependency override actually reached the built kaniko binary, by
# grepping Go's plain-text embedded build info inside /kaniko/executor. Three defects were found in
# it on 2026-08-27 by an implementation-round adversary, all MEASURED against the real image, and
# every one of them fails in the SILENT direction:
#
#   1. HIGH — the pattern was an UNANCHORED SUBSTRING, so asking for v0.21.1 matched an embedded
#      v0.21.19 and the probe reported "verified in the binary" for a version nobody asked for.
#      It needs no malformed TSV: `go get mod@X` plus Go's minimal-version-selection can resolve
#      HIGHER than the request -- which is exactly the "we asked" vs "it happened" gap the probe
#      exists to close. The probe was blind to its own subject. Fixed with `grep -w`.
#   2. MED — an EMPTY version (`mod@`) passed validation, so the pattern became `<module>.` and
#      matched every build-info line: HITS=1197:RC=0 on the real image, i.e. VERIFIED having checked
#      no version at all.
#   3. MED — a single quote in the go_get field TERMINATES the quoting of the probe's inner `sh -c`.
#      Measured: a crafted value ran a command inside the container and returned rc=127, which
#      matches no arm and degraded to a silent "inconclusive" WARN.
#
# HONESTY (do not over-trust this green): this is OFFLINE. It proves the VALIDATION refuses the two
# malformed shapes, that the grep semantics distinguish a version from a longer version that starts
# with it, and that the source still carries `-w`. It does NOT run a container and does NOT prove the
# probe's exit-code classification end-to-end -- that is exercised by `make selfbuilt-image` against
# a real image, and the four arms were measured by hand on 2026-08-27:
#   match HITS=1:RC=0 -> verified · no match HITS=0:RC=1 -> die
#   grep errored HITS=:RC=2 -> WARN tooling · no shell rc=127 -> WARN no-shell
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

TMP="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
mkdir -p "$TMP/images"

# ---- validation: build a fixture repo root and drive selfbuilt_validate ---------------------
fixture() {   # $1 = the go_get field
  { printf '# fixture\n'
    printf 'kaniko\thttps://example.invalid/k\tv1.0.0\tdeploy/Dockerfile\tkaniko-debug\tk/executor\tv1.0.0-debug\t%s\t\n' "$1"
  } > "$TMP/images/selfbuilt.tsv"
}
validate() {  # -> rc of selfbuilt_validate against the fixture
  # REPO_ROOT is read by selfbuilt_file() inside the sourced library, which shellcheck cannot see
  # through the variable path -- hence the export (silences SC2034) and the source= directive.
  ( export REPO_ROOT="$TMP"
    # shellcheck source=scripts/lib/selfbuilt.sh
    . "$SCRIPT_DIR/lib/selfbuilt.sh" >/dev/null 2>&1 || exit 9
    selfbuilt_validate >/dev/null 2>&1 )
}

fixture 'github.com/google/go-containerregistry@v0.21.9'
if validate; then ok "a concrete go_get version is ACCEPTED"
else bad "a concrete go_get version was rejected (the positive control -- everything below is moot)"; fi

fixture 'github.com/google/go-containerregistry@'
if validate; then bad "an EMPTY go_get version was accepted (it makes the probe match EVERY line)"
else ok "an EMPTY go_get version is REFUSED"; fi

# ⚠️ NO SPACES IN THIS FIXTURE. `selfbuilt_validate` does `for _m in $_gg`, which WORD-SPLITS, so a
# realistic injection payload (`x'; touch /tmp/pwned; :'@v1.0.0`) is rejected by the "has no @version"
# arm on its `touch` token -- i.e. the assertion would pass while never exercising the quote guard.
# Caught by RED-proving this test: deleting the quote arm left it GREEN. A space-free value with a
# quote AND an @version reaches the arm under test and nothing else.
fixture "github.com/x'y@v1.0.0"
if validate; then bad "a single quote in go_get was accepted (it breaks the probe's inner sh -c)"
else ok "a single quote in go_get is REFUSED"; fi

fixture 'github.com/google/go-containerregistry@latest'
if validate; then bad "go_get @latest was accepted (not reproducible)"
else ok "go_get @latest is still REFUSED (pre-existing rule, not regressed)"; fi

# ---- the grep semantics the probe depends on ------------------------------------------------
# Go's build info is TAB-separated, so `.` in the pattern matches the tab and `-w` sees a non-word
# character on both sides of a real match.
printf 'dep\tgithub.com/google/go-containerregistry\tv0.21.19\th1:xyz\n' > "$TMP/buildinfo"
n_wrong_nw=$(grep -ac  'go-containerregistry.v0.21.1'  "$TMP/buildinfo"); rc_wrong_nw=$?
n_wrong_w=$(grep -acw  'go-containerregistry.v0.21.1'  "$TMP/buildinfo"); rc_wrong_w=$?
n_right_w=$(grep -acw  'go-containerregistry.v0.21.19' "$TMP/buildinfo"); rc_right_w=$?

# The RED this test exists for: WITHOUT -w the WRONG version matches. If this stops being true the
# fixture no longer reproduces the defect and the assertion below proves nothing.
if [ "$n_wrong_nw" -ge 1 ] && [ "$rc_wrong_nw" -eq 0 ]; then
  ok "fixture reproduces the defect: WITHOUT -w, v0.21.1 matches the embedded v0.21.19"
else bad "fixture no longer reproduces the defect (got HITS=$n_wrong_nw RC=$rc_wrong_nw) — the guard below is vacuous"; fi

if [ "$n_wrong_w" -eq 0 ] && [ "$rc_wrong_w" -eq 1 ]; then
  ok "WITH -w, the WRONG version does NOT match (HITS=0:RC=1 -> the probe DIES, correctly)"
else bad "WITH -w, a wrong version still matched (HITS=$n_wrong_w RC=$rc_wrong_w) -> SILENT FALSE VERIFY"; fi

if [ "$n_right_w" -ge 1 ] && [ "$rc_right_w" -eq 0 ]; then
  ok "WITH -w, the REAL version still matches (HITS=$n_right_w:RC=0 -> verified)"
else bad "WITH -w, the real version stopped matching (HITS=$n_right_w RC=$rc_right_w) -> the probe would die on a GOOD build"; fi

# ---- the source still carries the fix --------------------------------------------------------
# Greps the USAGE FORM, not a bare word: the rationale comment above the line contains "-w" in prose,
# so matching the word alone would pass on a source that had lost the flag.
if grep -q "grep -acw '" "$SCRIPT_DIR/14-selfbuilt-build.sh"; then
  ok "14-selfbuilt-build.sh still invokes grep with -w"
else bad "14-selfbuilt-build.sh no longer uses 'grep -acw' — the substring false-verify is back"; fi

if grep -q 'HITS=%s:RC=%s' "$SCRIPT_DIR/14-selfbuilt-build.sh"; then
  ok "the probe still reports its status in-band (HITS=:RC= sentinel)"
else bad "the HITS=/RC= sentinel is gone — grep's three-way status is collapsed again"; fi

rm -rf "$TMP"
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
