#!/usr/bin/env bash
# scripts/lib/mirror.sh — shared image-mirroring helpers used by both the pull
# (10) and push (21) scripts, so the image list and source→Harbor mapping are
# computed identically on both sides. Source after lib/os.sh + load_env.
#
# shellcheck shell=bash
[ -n "${__VKS_MIRROR_SH_LOADED:-}" ] && return 0
__VKS_MIRROR_SH_LOADED=1

# mirror_split_ref SRC -> prints "name<TAB>tagpart" where tagpart is ":tag" or
# "@sha256:...". name is the full repo path (may include a registry host).
_mirror_split_ref() {
  local ref="$1" name tag
  if [[ "$ref" == *"@"* ]]; then
    name="${ref%@*}"; tag="@${ref#*@}"
  elif [[ "${ref##*/}" == *":"* ]]; then
    # colon in the LAST path segment => it's a tag (not a registry port)
    name="${ref%:*}"; tag=":${ref##*:}"
  else
    name="$ref"; tag=":latest"
  fi
  printf '%s\t%s' "$name" "$tag"
}

# mirror_repo_path SRC -> the repo path WITHOUT the registry host and WITHOUT tag.
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

# mirror_target_ref SRC -> Harbor destination ref:
#   $HARBOR_URL/$HARBOR_INFRA_PROJECT/<repo-path><tag>
mirror_target_ref() {
  local src="$1" name tag path
  IFS=$'\t' read -r name tag <<<"$(_mirror_split_ref "$src")"
  path="$(_mirror_repo_path "$name")"
  printf '%s/%s/%s%s' "${HARBOR_URL:?}" "${HARBOR_INFRA_PROJECT:?}" "$path" "$tag"
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
