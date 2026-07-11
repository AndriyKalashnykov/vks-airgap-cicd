#!/usr/bin/env bash
# scripts/lib/mirror.sh — shared image-mirroring helpers used by both the pull
# (10) and push (21) scripts, so the image list and source→Harbor mapping are
# computed identically on both sides. Source after lib/os.sh + load_env.
#
# shellcheck shell=bash
[ -n "${__VKS_MIRROR_SH_LOADED:-}" ] && return 0
__VKS_MIRROR_SH_LOADED=1

# _mirror_parse SRC -> prints "NAME<TAB>TAG<TAB>DIGEST".
# NAME is the full repo path incl. any registry host, WITHOUT tag/digest.
# Handles all four shapes: repo, repo:tag, repo@digest, and repo:tag@digest
# (the last is how Tekton release manifests pin images).
_mirror_parse() {
  local ref="$1" name tag="" digest=""
  case "$ref" in *@*) digest="${ref##*@}"; ref="${ref%@*}";; esac
  # A colon in the LAST path segment is a tag (not a registry :port).
  case "${ref##*/}" in *:*) tag="${ref##*:}"; ref="${ref%:*}";; esac
  name="$ref"
  printf '%s|%s|%s' "$name" "$tag" "$digest"
}

# _mirror_repo_path NAME -> repo path WITHOUT the registry host.
# docker.io short names (alpine/git, gitea/gitea) keep their path; a leading
# registry host (contains '.' or ':' or is 'localhost') is stripped.
_mirror_repo_path() {
  local name="$1" first
  first="${name%%/*}"
  if [[ "$name" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [[ "$first" == localhost ]]; }; then
    printf '%s' "${name#*/}"          # strip the host segment
  else
    printf '%s' "$name"               # docker.io short name — keep as-is
  fi
}

# mirror_pull_ref SRC -> a crane-valid image source. Prefer the digest (exact content)
# when present (crane pulls `name@digest`); otherwise the tag, else `:latest`.
mirror_pull_ref() {
  local name tag digest
  IFS='|' read -r name tag digest <<<"$(_mirror_parse "$1")"
  if   [ -n "$digest" ]; then printf '%s@%s' "$name" "$digest"
  elif [ -n "$tag" ];    then printf '%s:%s' "$name" "$tag"
  else                         printf '%s:latest' "$name"; fi
}

# mirror_src_digest SRC -> the pinned @sha256 digest of SRC, or empty if SRC is
# tag-based. Digest-pinned refs are content-addressable + immutable, so a cached
# copy at that exact digest is safe to reuse (cache-skip); tag-based refs can move,
# so they are always re-pulled.
mirror_src_digest() {
  local digest
  IFS='|' read -r _ _ digest <<<"$(_mirror_parse "$1")"
  printf '%s' "$digest"
}

# mirror_target_ref SRC -> Harbor destination (a TAG ref — you push to a tag, not
# a digest; --preserve-digests keeps the original digest resolvable there).
#   $HARBOR_URL/$HARBOR_INFRA_PROJECT/<repo-path>:<tag>
# A digest-only source (no tag) gets a stable synthesized tag from its digest.
mirror_target_ref() {
  local name tag digest path
  IFS='|' read -r name tag digest <<<"$(_mirror_parse "$1")"
  path="$(_mirror_repo_path "$name")"
  if [ -z "$tag" ]; then tag="sha-${digest#sha256:}"; tag="${tag:0:19}"; fi
  printf '%s/%s/%s:%s' "${HARBOR_URL:?}" "${HARBOR_INFRA_PROJECT:?}" "$path" "$tag"
}

# mirror_platform_arg SRC -> the crane `--platform` selector for this image, as a
# space-separated string the caller reads into an array (empty = all architectures).
#   - DIGEST-pinned refs (Tekton controller images) and MIRROR_ALL_ARCH=1 copy EVERY
#     arch — crane's DEFAULT (no --platform) preserves the whole manifest LIST/index, so
#     the multi-arch digest their manifests reference stays valid. (A single-arch copy
#     would change that digest and break the pull.)
#   - Otherwise select a SINGLE platform (linux/${MIRROR_ARCH:-amd64}) to keep the cache
#     small + mirroring fast.
mirror_platform_arg() {
  local digest
  IFS='|' read -r _ _ digest <<<"$(_mirror_parse "$1")"
  if [ -n "$digest" ] || [ "${MIRROR_ALL_ARCH:-0}" = "1" ]; then
    printf ''                                          # all arches (crane default)
  else
    printf -- '--platform linux/%s' "${MIRROR_ARCH:-amd64}"
  fi
}

# mirror_retry N CMD... -> run CMD, retrying up to N times with linear backoff. crane has
# no built-in retry (skopeo had --retry-times); transient registry 5xx/network errors are
# common on a cold mirror, so wrap the crane calls with this.
mirror_retry() {
  local n="$1"; shift
  local i=1
  while :; do
    if "$@"; then return 0; fi
    [ "$i" -ge "$n" ] && return 1
    log_warn "attempt ${i}/${n} failed: $* — retrying in $((i*2))s"
    sleep $((i*2)); i=$((i+1))
  done
}

# mirror_cache_dir SRC -> local OCI-dir path holding the pulled image.
mirror_cache_dir() {
  local src="$1" safe
  safe="$(printf '%s' "$src" | tr '/:@' '___')"
  printf '%s/%s' "${IMAGE_CACHE_DIR:?}" "$safe"
}

# mirror_collect_images -> prints the deduplicated list of source images:
#   (a) every non-comment line in images/images.txt, plus
#   (b) every fully-qualified registry image ref found ANYWHERE in
#       $BUNDLE_DIR/manifests/*.yaml — not just `image:` keys. Tekton controllers
#       pass several critical images as ARGS/env (the EventListener sink via
#       `-el-image`; the entrypoint/nop/sidecarlogresults/workingdirinit images
#       via controller flags), so an `image:`-only grep silently misses them and
#       they ImagePullBackOff in a real air gap.
mirror_collect_images() {
  local list="${REPO_ROOT}/images/images.txt" mdir="${BUNDLE_DIR:?}/manifests"
  {
    [ -f "$list" ] && grep -vE '^\s*(#|$)' "$list"
    if [ -d "$mdir" ]; then
      # Any host/path[:tag][@digest] on a known registry. The char class excludes
      # quotes/commas/spaces so refs embedded in JSON arg arrays are captured cleanly.
      grep -rhoE '(gcr\.io|ghcr\.io|registry\.k8s\.io|quay\.io|docker\.io)/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?(@sha256:[a-f0-9]+)?' "$mdir" 2>/dev/null \
        | grep -vE 'catalog/upstream|/\*$'    # drop Tekton Hub catalog globs/bundles
    fi
  } | sort -u
}
