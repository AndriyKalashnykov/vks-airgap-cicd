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
  # `|| true`: `head -1` closes the pipe → `grep` SIGPIPEs (141), and a repo absent from
  # images.txt makes `grep` exit 1; either non-zero would abort this `set -e` script mid-loop
  # and skip the `[ -z "$itag" ]` WARN guard below. The captured value is already correct.
  itag="$(grep -oE "${repo}:[^[:space:]\"]+" images/images.txt | head -1 | sed "s|${repo}:||" || true)"
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
# (TEMURIN_JRE_TAG, which feeds the rendered RUNTIME_IMAGE_REF in configure-tekton)
# and in the app runtime Dockerfile ARG. A grep over manifest literals cannot see
# those, so check them explicitly against images.txt. (Only the JRE runtime image
# is mirrored — the build uses the maven:...-temurin image.)
# `|| true`: this is the function body, consumed by `jre_itag="$(temurin_itag jre)"` (a `set -e`
# assignment) — a `head -1` SIGPIPE or no-match would otherwise abort the whole script there.
temurin_itag() { grep -oE "eclipse-temurin:[^[:space:]\"]*-$1-jammy" images/images.txt | head -1 | sed 's|eclipse-temurin:||' || true; }
check_pinned() { # <label> <actual> <expected-from-images.txt>
  [ -n "$3" ] || return 0
  if [ "$2" != "$3" ]; then
    echo "DRIFT ${1}: ${2:-<absent>} vs images/images.txt=${3}"
    drift=1
  else
    echo "ok    ${1}=${2}"
  fi
}
jre_itag="$(temurin_itag jre)"
check_pinned "TEMURIN_JRE_TAG (.env.example)" "$(grep -E '^TEMURIN_JRE_TAG=' .env.example | cut -d= -f2)" "$jre_itag"
check_pinned "RUNTIME_IMAGE (apps/java/webui/Dockerfile)" "$(grep -oE 'RUNTIME_IMAGE=eclipse-temurin:[^[:space:]"]+' apps/java/webui/Dockerfile | head -1 | sed 's|RUNTIME_IMAGE=eclipse-temurin:||')" "$jre_itag"

# Istio's version is carried in .env.example (ISTIO_VERSION, which feeds the helm
# global.tag in 46-install-istio.sh) and mirrored as istio/pilot + istio/proxyv2
# in images.txt. Keep them aligned (both istio images share the one version).
# `|| true`: standalone `set -e` assignments — a `head -1` SIGPIPE (or istio absent from
# images.txt) would abort the script before the aligning `check_pinned` calls below run.
istio_itag="$(grep -oE 'istio/pilot:[^[:space:]"]+' images/images.txt | head -1 | sed 's|istio/pilot:||' || true)"
proxyv2_itag="$(grep -oE 'istio/proxyv2:[^[:space:]"]+' images/images.txt | head -1 | sed 's|istio/proxyv2:||' || true)"
check_pinned "ISTIO_VERSION (.env.example)" "$(grep -E '^ISTIO_VERSION=' .env.example | cut -d= -f2)" "$istio_itag"
check_pinned "istio/proxyv2 (images.txt)" "$proxyv2_itag" "$istio_itag"

# The Maven BUILD image (maven:<mvn>-eclipse-temurin-<jdk>) is mirrored in images.txt and its
# FULL tag is re-typed in four consumers the manifest grep above cannot see: the two app
# Dockerfile ARGs and 15-build-push-builder.sh's upstream-pull + Harbor-ref lines. Renovate tracks
# it (depName=maven) via images.txt only, and check-java-alignment aligns just the JDK MAJOR — so a
# maven `3.9 -> 3.10` bump would drift the consumers silently. Assert the full tag across all four.
# `|| true`: standalone `set -e` assignments — a head-1 SIGPIPE / no-match must not abort here.
mvn_itag="$(grep -oE '^maven:[^[:space:]"]+' images/images.txt | head -1 | sed 's|maven:||' || true)"
check_pinned "MAVEN_IMAGE (apps/java/webui/Dockerfile.builder)" \
  "$(grep -oE 'MAVEN_IMAGE=maven:[^[:space:]"]+' apps/java/webui/Dockerfile.builder | head -1 | sed 's|MAVEN_IMAGE=maven:||' || true)" "$mvn_itag"
check_pinned "BUILDER_IMAGE (apps/java/webui/Dockerfile)" \
  "$(grep -oE 'BUILDER_IMAGE=maven:[^[:space:]"]+' apps/java/webui/Dockerfile | head -1 | sed 's|BUILDER_IMAGE=maven:||' || true)" "$mvn_itag"
check_pinned "BUILD_BASE (15-build-push-builder.sh)" \
  "$(grep -E '^BUILD_BASE=' scripts/15-build-push-builder.sh | grep -oE 'maven:[^[:space:]"]+' | head -1 | sed 's|maven:||' || true)" "$mvn_itag"
check_pinned "MAVEN_BASE (15-build-push-builder.sh)" \
  "$(grep -E '^MAVEN_BASE=' scripts/15-build-push-builder.sh | grep -oE 'maven:[^[:space:]"]+' | head -1 | sed 's|maven:||' || true)" "$mvn_itag"

if [ "$drift" -ne 0 ]; then
  echo "ERROR: image tag drift between manifests and images/images.txt (BLOCKING)." >&2
  echo "       The mirror pushes the images.txt tag; each manifest pulls its own tag." >&2
  echo "       Align the manifest tag(s) above with images/images.txt." >&2
  exit 1
fi
echo "check-image-alignment: all mirrored image tags aligned with images/images.txt"
