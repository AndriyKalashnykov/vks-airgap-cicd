#!/usr/bin/env bash
# 24-mirror-verify-red-test.sh — NEGATIVE test proving the mirror-verify integrity
# gate actually CATCHES a corrupt/missing image in Harbor.
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
log_info "asserting mirror-verify now FAILS (the integrity gate must catch the missing image)"
if verify; then
  die "RED-TEST FAILED: mirror-verify PASSED after $dst was deleted — the integrity gate does NOT catch corruption!"
fi

log_info "RED-TEST PASSED: mirror-verify correctly FAILED after $dst was deleted — restoring via the EXIT trap"
# 4. restore() fires on EXIT.
