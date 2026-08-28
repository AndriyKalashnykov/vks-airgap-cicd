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
if grep -q 'grep -acw' "$SCRIPT_DIR/14-selfbuilt-build.sh"; then
  ok "14-selfbuilt-build.sh still greps with -w"
else bad "14-selfbuilt-build.sh no longer uses 'grep -acw' — the substring false-verify is back"; fi

# The probe must NOT start a container. On a cgroup-v1 host (Photon 5 boots v1 by DEFAULT, and
# Photon is a jump-box OS we are handed) rootless `<engine> run` cannot start at all: crun cannot
# create the container cgroup under the root-owned v1 `devices` controller, and podman reports rc
# 127 -- the SAME code as a genuinely missing shell. The old code fell through to its else-branch
# and blamed the IMAGE, silently, on every photon row. Grepping the already-saved tarball has no
# runtime at all, so it works on v1 and v2 alike.
# shellcheck disable=SC2016  # literal source text — see the note on the first such grep below.
if grep -qE '"\$ENGINE" run|\$\{ENGINE\} run|podman run|docker run' "$SCRIPT_DIR/14-selfbuilt-build.sh"; then
  bad "the probe starts a CONTAINER again — that cannot run rootless on cgroup v1 (Photon 5 default)"
else ok "the probe starts no container (works on cgroup v1, where rootless run cannot)"; fi

# ---- the vacuity guard must select metadata by CONTENT, not by filename ----------------------
# `docker save` emits an OCI layout whose members are ALL `blobs/sha256/<digest>` with NO EXTENSION,
# and the config blob among them carries the `created_by` history — i.e. exactly where our injected
# `RUN go get` text lands. A `*.json` name filter is therefore VACUOUS ON DOCKER, blind precisely to
# the case the guard exists for. This fixture reproduces that member shape.
FIX="$TMP/fix"; mkdir -p "$FIX/blobs/sha256"
printf '{"history":[{"created_by":"RUN go get github.com/example/mod@v1.2.3"}]}' \
  > "$FIX/blobs/sha256/deadbeef"
( cd "$FIX" && tar -cf "$TMP/oci.tar" blobs ) 2>/dev/null
by_name=$(tar -tf "$TMP/oci.tar" 2>/dev/null | grep -c '\.json$' || true)
by_content=0
while read -r _sz _m; do
  case "$_sz" in ''|*[!0-9]*) continue ;; esac
  [ "$_sz" -le 1048576 ] || continue
  case "$(tar -xOf "$TMP/oci.tar" "$_m" 2>/dev/null | head -c 1)" in '{') ;; *) continue ;; esac
  h=$(tar -xOf "$TMP/oci.tar" "$_m" 2>/dev/null | grep -acw 'github.com/example/mod.v1.2.3' || true)
  case "$h" in ''|*[!0-9]*) h=0 ;; esac
  by_content=$((by_content + h))
done <<EOF
$(tar -tvf "$TMP/oci.tar" 2>/dev/null | awk '$1 !~ /^d/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i, $NF; break } }')
EOF
if [ "$by_name" -eq 0 ]; then
  ok "fixture reproduces the docker blind spot: a *.json filter sees 0 members"
else bad "fixture no longer reproduces the blind spot (by_name=$by_name) — the case below is vacuous"; fi
# EXACTLY 1: `tar -xOf <dir>` dumps everything beneath it, so without the directory skip
# each ancestor re-yields the same bytes and this reads 3. An inflated count is a FALSE
# vacuity warning in production, so pin the exact value, not ">= 1".
if [ "$by_content" -eq 1 ]; then
  ok "the CONTENT filter DOES find the metadata hit a name filter misses (${by_content})"
else bad "content filter returned $by_content, want exactly 1 (0 = vacuous on docker; >1 = directory members double-counted -> false vacuity warnings)"; fi

# shellcheck disable=SC2016  # single quotes are DELIBERATE: this greps for the LITERAL source
# text of the probe. Expanding it here would search for this test's own (empty) variables and the
# assertion would pass on any file, which is the vacuous-green this case exists to prevent.
if grep -q 'grep -acw "${_want_mod}.${_want_ver}" "$tarball"' "$SCRIPT_DIR/14-selfbuilt-build.sh"; then
  ok "the probe greps the SAVED TARBALL (no engine call, no cgroups)"
else bad "the probe no longer greps \$tarball — the cgroup-v1-proof route is gone"; fi

# The tar also carries manifest.json and the image config, whose history records the very
# `RUN go get <mod>@<ver>` this script injects. Today the go_get runs in a DISCARDED builder stage
# so the metadata contributes zero hits; if it ever moved to the final stage the metadata alone
# would satisfy the check and it would verify itself.
# ⚠️ Grep the USAGE FORM, not the bare name: `_json_hits` also appears inside the warn MESSAGE, so
# a name-only grep stays green when the guard is deleted. Caught by RED-proving this very test —
# removing the guard left it passing. Both the accumulate and the branch must be present.
# shellcheck disable=SC2016  # literal source text again — see the note above.
if grep -q '_json_hits=$((_json_hits + _jh))' "$SCRIPT_DIR/14-selfbuilt-build.sh" \
   && grep -q '\[ "$_json_hits" -gt 0 \]' "$SCRIPT_DIR/14-selfbuilt-build.sh"; then
  ok "the vacuity guard is present (metadata hits counted separately)"
else bad "the vacuity guard is gone — image METADATA could satisfy the check on its own"; fi

rm -rf "$TMP"
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
