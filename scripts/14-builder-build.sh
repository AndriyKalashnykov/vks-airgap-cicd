#!/usr/bin/env bash
# 14-builder-build.sh — (INTERNET side, NO Harbor needed) build each app's offline Maven builder image
# and SAVE it into the bundle. Its sibling 22-builder-push.sh pushes it to Harbor from the air-gap box.
#
# WHY THIS EXISTS — `make builder-image` was unrunnable on EITHER sneakernet box
# ---------------------------------------------------------------------------
# The builder needs TWO networks at once, and sneakernet's whole premise is that no box has both:
#   * MAVEN CENTRAL — Dockerfile.builder runs `mvn verify` to bake ~/.m2 (that IS the point: the
#     in-cluster Kaniko build cannot reach Maven Central, so the deps must be pre-baked).
#   * HARBOR        — its base was pulled from Harbor, a login probe ran BEFORE the build, and the
#     result was pushed to Harbor.
# So on a sneakernet split the OUTSIDE box died at the Harbor login and the INSIDE box died inside
# `mvn verify`. The mirror completed and the offline Java build could not be produced — and the e2e
# could not see it, because its "air-gap box" only did bundle-load -> mirror-push -> mirror-verify
# while the builder was built by the dual-homed HOST.
#
# The split: build HERE (internet only) -> save into bundle/builders/ -> carry -> push THERE (Harbor only).
#
# THE BASE COMES FROM images.lock, BY DIGEST — not from Harbor, and not from a bare public tag.
# This box has no Harbor. But `10-mirror-pull.sh` already resolved every image to a digest in
# bundle/images.lock, so we pull the base from its PUBLIC registry AT THAT EXACT DIGEST: byte-identical
# to the image that is in the bundle, and identical to what Harbor will serve after mirror-push. That
# makes builder<->mirror alignment true BY CONSTRUCTION — better than any gate. (images.txt pins maven
# by TAG, so a naive public pull at build time could legitimately be a DIFFERENT image.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

: "${BUILDER_IMAGE_TAG:?}"
: "${BUNDLE_DIR:?}"

# NOTE: no HARBOR_* is required here, deliberately. This box does not have Harbor and must not need it.

# `if ... fi`, not `A && B`: a bare `A && B` returns non-zero when A is false, so the last iteration
# (an app with no Dockerfile.builder) would make the command substitution fail and `set -e` kill us.
BUILDER_APPS="$(app_names | while read -r a; do if app_has_builder "$a"; then printf '%s ' "$a"; fi; done)"
if [ -z "$BUILDER_APPS" ]; then
  log_info "no app ships a Dockerfile.builder — nothing to build (a stdlib-only app needs no offline dependency cache)"
  exit 0
fi

LOCK="${BUNDLE_DIR}/images.lock"
[ -f "$LOCK" ] || die "no ${LOCK} — run 'make mirror-pull' first.
  The builder's base image is pinned to the DIGEST the mirror resolved, so the builder and the mirrored
  base are the same bytes by construction. Without the lock there is nothing to pin to."

MAVEN_SRC="maven:3.9-eclipse-temurin-25"
# `|| true`: grep exits 1 on no-match and 2 on a missing file — either would kill this script under
# `set -e` with NO output, an error shape this repo has hit four times.
MAVEN_DIGEST="$(awk -v k="$MAVEN_SRC" '$1==k{print $2}' "$LOCK" 2>/dev/null | head -1 || true)"
[ -n "$MAVEN_DIGEST" ] || die "'${MAVEN_SRC}' has no digest in ${LOCK} — re-run 'make mirror-pull'."
BUILD_BASE="docker.io/library/maven@${MAVEN_DIGEST}"

ENGINE="$(container_engine)"
log_info "engine=${ENGINE} · base pinned by digest from images.lock: ${MAVEN_SRC} -> ${MAVEN_DIGEST}"

OUT_DIR="${BUNDLE_DIR}/builders"
mkdir -p "$OUT_DIR"

for app in $BUILDER_APPS; do
  src="${REPO_ROOT}/$(app_src "$app")"
  # A LOCAL tag only. The destination ref is NOT computed here on purpose: it is
  # ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<app>-builder:<tag>, and this box does not know HARBOR_URL
  # (it has no Harbor). 22-builder-push.sh names the destination on the box that does.
  local_ref="localhost/${app}-builder:${BUILDER_IMAGE_TAG}"
  tarball="${OUT_DIR}/${app}-builder.tar"

  log_info "[${app}] building the offline builder (this pulls its Maven deps — needs the internet)"
  run "$ENGINE" build \
    --build-arg "MAVEN_IMAGE=${BUILD_BASE}" \
    -f "${src}/Dockerfile.builder" \
    -t "$local_ref" \
    "${src}"

  # A DOCKER-STYLE TARBALL, which is what `crane push` reads when PATH is a file (verified against
  # crane 0.21.7: "If the PATH is a directory, it will be read as an OCI image layout. Otherwise, PATH
  # is assumed to be a docker-style tarball."). Both podman and docker `save` produce exactly this — so
  # the air-gap box needs NO CONTAINER ENGINE to push it, only the crane the bundle already carries.
  log_info "[${app}] saving -> ${tarball} (carried in the bundle; pushed by 'make builder-push' on the air-gap box)"
  run "$ENGINE" save -o "$tarball" "$local_ref"

  # Record the tag the image was built for, so the far side pushes it under the SAME tag the pipeline
  # asks for. A tag mismatch here surfaces as an ImagePullBackOff at the far end of the pipeline.
  printf '%s\t%s\n' "$app" "$BUILDER_IMAGE_TAG" >> "${OUT_DIR}/builders.tsv.tmp"
done

# Rewrite atomically so a re-run does not append duplicates.
sort -u "${OUT_DIR}/builders.tsv.tmp" > "${OUT_DIR}/builders.tsv"
rm -f "${OUT_DIR}/builders.tsv.tmp"

log_info "builder images saved into the bundle for: ${BUILDER_APPS}"
log_info "next: make bundle   (they are carried by the existing tar — bundle/builders/ is inside BUNDLE_DIR)"
log_info "then, on the air-gap box: make builder-push"
