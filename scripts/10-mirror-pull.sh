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

require_cmd skopeo
require_cmd curl

: "${BUNDLE_DIR:?}"; : "${IMAGE_CACHE_DIR:?}"
MANIFEST_DIR="${BUNDLE_DIR}/manifests"
mkdir -p "$MANIFEST_DIR" "$IMAGE_CACHE_DIR"

# ---- 1. Download the Tekton install manifests (also feed the image list) ----
tk_pipe="${TEKTON_PIPELINES_VERSION:?}"
tk_trig="${TEKTON_TRIGGERS_VERSION:?}"
declare -A MANIFESTS=(
  ["tekton-pipelines-${tk_pipe}.yaml"]="https://storage.googleapis.com/tekton-releases/pipeline/previous/${tk_pipe}/release.yaml"
  ["tekton-triggers-${tk_trig}.yaml"]="https://storage.googleapis.com/tekton-releases/triggers/previous/${tk_trig}/release.yaml"
  ["tekton-triggers-interceptors-${tk_trig}.yaml"]="https://storage.googleapis.com/tekton-releases/triggers/previous/${tk_trig}/interceptors.yaml"
)
for f in "${!MANIFESTS[@]}"; do
  log_info "downloading manifest $f"
  run curl -fsSL "${MANIFESTS[$f]}" -o "${MANIFEST_DIR}/${f}"
done

# ---- 2. Collect the full image list ----
mapfile -t IMAGES < <(mirror_collect_images)
[ "${#IMAGES[@]}" -gt 0 ] || die "no images collected (empty images.txt and no manifest images)"
log_info "collected ${#IMAGES[@]} images to pull"

# ---- 3. Pull each image into the local OCI cache ----
fails=0
for src in "${IMAGES[@]}"; do
  dst_dir="$(mirror_cache_dir "$src")"
  pull_ref="$(mirror_pull_ref "$src")"      # digest-valid (never tag+digest)
  log_info "pull $pull_ref"
  mkdir -p "$dst_dir"
  # --all preserves multi-arch manifest lists; --preserve-digests keeps identity.
  if run skopeo copy --all --preserve-digests --retry-times 3 \
        "docker://${pull_ref}" "dir:${dst_dir}"; then
    :
  else
    log_error "failed to pull $src"; fails=$((fails+1))
  fi
done

# ---- 4. Summary ----
if [ "$fails" -gt 0 ]; then
  die "$fails/${#IMAGES[@]} images failed to pull"
fi
log_info "pulled ${#IMAGES[@]} images into $IMAGE_CACHE_DIR"
log_info "next: dual-homed -> 'make mirror-push'  |  sneakernet -> 'make bundle'"
