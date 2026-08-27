#!/usr/bin/env bash
# selfbuilt.sh — read images/selfbuilt.tsv, the inventory of images we BUILD rather than mirror.
#
# Deliberately tiny and NOT app-keyed. See images/selfbuilt.tsv's header for why an infra image must
# not go through apps/registry.tsv.
#
# Sourced by 16-selfbuilt-build.sh (internet box) and 26-selfbuilt-push.sh (air-gap box).

selfbuilt_file() { printf '%s' "${REPO_ROOT}/images/selfbuilt.tsv"; }

# Emit non-comment, non-blank rows verbatim (TAB-separated).
selfbuilt_rows() {
  local f; f="$(selfbuilt_file)"
  [ -f "$f" ] || return 0
  # `grep -v` exits 1 when EVERY line is filtered out, which under `set -e` in a caller would abort
  # a legitimately-empty inventory. `|| true` keeps an empty file an empty list, not a failure.
  grep -vE '^[[:space:]]*(#|$)' "$f" || true
}

selfbuilt_names() { selfbuilt_rows | cut -f1; }

# selfbuilt_field <name> <1-based column>
selfbuilt_field() {
  local want="$1" col="$2"
  selfbuilt_rows | awk -F'\t' -v w="$want" -v c="$col" '$1==w {print $c; exit}'
}

selfbuilt_git_url()   { selfbuilt_field "$1" 2; }
selfbuilt_git_ref()   { selfbuilt_field "$1" 3; }
selfbuilt_dockerfile(){ selfbuilt_field "$1" 4; }
selfbuilt_target()    { selfbuilt_field "$1" 5; }
selfbuilt_repo_path() { selfbuilt_field "$1" 6; }
selfbuilt_tag()       { selfbuilt_field "$1" 7; }
selfbuilt_go_get()    { selfbuilt_field "$1" 8; }   # OPTIONAL — see the TSV header

# The FULL Harbor reference a consuming manifest asks for. Single-sourced here so the build side,
# the push side and check-image-alignment cannot disagree about it.
selfbuilt_harbor_ref() {
  local n="$1"
  printf '%s/%s/%s:%s' "${HARBOR_URL:?HARBOR_URL must be set}" \
    "${HARBOR_INFRA_PROJECT:?HARBOR_INFRA_PROJECT must be set}" \
    "$(selfbuilt_repo_path "$n")" "$(selfbuilt_tag "$n")"
}

# A row is only usable if EVERY column is present — a short row would otherwise produce an empty
# tag and push `repo:` , which Harbor accepts as `latest`. Fail loudly instead.
selfbuilt_validate() {
  local n rc=0
  for n in $(selfbuilt_names); do
    local c
    for c in 2 3 4 6 7; do   # 5 (target) may legitimately be empty
      [ -n "$(selfbuilt_field "$n" "$c")" ] || { echo "selfbuilt: row '$n' has an empty column $c" >&2; rc=1; }
    done
    case "$(selfbuilt_git_ref "$n")" in
      main|master|HEAD|'') echo "selfbuilt: row '$n' pins a BRANCH ('$(selfbuilt_git_ref "$n")'), not an immutable tag — the bundle would not be reproducible" >&2; rc=1 ;;
    esac
  done
  return $rc
}
