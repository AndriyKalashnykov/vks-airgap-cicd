#!/usr/bin/env bash
# scripts/test-mirror-cache.sh — OFFLINE unit tests for scripts/lib/mirror.sh's
# cache-skip / resume / prune logic (the `.mirror-ok` sentinel + orphan-dir prune).
# NO network, NO cluster, NO registry — pure-function tests on synthetic fixtures.
#
# What's covered, and the boundary:
#   * mirror_src_digest  — THE skip-vs-repull discriminator. A digest-pinned ref is
#     cache-skip-eligible (returns its @sha256 digest); a tag-based ref is not (empty
#     → always re-pulled). Pure, lives in lib/mirror.sh.
#   * mirror_cache_dir   — the deterministic cache-dir path where the `.mirror-ok`
#     sentinel lives. Pure, lives in lib/mirror.sh.
#   * mirror_prune_cache — deletes orphaned old-digest cache dirs, KEEPS current ones,
#     and REFUSES to prune when the manifest keep-set is incomplete. Pure (no registry).
#   * BOUNDARY: the cache-SKIP DECISION itself is an inline compound predicate in
#     scripts/10-mirror-pull.sh (lines ~74-75), NOT a function, built from the two pure
#     primitives above + the `.mirror-ok` sentinel. We reproduce that exact predicate
#     here (cache_should_skip) so the resume semantics are locked, but the code a RED
#     actually breaks is the lib/mirror.sh primitives it calls.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3], got [$2])"; fi; }
neq() { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both [$2])"; fi; }

