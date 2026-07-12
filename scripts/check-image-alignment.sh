#!/usr/bin/env bash
# check-image-alignment.sh — fail if any mirrored image referenced in a k8s/ or
# manifest under k8s/ (as ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<repo>:<tag>) has a
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
done < <(grep -rhoE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"]+:[^[:space:]"]+' k8s/ 2>/dev/null \
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

# --- EVERY app's Dockerfile base images, DERIVED from the app registry ------------------------
# NOT one hardcoded block per language. For each app in apps/registry.tsv we read ITS Dockerfile's
# base-image ARGs and assert each ref appears VERBATIM in images/images.txt. Adding an app (or a
# language) needs ZERO edits here — the gate follows the registry.
#
# Why it matters: if images.txt is bumped (Renovate) and an app's Dockerfile ARG is not, the mirror
# pushes the NEW ref while the build asks Harbor for one it never received — Kaniko fails with
# MANIFEST_UNKNOWN at PIPELINE time, never at build time. Digest-pinned refs (`tag@sha256:...`) are
# compared whole, so a digest bump that misses a Dockerfile is caught too.
# lib/apps.sh needs REPO_ROOT (this script calls its root $ROOT) and os.sh's die().
REPO_ROOT="$ROOT"; export REPO_ROOT
# shellcheck source=scripts/lib/os.sh
. "${ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${ROOT}/scripts/lib/apps.sh"

while read -r app; do
  [ -n "$app" ] || continue
  df="${ROOT}/$(app_src "$app")/Dockerfile"
  [ -f "$df" ] || { echo "DRIFT ${app}: no Dockerfile at ${df#"$ROOT"/}"; drift=1; continue; }
  for arg in BUILDER_IMAGE RUNTIME_IMAGE; do
    ref="$(grep -oE "^ARG ${arg}=[^[:space:]\"]+" "$df" | head -1 | sed "s|^ARG ${arg}=||" || true)"
    [ -n "$ref" ] || continue          # an app need not define both (a single-stage build)
    if grep -qxF "$ref" images/images.txt; then
      echo "ok    ${arg} (${app})=${ref}"
    else
      echo "DRIFT ${arg} (${app}): ${ref} is NOT in images/images.txt (so it is never mirrored)"
      drift=1
    fi
  done
done <<EOF
$(app_names)
EOF

# Istio's version is carried in .env.example (ISTIO_VERSION, which feeds the helm
# global.tag in 46-install-istio.sh) and mirrored as istio/pilot + istio/proxyv2
# in images.txt. Keep them aligned (both istio images share the one version).
# `|| true`: standalone `set -e` assignments — a `head -1` SIGPIPE (or istio absent from
# images.txt) would abort the script before the aligning `check_pinned` calls below run.
istio_itag="$(grep -oE 'istio/pilot:[^[:space:]"]+' images/images.txt | head -1 | sed 's|istio/pilot:||' || true)"
proxyv2_itag="$(grep -oE 'istio/proxyv2:[^[:space:]"]+' images/images.txt | head -1 | sed 's|istio/proxyv2:||' || true)"
check_pinned "ISTIO_VERSION (.env.example)" "$(grep -E '^ISTIO_VERSION=' .env.example | cut -d= -f2)" "$istio_itag"
check_pinned "istio/proxyv2 (images.txt)" "$proxyv2_itag" "$istio_itag"

# The following are NOT registry-derived on purpose: they guard the Java OFFLINE-BUILDER apparatus
# (Dockerfile.builder + 15-build-push-builder.sh), which exists only because an in-cluster `mvn`
# cannot reach Maven Central. No other language has one (gowebapp is stdlib-only, so it needs no
# pre-baked dependency cache). If a second language ever needs a builder image, derive these too.
#
# The Maven BUILD image (maven:<mvn>-eclipse-temurin-<jdk>) is mirrored in images.txt and its
# FULL tag is re-typed in four consumers the manifest grep above cannot see: the two app
# Dockerfile ARGs and 15-build-push-builder.sh's upstream-pull + Harbor-ref lines. Renovate tracks
# it (depName=maven) via images.txt only, and check-java-alignment aligns just the JDK MAJOR — so a
# maven `3.9 -> 3.10` bump would drift the consumers silently. Assert the full tag across all four.
# `|| true`: standalone `set -e` assignments — a head-1 SIGPIPE / no-match must not abort here.
mvn_itag="$(grep -oE '^maven:[^[:space:]"]+' images/images.txt | head -1 | sed 's|maven:||' || true)"
check_pinned "MAVEN_IMAGE (apps/java/javawebapp/Dockerfile.builder)" \
  "$(grep -oE 'MAVEN_IMAGE=maven:[^[:space:]"]+' apps/java/javawebapp/Dockerfile.builder | head -1 | sed 's|MAVEN_IMAGE=maven:||' || true)" "$mvn_itag"
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
