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

# eclipse-temurin's tag is ALSO carried outside the manifests: in .env.example
# (TEMURIN_JDK_TAG / TEMURIN_JRE_TAG, which feed the rendered RUNTIME_IMAGE_REF
# in configure-tekton) and in the app runtime Dockerfile ARG. A grep over
# manifest literals cannot see those, so check them explicitly against images.txt.
temurin_itag() { grep -oE "eclipse-temurin:[^[:space:]\"]*-$1-jammy" images/images.txt | head -1 | sed 's|eclipse-temurin:||'; }
check_pinned() { # <label> <actual> <expected-from-images.txt>
  [ -n "$3" ] || return 0
  if [ "$2" != "$3" ]; then
    echo "DRIFT ${1}: ${2:-<absent>} vs images/images.txt eclipse-temurin=${3}"
    drift=1
  else
    echo "ok    ${1}=${2}"
  fi
}
jre_itag="$(temurin_itag jre)"
jdk_itag="$(temurin_itag jdk)"
check_pinned "TEMURIN_JRE_TAG (.env.example)" "$(grep -E '^TEMURIN_JRE_TAG=' .env.example | cut -d= -f2)" "$jre_itag"
check_pinned "TEMURIN_JDK_TAG (.env.example)" "$(grep -E '^TEMURIN_JDK_TAG=' .env.example | cut -d= -f2)" "$jdk_itag"
check_pinned "RUNTIME_IMAGE (app/Dockerfile)" "$(grep -oE 'RUNTIME_IMAGE=eclipse-temurin:[^[:space:]"]+' app/Dockerfile | head -1 | sed 's|RUNTIME_IMAGE=eclipse-temurin:||')" "$jre_itag"

if [ "$drift" -ne 0 ]; then
  echo "ERROR: image tag drift between manifests and images/images.txt (BLOCKING)." >&2
  echo "       The mirror pushes the images.txt tag; each manifest pulls its own tag." >&2
  echo "       Align the manifest tag(s) above with images/images.txt." >&2
  exit 1
fi
echo "check-image-alignment: all mirrored image tags aligned with images/images.txt"