# Faithful copy of the cache-skip predicate in scripts/10-mirror-pull.sh, built ENTIRELY
# on the sourced lib/mirror.sh primitives + the `.mirror-ok` sentinel. Returns 0 (skip)
# / non-zero (re-pull). Always called via `if` so its non-zero return never trips set -e.
cache_should_skip() {
  local src="$1" want_dg dst_dir
  want_dg="$(mirror_src_digest "$src")"
  dst_dir="$(mirror_cache_dir "$src")"
  [ "${MIRROR_FORCE_PULL:-0}" != "1" ] && [ -n "$want_dg" ] \
    && [ -f "$dst_dir/.mirror-ok" ] && [ "$(cat "$dst_dir/.mirror-ok" 2>/dev/null)" = "$want_dg" ]
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DIGEST="sha256:1111111111111111111111111111111111111111111111111111111111111111"
WRONG="sha256:2222222222222222222222222222222222222222222222222222222222222222"
DPIN="registry.k8s.io/foo/bar:v1.2.3@${DIGEST}"   # digest-pinned (skip-eligible)
TAGREF="docker.io/gitea/gitea:1.26.4"             # tag-only (always re-pull)

export IMAGE_CACHE_DIR="${WORK}/cache"; mkdir -p "$IMAGE_CACHE_DIR"

echo "== mirror_src_digest — the skip-vs-repull discriminator =="
eq "digest-pinned ref returns its digest (cache-skip eligible)" "$(mirror_src_digest "$DPIN")" "$DIGEST"
eq "tag-only ref returns empty (always re-pulled)"              "$(mirror_src_digest "$TAGREF")" ""

echo "== mirror_cache_dir — deterministic sentinel location =="
cd1="$(mirror_cache_dir "$DPIN")"
case "$cd1" in
  "$IMAGE_CACHE_DIR"/*) ok "cache dir is under IMAGE_CACHE_DIR" ;;
  *) bad "cache dir not under IMAGE_CACHE_DIR ($cd1)" ;;
esac
eq  "same src → same cache dir (deterministic)" "$(mirror_cache_dir "$DPIN")" "$cd1"
neq "distinct src → distinct cache dir"         "$(mirror_cache_dir "$TAGREF")" "$cd1"

echo "== cache-skip / resume decision (10-mirror-pull.sh predicate over the primitives) =="
dst="$(mirror_cache_dir "$DPIN")"; mkdir -p "$dst"
printf '%s\n' "$DIGEST" > "$dst/.mirror-ok"
if cache_should_skip "$DPIN"; then ok "correct-digest sentinel → SKIP"; else bad "correct-digest sentinel should SKIP"; fi
printf '%s\n' "$WRONG" > "$dst/.mirror-ok"
if cache_should_skip "$DPIN"; then bad "wrong-digest sentinel should RE-PULL"; else ok "wrong-digest sentinel → RE-PULL (resume)"; fi
rm -f "$dst/.mirror-ok"
if cache_should_skip "$DPIN"; then bad "absent sentinel should RE-PULL"; else ok "absent sentinel → RE-PULL (interrupted pull resumes)"; fi
tdst="$(mirror_cache_dir "$TAGREF")"; mkdir -p "$tdst"; printf 'whatever\n' > "$tdst/.mirror-ok"
if cache_should_skip "$TAGREF"; then bad "tag-based ref should always RE-PULL"; else ok "tag-based ref → always RE-PULL (even with a sentinel)"; fi
printf '%s\n' "$DIGEST" > "$dst/.mirror-ok"
if ( MIRROR_FORCE_PULL=1; cache_should_skip "$DPIN" ); then bad "MIRROR_FORCE_PULL=1 should RE-PULL"; else ok "MIRROR_FORCE_PULL=1 → RE-PULL (overrides a correct sentinel)"; fi

echo "== mirror_prune_cache — orphan prune + safety guard =="
FROOT="${WORK}/repo"; mkdir -p "$FROOT/images"
printf '%s\n' 'alpine/git:v2.54.0' 'gitea/gitea:1.26.4' > "$FROOT/images/images.txt"
export REPO_ROOT="$FROOT"
export BUNDLE_DIR="${WORK}/bundle"; mkdir -p "$BUNDLE_DIR/manifests"
printf 'image: gcr.io/kaniko-project/executor:v1.24.0-debug\n' > "$BUNDLE_DIR/manifests/dummy.yaml"
export IMAGE_CACHE_DIR="${WORK}/pcache"; mkdir -p "$IMAGE_CACHE_DIR"
k1="$(basename "$(mirror_cache_dir 'alpine/git:v2.54.0')")"
k2="$(basename "$(mirror_cache_dir 'gitea/gitea:1.26.4')")"
k3="$(basename "$(mirror_cache_dir 'gcr.io/kaniko-project/executor:v1.24.0-debug')")"
mkdir -p "$IMAGE_CACHE_DIR/$k1" "$IMAGE_CACHE_DIR/$k2" "$IMAGE_CACHE_DIR/$k3" "$IMAGE_CACHE_DIR/orphan_old_digest"
n="$(mirror_prune_cache)"
eq "prunes exactly the 1 orphaned cache dir" "$n" "1"
if [ -d "$IMAGE_CACHE_DIR/$k1" ] && [ -d "$IMAGE_CACHE_DIR/$k2" ] && [ -d "$IMAGE_CACHE_DIR/$k3" ]; then
  ok "kept every current-image cache dir"; else bad "a current-image cache dir was wrongly pruned"; fi
if [ ! -d "$IMAGE_CACHE_DIR/orphan_old_digest" ]; then ok "removed the orphaned dir"; else bad "orphan dir survived"; fi

# Safety guard: an absent/empty manifest dir makes the keep-set INCOMPLETE, so prune must
# REFUSE (return 0, delete nothing) rather than wipe every manifest-derived image.
rm -f "$BUNDLE_DIR"/manifests/*
mkdir -p "$IMAGE_CACHE_DIR/orphan2"
n2="$(mirror_prune_cache)"
eq "refuses to prune when manifests are absent/empty (returns 0)" "$n2" "0"
if [ -d "$IMAGE_CACHE_DIR/orphan2" ]; then ok "orphan preserved when keep-set is incomplete (guard)"; else bad "orphan wrongly deleted under an incomplete keep-set"; fi

echo
printf 'test-mirror-cache: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
