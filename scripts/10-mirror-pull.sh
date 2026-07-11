#!/usr/bin/env bash
# 10-mirror-pull.sh — (INTERNET side) download Tekton install manifests and pull
# every required image into a local OCI cache, ready to push to Harbor (21) or
# bundle for sneakernet transfer (11).
#
# Sources: images/images.txt + the Tekton Pipelines/Triggers release manifests
# (their images are digest-pinned upstream, so we derive them rather than hand-list).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
# shellcheck source=scripts/lib/progress.sh
. "${SCRIPT_DIR}/lib/progress.sh"

require_cmd crane
require_cmd curl
require_cmd jq

: "${BUNDLE_DIR:?}"; : "${IMAGE_CACHE_DIR:?}"
MANIFEST_DIR="${BUNDLE_DIR}/manifests"
# images.lock — the resolved source digest of every mirrored image, recorded at
# pull time. Travels with the bundle (sneakernet) and is what 'make mirror-verify'
# checks Harbor against, so re-mirrors are reproducible + verifiable.
LOCK_FILE="${BUNDLE_DIR}/images.lock"
mkdir -p "$MANIFEST_DIR" "$IMAGE_CACHE_DIR"

# ---- 1. Download the Tekton install manifests (also feed the image list) ----
tk_pipe="${TEKTON_PIPELINES_VERSION:?}"
tk_trig="${TEKTON_TRIGGERS_VERSION:?}"
tk_dash="${TEKTON_DASHBOARD_VERSION:?}"
# Tekton publishes its pinned per-version install manifests as GitHub RELEASE
# ASSETS. The legacy GCS `.../previous/<version>/` mirror was abandoned after
# pipeline v1.14.0 / triggers v0.34.0 (newer tags 404 there), and Renovate
# tracks these via datasource=github-releases (see .env.example) — so the
# GitHub release download URL is the single, version-consistent source of truth.
declare -A MANIFESTS=(
  ["tekton-pipelines-${tk_pipe}.yaml"]="https://github.com/tektoncd/pipeline/releases/download/${tk_pipe}/release.yaml"
  ["tekton-triggers-${tk_trig}.yaml"]="https://github.com/tektoncd/triggers/releases/download/${tk_trig}/release.yaml"
  ["tekton-triggers-interceptors-${tk_trig}.yaml"]="https://github.com/tektoncd/triggers/releases/download/${tk_trig}/interceptors.yaml"
  # Dashboard: read-only (release.yaml). Its ghcr.io image is auto-collected from this
  # manifest by mirror_collect_images (same as the pipeline/triggers controllers).
  ["tekton-dashboard-${tk_dash}.yaml"]="https://github.com/tektoncd/dashboard/releases/download/${tk_dash}/release.yaml"
)
for f in "${!MANIFESTS[@]}"; do
  log_info "downloading manifest $f"
  http_get_retry "${MANIFESTS[$f]}" "${MANIFEST_DIR}/${f}"
done

# ---- 2. Collect the full image list ----
mapfile -t IMAGES < <(mirror_collect_images)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images collected (empty images.txt and no manifest images)"
log_info "collected ${#IMAGES[@]} images to pull"

# ---- 3. Pull each image into the local OCI cache ----
# Resilient to transient upstream-CDN failures (e.g. ghcr.io connection resets):
#   * cache-skip — a DIGEST-PINNED image already present at the exact digest (proven
#     by the .mirror-ok sentinel, written only on a COMPLETE pull) is immutable, so
#     reuse it instead of re-hitting the registry. A re-run after a partial failure
#     RESUMES (re-pulls only the misses) rather than restarting all of them.
#     Tag-based refs can move, so they are always re-pulled. MIRROR_FORCE_PULL=1 forces all.
#   * retry — MIRROR_RETRIES (default 5) attempts per image via mirror_retry.
: > "$LOCK_FILE"                              # start a fresh lock for this pull
fails=0; skipped=0
pg_init "${#IMAGES[@]}"
for src in "${IMAGES[@]}"; do
  dst_dir="$(mirror_cache_dir "$src")"
  pull_ref="$(mirror_pull_ref "$src")"      # digest-valid (never tag+digest)
  read -ra platform <<<"$(mirror_platform_arg "$src")"   # single-arch, or empty for all/digest-pinned
  want_dg="$(mirror_src_digest "$src")"     # empty for tag-based (always re-pulled)
  if [ "${MIRROR_FORCE_PULL:-0}" != "1" ] && [ -n "$want_dg" ] \
     && [ -f "$dst_dir/.mirror-ok" ] && [ "$(cat "$dst_dir/.mirror-ok" 2>/dev/null)" = "$want_dg" ]; then
    pg_step "cached $pull_ref (digest match — skip)"
    printf '%s %s\n' "$src" "$want_dg" >> "$LOCK_FILE"
    skipped=$((skipped+1)); continue
  fi
  pg_step "pull $pull_ref ${platform[*]:-(all arches)}"
  # crane writes an OCI image layout; start from a clean dir so a re-pull doesn't append.
  rm -rf "$dst_dir"; mkdir -p "$dst_dir"
  if mirror_retry "${MIRROR_RETRIES:-5}" run crane pull --format=oci "${platform[@]}" "$pull_ref" "$dst_dir"; then
    # Record the resolved source digest (the OCI layout's top-level manifest) so
    # 'make mirror-verify' can confirm Harbor serves the exact same content.
    dg="$(jq -r '.manifests[0].digest // empty' "$dst_dir/index.json" 2>/dev/null)"
    [ -n "$dg" ] && printf '%s %s\n' "$src" "$dg" >> "$LOCK_FILE"
    # Completeness sentinel — written LAST, so an interrupted pull leaves no marker
    # and is re-pulled next run. Only for digest-pinned (immutable) images whose
    # pulled digest matches what was requested.
    [ -n "$want_dg" ] && [ "$dg" = "$want_dg" ] && printf '%s\n' "$dg" > "$dst_dir/.mirror-ok"
  else
    log_error "failed to pull $src"; fails=$((fails+1))
  fi
done

# ---- 4. Summary ----
if [ "$fails" -gt 0 ]; then
  die "$fails/${#IMAGES[@]} images failed to pull"
fi
pg_done "mirror-pull: ${#IMAGES[@]} images into $IMAGE_CACHE_DIR (${skipped} cache-skipped)"
log_info "wrote $LOCK_FILE ($(wc -l < "$LOCK_FILE") digests) — used by 'make mirror-verify'"
log_info "next: dual-homed -> 'make mirror-push'  |  sneakernet -> 'make bundle'"
