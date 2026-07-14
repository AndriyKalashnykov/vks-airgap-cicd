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
done < <( { grep -rhoE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"]+:[^[:space:]"]+' k8s/ 2>/dev/null
            # Gitea's ref lives in the SCRIPT's default, not the manifest: the manifest carries
            # ${GITEA_IMAGE} so a Harbor-less test (e2e-cross-cluster) can override it. A gate that
            # only greps k8s/ would have gone BLIND to the gitea tag the moment that changed — the
            # gate must follow its content. (Same treatment as eclipse-temurin below.)
            grep -rhoE '\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/[^:[:space:]"}]+:[^[:space:]"}]+' scripts/40-install-gitea.sh 2>/dev/null
          } | sed -E 's|\$\{HARBOR_URL\}/\$\{HARBOR_INFRA_PROJECT\}/||' | sort -u)

check_pinned() { # <label> <actual> <expected-from-images.txt>
  [ -n "$3" ] || return 0
  if [ "$2" != "$3" ]; then
    echo "DRIFT ${1}: ${2:-<absent>} vs images/images.txt=${3}"
    drift=1
  else
    echo "ok    ${1}=${2}"
  fi
}

# --- .env.example tag vars, DERIVED FROM THEIR CONSUMER (lib/apps.sh) --------------------------
# This used to be ONE HARDCODED LINE (`check_pinned "TEMURIN_JRE_TAG …"`), and that enumerated list
# ROTTED THE MOMENT A SECOND LANGUAGE ARRIVED. The Go app added GOLANG_BUILD_TAG and
# DISTROLESS_STATIC_TAG; neither was ever added here — so when Renovate bumped the distroless DIGEST
# in images.txt + the Dockerfile but NOT in .env.example, this gate went GREEN on a broken tree, the
# PR merged, and the mirror pushed a digest the pipeline never asks for. Kaniko then failed with
# `NOT_FOUND: artifact …@sha256:… not found` at the FAR END of the pipeline, naming the image and not
# the drift. (A gate whose scope is a hand-typed list is the defect — the same lesson the per-app
# Dockerfile loop below already learned.)
#
# So DERIVE the list from the only thing that actually renders these vars into the refs the pipeline
# pulls from Harbor: app_builder_image()/app_runtime_image() in lib/apps.sh. Each branch looks like
#     go)  printf '%s/%s/distroless/static-debian12:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${DISTROLESS_STATIC_TAG:?}"
# giving us (repo=distroless/static-debian12, var=DISTROLESS_STATIC_TAG). A repo containing a `%s`
# (`%s-builder`) is an image WE BUILD, not one we mirror — it has no images.txt row, so it is skipped.
# A new language's var is covered here the day it is written, with zero edits to this gate.
env_pairs="$(sed -n '/^app_builder_image()/,/^}/p;/^app_runtime_image()/,/^}/p' scripts/lib/apps.sh \
  | sed -nE "s|.*printf '%s/%s/([^:']+):%s'.*\\\$\{([A-Z_]+):\?\}.*|\1 \2|p" \
  | grep -v '%s' | sort -u || true)"
[ -n "$env_pairs" ] || { echo "ERROR check-image-alignment: parsed ZERO tag vars out of lib/apps.sh — the gate has gone BLIND (did app_*_image() change shape?)"; exit 1; }

env_checked=0
while read -r repo var; do
  [ -n "$repo" ] || continue
  # The images.txt row for this repo: match the repo as a whole path segment-suffix (images.txt may
  # carry a registry prefix, e.g. gcr.io/distroless/static-debian12), then take everything after the
  # FIRST colon as the tag (which may itself be `tag@sha256:...`).
  row="$(grep -E "(^|/)${repo}:" images/images.txt | grep -v '^[[:space:]]*#' | head -1 || true)"
  if [ -z "$row" ]; then
    echo "WARN  ${var}: '${repo}' is rendered by lib/apps.sh but is absent from images/images.txt (not mirrored?)"
    continue
  fi
  expected="${row#*:}"
  actual="$(grep -E "^${var}=" .env.example | head -1 | cut -d= -f2- || true)"
  check_pinned "${var} (.env.example → ${repo})" "$actual" "$expected"
  env_checked=$((env_checked + 1))
done <<< "$env_pairs"
echo "      (checked ${env_checked} .env.example tag var(s), derived from lib/apps.sh)"

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
# The builder Dockerfile belongs to whichever app SHIPS one (see app_has_builder) — found via the
# registry, never by hardcoding which app is the Java one.
builder_app="$(app_names | while read -r a; do app_has_builder "$a" && { printf '%s' "$a"; break; }; done)"
if [ -n "$builder_app" ]; then
  builder_df="$(app_src "$builder_app")/Dockerfile.builder"
  check_pinned "MAVEN_IMAGE (${builder_df})" \
    "$(grep -oE 'MAVEN_IMAGE=maven:[^[:space:]"]+' "$builder_df" | head -1 | sed 's|MAVEN_IMAGE=maven:||' || true)" "$mvn_itag"
fi
# The builder's base ref lives in 14-builder-build.sh (MAVEN_SRC). It used to be two vars in
# 15-build-push-builder.sh (BUILD_BASE / MAVEN_BASE, both a Harbor ref); the builder was split so the
# INTERNET box can build it without Harbor, and 14 now resolves that ref to a DIGEST via
# bundle/images.lock. The tag must still match images.txt — it is the key the lock is looked up by, so a
# drift here means the lookup finds nothing (or the wrong image) rather than an ImagePullBackOff.
check_pinned "MAVEN_SRC (14-builder-build.sh)" \
  "$(grep -E '^MAVEN_SRC=' scripts/14-builder-build.sh | grep -oE 'maven:[^[:space:]"]+' | head -1 | sed 's|maven:||' || true)" "$mvn_itag"

if [ "$drift" -ne 0 ]; then
  echo "ERROR: image tag drift between manifests and images/images.txt (BLOCKING)." >&2
  echo "       The mirror pushes the images.txt tag; each manifest pulls its own tag." >&2
  echo "       Align the manifest tag(s) above with images/images.txt." >&2
  exit 1
fi
echo "check-image-alignment: all mirrored image tags aligned with images/images.txt"
