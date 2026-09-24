#!/usr/bin/env bash
# test-build-arch.sh — B736: an image of the wrong architecture must never reach Harbor.
#
# Offline, no container engine, no qemu: synthetic archives (docker-archive and OCI-in-tar shapes)
# for assert_tarball_platform, and a stub engine on PATH for require_build_arch. Plus an ORDER check:
# in both push scripts the platform assertion must come BEFORE `crane push`, or it guards nothing.
# shellcheck disable=SC2016  # single quotes are the point: bash -c bodies, a stub script, grep patterns
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
fail=0; n=0
ok()  { n=$((n + 1)); printf '  ok    %s\n' "$1"; }
bad() { n=$((n + 1)); fail=1; printf '  FAIL  %s\n' "$1"; }

# mk_archive <file> <config-json> <config-path-inside-tar>
mk_archive() {
  local d; d="$(mktemp -d "${T}/a.XXXX")"
  mkdir -p "$d/$(dirname "$3")"
  printf '%s' "$2" > "$d/$3"
  printf '[{"Config":"%s","RepoTags":["x:1"],"Layers":[]}]' "$3" > "$d/manifest.json"
  tar -C "$d" -cf "$1" manifest.json "$3"
}
cfg() { printf '{"architecture":"%s","os":"%s","rootfs":{"type":"layers","diff_ids":[]}}' "$1" "$2"; }

mk_archive "$T/amd64.tar"   "$(cfg amd64 linux)" "abc.json"
mk_archive "$T/arm64.tar"   "$(cfg arm64 linux)" "abc.json"
mk_archive "$T/noarch.tar"  '{"os":"linux","rootfs":{"type":"layers","diff_ids":[]}}' "abc.json"
mk_archive "$T/oci.tar"     "$(cfg amd64 linux)" "blobs/sha256/0123456789abcdef"
mk_archive "$T/windows.tar" "$(cfg amd64 windows)" "abc.json"
printf 'not a tar' > "$T/garbage.tar"

# check <want: pass|die> <label> <tarball> [MIRROR_ARCH]
check() {
  local out rc
  out="$(MIRROR_ARCH="${4:-}" bash -c '. "$1/scripts/lib/os.sh"; assert_tarball_platform "$2"' _ "$REPO_ROOT" "$3" 2>&1)"; rc=$?
  if [ "$1" = pass ] && [ "$rc" -eq 0 ]; then ok "$2"
  elif [ "$1" = die ] && [ "$rc" -ne 0 ]; then ok "$2 (refused: ${out##*msg=})"
  else bad "$2 — want $1, got rc=$rc: $out"; fi
}
echo "== assert_tarball_platform"
check pass "amd64 docker-archive passes (default MIRROR_ARCH)"      "$T/amd64.tar"
check pass "amd64 OCI-in-tar (Config blobs/sha256/…) passes"        "$T/oci.tar"
check die  "arm64 image is REFUSED"                                  "$T/arm64.tar"
check pass "arm64 image passes when MIRROR_ARCH=arm64"               "$T/arm64.tar" arm64
check die  "a config with no architecture is REFUSED (fail closed)" "$T/noarch.tar"
check die  "a windows image is REFUSED"                              "$T/windows.tar"
check die  "a non-tar file is REFUSED"                               "$T/garbage.tar"
check die  "a missing file is REFUSED"                               "$T/missing.tar"

echo "== require_build_arch (stub engine on PATH)"
mkdir -p "$T/bin"
printf '#!/bin/sh\n[ "$STUB_ARCH" = none ] || echo "$STUB_ARCH"\n' > "$T/bin/podman"; chmod +x "$T/bin/podman"
# rba <want: pass|die> <label> <stub-arch> [BUILD_EMULATE]
rba() {
  local rc
  PATH="$T/bin:$PATH" STUB_ARCH="$3" BUILD_EMULATE="${4:-0}" MIRROR_ARCH="" bash -c \
    '. "$1/scripts/lib/os.sh"; . "$1/scripts/lib/engine.sh"; require_build_arch podman' _ "$REPO_ROOT" >/dev/null 2>&1; rc=$?
  if { [ "$1" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$1" = die ] && [ "$rc" -ne 0 ]; }; then ok "$2"
  else bad "$2 — want $1, got rc=$rc"; fi
}
rba pass "x86_64 engine builds amd64"                       x86_64
rba die  "aarch64 engine is REFUSED"                        aarch64
rba pass "aarch64 engine with BUILD_EMULATE=1 proceeds"     aarch64 1
rba die  "an engine that reports nothing is REFUSED"        none

echo "== order: the assertion precedes crane push in both push scripts"
for f in 22-builder-push.sh 22-selfbuilt-push.sh; do
  a="$(grep -n 'assert_tarball_platform' "$REPO_ROOT/scripts/$f" | head -1 | cut -d: -f1)"
  c="$(grep -n 'crane push "\$tarball"' "$REPO_ROOT/scripts/$f" | head -1 | cut -d: -f1)"
  if [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; then ok "$f: line $a < crane push line $c"
  else bad "$f: assert_tarball_platform (${a:-absent}) must come before crane push (${c:-absent})"; fi
done
for f in 14-builder-build.sh 14-selfbuilt-build.sh; do
  if grep -q 'require_build_arch' "$REPO_ROOT/scripts/$f" && grep -q -- '--platform "linux/$(target_arch)"' "$REPO_ROOT/scripts/$f"; then
    ok "$f: preflight + --platform present"
  else bad "$f: missing require_build_arch or --platform"; fi
done

echo "test-build-arch: ${n} checks"
[ "$fail" -eq 0 ] && { echo "test-build-arch: OK"; exit 0; }
echo "test-build-arch: FAILED"; exit 1
