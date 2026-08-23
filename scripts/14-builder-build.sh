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
# So on a sneakernet split the INTERNET box died at the Harbor login and the AIR-GAP box died inside
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
# engine_build_isolation lives HERE, not in os.sh (which defines container_engine/engine_choice/
# engine_packages). Calling it without this source dies `command not found`, rc=127 — measured on a
# real matrix row, and invisible to `make ci` because no offline test executes this build path.
# shellcheck source=scripts/lib/engine.sh
. "${SCRIPT_DIR}/lib/engine.sh"
load_env

: "${BUILDER_IMAGE_TAG:=${BUILDER_IMAGE_TAG_DEFAULT:?lib/apps.sh must be sourced first}}"   # single-sourced in lib/apps.sh; .env/env/cmdline still override
: "${BUNDLE_DIR:?}"

# NOTE: no HARBOR_* is required here, deliberately. This box does not have Harbor and must not need it.

# `if ... fi`, not `A && B`: a bare `A && B` returns non-zero when A is false, so the last iteration
# (an app with no Dockerfile.builder) would make the command substitution fail and `set -e` kill us.
BUILDER_APPS="$(app_names | while read -r a; do if app_has_builder "$a"; then printf '%s ' "$a"; fi; done)"
if [ -z "$BUILDER_APPS" ]; then
  log_info "no app ships a Dockerfile.builder — nothing to build (an app whose build fetches nothing needs no pre-baked dependency cache). As of 2026-08-22 every app ships one, so reaching this line means the registry or the app dirs are not what you think."
  exit 0
fi

LOCK="${BUNDLE_DIR}/images.lock"
[ -f "$LOCK" ] || die "no ${LOCK} — run 'make mirror-pull' first.
  The builder's base image is pinned to the DIGEST the mirror resolved, so the builder and the mirrored
  base are the same bytes by construction. Without the lock there is nothing to pin to."


ENGINE="$(container_engine)"
log_info "engine=${ENGINE} · builder base(s) pinned by digest from images.lock (resolved PER APP below)"

OUT_DIR="${BUNDLE_DIR}/builders"
mkdir -p "$OUT_DIR"

for app in $BUILDER_APPS; do
  src="${REPO_ROOT}/$(app_src "$app")"
  # A LOCAL tag only. The destination ref is NOT computed here on purpose: it is
  # ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<app>-builder:<tag>, and this box does not know HARBOR_URL
  # (it has no Harbor). 22-builder-push.sh names the destination on the box that does.
  # PER-APP, INSIDE THE LOOP. This used to be one Maven base resolved ABOVE the loop, so it could
  # not vary per app: a node builder would have been handed `--build-arg MAVEN_IMAGE=<maven digest>`,
  # an ARG its Dockerfile never declares. MEASURED: podman prints `[Warning] one or more build args
  # were not consumed` and EXITS 0, so the build silently falls back to the ARG's own default -- an
  # UNPINNED base in an air-gap build. Renaming the variables would not have fixed it; moving the
  # resolution in here is what fixes it.
  base_key="$(app_builder_base "$app")"
  builder_arg="$(app_builder_arg "$app")"
  # `|| true`: awk exits non-zero on a missing file, which would kill this script under `set -e`
  # with NO output -- an error shape this repo has hit four times.
  base_digest="$(awk -v k="$base_key" '$1==k{print $2}' "$LOCK" 2>/dev/null | head -1 || true)"
  [ -n "$base_digest" ] || die "[${app}] '${base_key}' has no digest in ${LOCK} — is it in images/images.txt? Then re-run 'make mirror-pull'."
  build_base="$(app_builder_base_path "$app")@${base_digest}"

  # THE GUARD that makes the whole thing fail LOUDLY. An undeclared --build-arg is a WARNING and
  # exit 0, so without this a wrong ARG name ships an unpinned base and nothing says so. Assert the
  # Dockerfile actually declares it BEFORE spending a build on it.
  grep -qE "^[[:space:]]*ARG[[:space:]]+${builder_arg}(=|[[:space:]]|$)" "${src}/Dockerfile.builder" \
    || die "[${app}] ${src}/Dockerfile.builder does not declare 'ARG ${builder_arg}', which app_builder_arg() says it should. An undeclared --build-arg is only a WARNING (measured: podman exits 0), so this would have silently built on an UNPINNED base."

  local_ref="localhost/${app}-builder:${BUILDER_IMAGE_TAG}"
  tarball="${OUT_DIR}/${app}-builder.tar"

  log_info "[${app}] building the offline builder (this pulls its Maven deps — needs the internet)"
  # A cgroup-v1 box cannot build rootless at all; see engine_build_isolation() for the measured A/B.
  # ANNOUNCED, not applied silently -- it is a real isolation trade and the operator should see it.
  _iso="$(engine_build_isolation)"
  if [ -n "$_iso" ]; then
    export BUILDAH_ISOLATION="$_iso"
    log_warn "cgroup v1 detected — building with BUILDAH_ISOLATION=${_iso}: rootless podman cannot"
    log_warn "  create a container cgroup here. Weaker isolation, bounded — our Dockerfile, our base."
  fi
  # PROVENANCE LABELS. The tag alone cannot distinguish two builders built from different trees --
  # MEASURED 2026-08-23: bundle/builders/rustwebapp-builder.tar (config ebbbdf76…, 9 layers, 16:04:30Z)
  # and localhost/rustwebapp-builder:0.3.0 (config 88371d02…, 8 layers, 17:33:47Z) are DIFFERENT
  # IMAGES at ONE TAG; one is what builder-push ships to Harbor for Tekton, the other is what
  # app-verify certifies. Stamping here is the whole fix: this is the SINGLE chokepoint (15-build-
  # push-builder.sh is a thin orchestrator over this file), base_digest is already resolved above,
  # and the config blob that carries labels is exactly what `save` writes and `crane push` reads --
  # so the air-gap side inherits the provenance for free, no second mechanism to carry it.
  #   inputs = the tree recipe  -> checkable OFFLINE, on a fresh box, which is where the defect lives
  #   base   = the resolved digest -> checkable only where bundle/images.lock exists (gitignored)
  run "$ENGINE" build \
    --build-arg "${builder_arg}=${build_base}" \
    --label "io.vks.builder.inputs=$(builder_inputs_hash "$app")" \
    --label "io.vks.builder.base=${base_digest}" \
    -f "${src}/Dockerfile.builder" \
    -t "$local_ref" \
    "${src}"

  # A DOCKER-STYLE TARBALL, which is what `crane push` reads when PATH is a file (verified against
  # crane 0.21.7: "If the PATH is a directory, it will be read as an OCI image layout. Otherwise, PATH
  # is assumed to be a docker-style tarball."). Both podman and docker `save` produce exactly this — so
  # the air-gap box needs NO CONTAINER ENGINE to push it, only the crane the bundle already carries.
  log_info "[${app}] saving via '${ENGINE} save' -> ${tarball} (carried in the bundle; pushed by 'make builder-push' on the air-gap box)"
  # `rm -f` FIRST: `podman save -o <existing-file>` fails with "docker-archive doesn't support modifying
  # existing images" (it will not overwrite), so a SECOND run dies while the first succeeded — a re-run
  # bug that a single green run cannot show. docker save overwrites, so this is podman-specific and
  # would have shipped on a docker-only test.
  rm -f "$tarball"
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
