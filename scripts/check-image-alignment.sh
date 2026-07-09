#!/usr/bin/env bash
# check-image-alignment.sh — fail if any mirrored image referenced in a k8s/ or
# tekton/ manifest (as ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<repo>:<tag>) has a
# tag that differs from images/images.txt (the mirror's source of truth).
#
# Why this gate exists: image versions are duplicated between images/images.txt
# (Renovate-tracked) and the rendered manifests. When Renovate bumps images.txt
# but a manifest still pins the old tag, the mirror pushes only the images.txt
# tag, so the workload pulls a tag Harbor does not have -> ImagePullBackOff. This
# gate makes that drift a RED CI failure instead of a runtime surprise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

drift=0
while read -r ref; do
  [ -n "$ref" ] || continue
  repo="${ref%:*}"
  mtag="${ref##*:}"
  itag="$(grep -oE "${repo}:[^[:space:]\"]+" images/images.txt | head -1 | sed "s|${repo}:||")"
  if [ -z "$itag" ]; then
    echo "WARN  ${repo}: referenced in a manifest but absent from images/images.txt (not mirrored?)"
    continue
  fi
  if [ "$mtag" != "$itag" ]; then
    echo "DRIFT ${repo}: manifest=${mtag} vs images/images.txt=${itag}"
    drift=1
  else
    echo "ok    ${repo}=${mtag}"
  fi
done < <(grep -rhoE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"]+:[^[:space:]"]+' k8s/ tekton/ 2>/dev/null \
          | sed -E 's|\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/||' | sort -u)

if [ "$drift" -ne 0 ]; then
  echo "ERROR: image tag drift between manifests and images/images.txt (BLOCKING)." >&2
  echo "       The mirror pushes the images.txt tag; each manifest pulls its own tag." >&2
  echo "       Align the manifest tag(s) above with images/images.txt." >&2
  exit 1
fi
echo "check-image-alignment: all mirrored image tags aligned with images/images.txt"
