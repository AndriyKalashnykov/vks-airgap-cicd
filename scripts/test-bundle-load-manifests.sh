#!/usr/bin/env bash
# ci-tier: fast — pure filesystem + the real mirror_collect_images. No network, no registry.
#
# test-bundle-load-manifests.sh — the AIR-GAP half of B702's prune (B705).
#
# THE DEFECT IT PINS, measured 2026-09-06 by an end-of-session adversary round:
#   `tar -x` MERGES; it never deletes a file the archive lacks. That was harmless while the
#   INTERNET box also accumulated manifests forever — the bundle then carried every version's
#   image cache too, so the wanted-set and the cache agreed (wastefully, but they agreed).
#
#   B702's prune broke that symmetry. The internet box now ships ONLY the pinned manifests and
#   ONLY their images, while the air-gap box still held the PREVIOUS bundle's superseded
#   manifest. mirror_collect_images greps EVERY file in that directory and is called by
#   21-mirror-push.sh:64 and 23-mirror-verify.sh:54 — BOTH of which run on the air-gap box.
#   The wanted-set therefore named images the new cache does not carry, and
#   21-mirror-push.sh:73 reports "cache missing for <img>" and :84 DIES — naming images the
#   operator never asked for, on the box with no internet and no way to diagnose it.
#
# ⚠️ SCOPE — what this does NOT cover. It asserts the INVARIANT (what the wanted-set contains
#   for a given manifest directory) using the REAL mirror_collect_images. It does NOT exercise
#   20-bundle-load.sh's mv-aside / restore-on-failure plumbing, which needs a real tarball and a
#   toolchain install. Case 3 is therefore the closest available proxy, not a test of that code.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

log_info() { :; }; log_warn() { :; }; log_error() { printf '%s\n' "$*" >&2; }
die() { log_error "$*"; exit 1; }

# shellcheck source=scripts/lib/mirror.sh
. scripts/lib/mirror.sh 2>/dev/null || { echo "FAIL  cannot source lib/mirror.sh" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export BUNDLE_DIR="$TMP/bundle"
export REPO_ROOT="$TMP/repo"
mkdir -p "$BUNDLE_DIR/manifests" "$REPO_ROOT/images"
: > "$REPO_ROOT/images/images.txt"          # empty list: the manifests are the only source

_gen() {   # $1=dir  $2=version — a manifest naming that version's controller image
  printf 'image: gcr.io/tekton-releases/pipeline/cmd/controller:%s\n' "$2" \
    > "$1/tekton-pipelines-${2}.yaml"
}

# ---- case 1: THE DEFECT — a merged directory demands BOTH generations ---------------
_gen "$BUNDLE_DIR/manifests" v1.14.0        # bundle N, left behind by tar -x
_gen "$BUNDLE_DIR/manifests" v1.15.0        # bundle N+1, just extracted
got="$(mirror_collect_images | grep -c 'cmd/controller')"
if [ "$got" -eq 2 ]; then
  ok "case1: a MERGED manifest dir demands 2 generations (the failure mode)"
else bad "case1: wanted-set has $got controller ref(s), expected 2"; fi

# ---- case 2: THE FIX — a REPLACED directory demands only the pinned one -------------
rm -rf "$BUNDLE_DIR/manifests"; mkdir -p "$BUNDLE_DIR/manifests"
_gen "$BUNDLE_DIR/manifests" v1.15.0
got="$(mirror_collect_images | grep -c 'cmd/controller')"
stale="$(mirror_collect_images | grep -c 'controller:v1.14.0')"
if [ "$got" -eq 1 ] && [ "$stale" -eq 0 ]; then
  ok "case2: a REPLACED manifest dir demands only the pinned generation"
else bad "case2: controller refs=$got stale=$stale, wanted 1 and 0"; fi

# ---- case 3: the set-aside must be RECOVERABLE (proxy for restore-on-failure) -------
# On an air-gapped box the previous generation is the only copy in the building, so
# 20-bundle-load.sh moves it aside rather than deleting it. Assert a move round-trips.
rm -rf "$BUNDLE_DIR/manifests"; mkdir -p "$BUNDLE_DIR/manifests"
_gen "$BUNDLE_DIR/manifests" v1.14.0
saved="$BUNDLE_DIR/manifests.prev.$$"
mv -- "$BUNDLE_DIR/manifests" "$saved"
if [ ! -d "$BUNDLE_DIR/manifests" ] && [ -f "$saved/tekton-pipelines-v1.14.0.yaml" ]; then
  mv -- "$saved" "$BUNDLE_DIR/manifests"
  if [ -f "$BUNDLE_DIR/manifests/tekton-pipelines-v1.14.0.yaml" ]; then
    ok "case3: set-aside round-trips, so a failed extraction is recoverable"
  else bad "case3: restore did not bring the manifest back"; fi
else bad "case3: set-aside did not move the directory"; fi

# ---- case 4: the fix is WIRED — 20-bundle-load.sh must replace, not merge -----------
# Grep the CODE SHAPE, not a name that also appears in the comment above it.
# shellcheck disable=SC2016  # the single quotes are the POINT: this greps another
# file's SOURCE for a literal `$name`. Double quotes would expand it here (unset), so the
# pattern would silently become one that matches nothing — a vacuous, always-green check.
if grep -qE '^\s*mv -- "\$_mfst" "\$_mfst_old"' scripts/20-bundle-load.sh; then
  ok "case4: 20-bundle-load.sh sets the previous manifest dir aside before extracting"
else bad "case4: 20-bundle-load.sh does NOT set the manifest dir aside — tar -x will MERGE"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
