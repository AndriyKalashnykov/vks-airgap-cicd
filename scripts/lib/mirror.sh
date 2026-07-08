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

# mirror_pull_ref SRC -> a skopeo-valid docker source. skopeo rejects refs with
# BOTH a tag and a digest, so prefer the digest (exact content) when present.
mirror_pull_ref() {
  local name tag digest
  IFS='|' read -r name tag digest <<<"$(_mirror_parse "$1")"
  if   [ -n "$digest" ]; then printf '%s@%s' "$name" "$digest"
  elif [ -n "$tag" ];    then printf '%s:%s' "$name" "$tag"
  else                         printf '%s:latest' "$name"; fi
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

# mirror_cache_dir SRC -> local OCI-dir path holding the pulled image.
mirror_cache_dir() {
  local src="$1" safe
  safe="$(printf '%s' "$src" | tr '/:@' '___')"
  printf '%s/%s' "${IMAGE_CACHE_DIR:?}" "$safe"
}

# mirror_collect_images -> prints the deduplicated list of source images:
#   (a) every non-comment line in images/images.txt, plus
#   (b) every `image:` ref found in $BUNDLE_DIR/manifests/*.yaml (Tekton/Triggers
#       release manifests downloaded by 10-mirror-pull.sh).
mirror_collect_images() {
  local list="${REPO_ROOT}/images/images.txt" mdir="${BUNDLE_DIR:?}/manifests"
  {
    [ -f "$list" ] && grep -vE '^\s*(#|$)' "$list"
    if [ -d "$mdir" ]; then
      grep -rhoE '^\s*image:\s*"?[^"'"'"' ]+"?' "$mdir" 2>/dev/null \
        | sed -E 's/^\s*image:\s*//; s/^"//; s/"$//' \
        | grep -vE '^\s*$'
    fi
  } | sort -u
}
