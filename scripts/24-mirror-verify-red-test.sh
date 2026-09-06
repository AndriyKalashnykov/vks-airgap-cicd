#!/usr/bin/env bash
# 24-mirror-verify-red-test.sh — NEGATIVE test proving the mirror-verify gate actually CATCHES an
# image that is MISSING from Harbor.
#
# ⚠️ IT PROVES **ABSENT**, NOT **CORRUPT** — and saying so is the point (B703). This test DELETES a
# manifest, and since B703 a deleted manifest classifies **ABSENT** (`NOT_FOUND` from Harbor, or the
# OCI-standard `MANIFEST_UNKNOWN`), not CORRUPT. It still exits non-zero, so nothing LOOKED broken —
# which is exactly why this header had to change: moving `MANIFEST_UNKNOWN` out of CORRUPT silently
# re-pointed this test at a different verdict while its prose went on claiming the old one. A test
# asserting only `rc != 0` cannot notice that, so the assertion below now checks the CLASS.
#
# ⚠️ CONSEQUENCE, STATED PLAINLY: the **CORRUPT** verdict (`fails`) has **NO live RED anywhere in
# this repo** — it is covered by fixtures in `test-mirror-verify-class.sh` only. Producing a real one
# needs a genuinely damaged BLOB with an intact manifest (the 2026-07-13 shape), which this test does
# not create. Do not read a green here as evidence that the corruption path works.
#
# ⚠️ AND IT CANNOT RUN WITH THE CREDENTIAL THIS REPO MINTS (B711). MEASURED 2026-09-06: the delete
# fails `UNAUTHORIZED: ... action: delete` because `22-harbor-robot.sh` mints push+pull only, by
# design. Use an admin credential, or expect this to stop at the delete step.
#
# Why this exists: `make mirror-verify` (23) is only ever OBSERVED green — a gate's
# real value is its demonstrated RED (see rules/common/testing.md "a gate's value is
# its demonstrated RED"). This test deliberately DELETES one already-mirrored image's
# manifest from Harbor, asserts that `23-mirror-verify.sh` then FAILS non-zero, and
# RESTORES the image by re-pushing it from the local OCI cache.
#
# Requires a LIVE Harbor with the images already mirrored (run after `make mirror`,
# e.g. inside `make e2e-kind`). It MUTATES Harbor — never run it concurrently with a
# real mirror/pipeline (see the no-concurrent-load rule).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"

require_cmd crane

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${IMAGE_CACHE_DIR:?}"

HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
# harbor_setup exports SSL_CERT_FILE (crane trusts the self-signed CA) + sets HARBOR_TLS_VERIFY.
harbor_setup "$HARBOR_TMP"
INSECURE=(); [ "$HARBOR_TLS_VERIFY" = "false" ] && INSECURE=(--insecure)

# crane delete needs auth (admin creds carry manifest-delete). Password on stdin, never argv.
log_info "logging in to Harbor $HARBOR_URL as $HARBOR_USERNAME"
printf '%s' "$HARBOR_PASSWORD" | run crane auth login "$HARBOR_URL" \
  --username "$HARBOR_USERNAME" --password-stdin

# --- Pick a reversible victim: a TAG-based image with a local cache to restore from ---
mapfile -t IMAGES < <(mirror_collect_images)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images to test (run 'make mirror' first)"

victim=""
# Prefer a tag-based (single-arch) image — cheapest to delete + re-push.
for src in "${IMAGES[@]}"; do
  [ -n "$(mirror_src_digest "$src")" ] && continue          # skip multi-arch digest-pinned (heavier)
  [ -d "$(mirror_cache_dir "$src")" ] || continue           # must have a local copy to restore from
  victim="$src"; break
done
# Fall back to ANY image that has a local cache dir.
if [ -z "$victim" ]; then
  for src in "${IMAGES[@]}"; do
    [ -d "$(mirror_cache_dir "$src")" ] && { victim="$src"; break; }
  done
fi
[ -n "$victim" ] || die "no mirrored image with a local cache dir found — cannot run the reversible RED test (run 'make mirror-pull' first)"

dst="$(mirror_target_ref "$victim")"
cache="$(mirror_cache_dir "$victim")"
log_info "RED-test victim: $victim -> $dst"

# --- Restore is armed BEFORE the destructive delete, so any exit re-pushes the image ---
restore() {
  log_info "restoring $dst from local cache $cache"
  mirror_retry "${MIRROR_RETRIES:-5}" run crane push "${INSECURE[@]}" "$cache" "$dst" \
    || log_error "RESTORE FAILED for $dst — re-run 'make mirror-push' to fully restore Harbor"
}
trap 'restore; rm -rf "$HARBOR_TMP"' EXIT

verify() { "${SCRIPT_DIR}/23-mirror-verify.sh"; }

# 1. PRE-CHECK — the intact mirror must currently PASS, else a later RED is meaningless.
#    (Skip with RED_TEST_SKIP_PRECHECK=1 when chained right after a known-good verify.)
if [ "${RED_TEST_SKIP_PRECHECK:-0}" != "1" ]; then
  log_info "pre-check: mirror-verify should PASS on the intact mirror"
  verify || die "pre-check FAILED: mirror-verify is already red before corruption — fix the mirror first"
fi

# 2. CORRUPT — delete the victim's manifest from Harbor (simulates a missing/corrupt image).
log_info "deleting $dst from Harbor (simulating registry corruption)"
run crane delete "${INSECURE[@]}" "$dst"

# 3. ASSERT RED — mirror-verify MUST now fail non-zero. `if verify; then` inverts cleanly.
log_info "asserting mirror-verify now FAILS, and FAILS AS 'ABSENT' (not as corruption)"
# Assert the CLASS, not merely the exit code. `rc != 0` alone cannot tell "the gate caught it" from
# "the gate failed for some unrelated reason", and it is what let this test go on passing while the
# verdict it exercises changed underneath it.
_out="$(verify 2>&1)" && _vrc=0 || _vrc=$?
if [ "$_vrc" -eq 0 ]; then
  die "RED-TEST FAILED: mirror-verify PASSED after $dst was deleted — the gate does NOT catch a missing image!"
fi
if ! printf '%s' "$_out" | grep -q 'ABSENT'; then
  printf '%s\n' "$_out" | tail -20 >&2
  die "RED-TEST FAILED: mirror-verify failed, but NOT with the ABSENT verdict. A deleted manifest must
  classify ABSENT (remedy: re-push this one image), never CORRUPT (remedy: re-carry a 12 GB bundle).
  See the output above for what it said instead."
fi

log_info "RED-TEST PASSED: mirror-verify FAILED with the ABSENT verdict after $dst was deleted — restoring via the EXIT trap"
# 4. restore() fires on EXIT.
