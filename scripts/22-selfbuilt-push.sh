#!/usr/bin/env bash
# 22-selfbuilt-push.sh — AIR-GAP BOX. Push the carried self-built images into Harbor.
#
# THIS BOX NEEDS NO CONTAINER ENGINE — exactly as 22-builder-push.sh explains: `crane push` reads a
# docker-style tarball (which is what `podman save`/`docker save` produce), and crane is CARRIED IN
# THE BUNDLE. Sibling of that script; see 14-selfbuilt-build.sh for why this is separate from the
# per-APP builder path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/selfbuilt.sh
. "${SCRIPT_DIR}/lib/selfbuilt.sh"
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
load_env

: "${BUNDLE_DIR:?BUNDLE_DIR must be set (see .env.example)}"
: "${HARBOR_URL:?HARBOR_URL must be set}"
: "${HARBOR_INFRA_PROJECT:?HARBOR_INFRA_PROJECT must be set}"

selfbuilt_validate || die "images/selfbuilt.tsv is not usable — fix the rows above."

NAMES="$(selfbuilt_names | tr '\n' ' ')"
if [ -z "${NAMES// /}" ]; then
  log_info "images/selfbuilt.tsv lists nothing — nothing to push."
  exit 0
fi

IN_DIR="${BUNDLE_DIR}/selfbuilt"
require_cmd crane "crane is carried in the bundle — is BUNDLE_DIR right?"

CRANE_INSECURE=()
[ "${HARBOR_INSECURE:-0}" = "1" ] && CRANE_INSECURE=(--insecure)

# Secret on stdin, never argv.
printf '%s' "${HARBOR_PASSWORD:?HARBOR_PASSWORD must be set}" \
  | run crane auth login "$HARBOR_URL" -u "${HARBOR_USERNAME:?HARBOR_USERNAME must be set}" --password-stdin

pushed=""
for name in $NAMES; do
  tarball="${IN_DIR}/${name}.tar"
  ref="$(selfbuilt_harbor_ref "$name")"
  [ -f "$tarball" ] || die "'${name}' is listed in images/selfbuilt.tsv but the bundle carries no ${tarball}.
  Re-cut the bundle on the internet box: make selfbuilt-build && make bundle"

  log_info "[${name}] pushing the carried image -> ${ref}"
  mirror_retry "${MIRROR_RETRIES:-5}" run crane push "$tarball" "$ref" "${CRANE_INSECURE[@]}"
  pushed="${pushed} ${name}"
done

# VERIFY BY FETCHING, NOT BY THE PUSH'S EXIT CODE.
# A registry that HEAD-200s a blob it cannot serve makes `crane push` a SILENT NO-OP THAT EXITS 0 —
# that happened to this repo's Harbor (36/36 "pushed", 153 manifest links, ZERO blobs). The push's
# status cannot see it; only a fetch can.
for name in $NAMES; do
  ref="$(selfbuilt_harbor_ref "$name")"
  run crane validate --remote "$ref" "${CRANE_INSECURE[@]}"
  log_info "[${name}] verified intact in Harbor: ${ref}"
done

log_info "self-built images pushed + verified:${pushed}"
