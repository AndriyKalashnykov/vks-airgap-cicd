#!/usr/bin/env bash
# check-java-alignment.sh — fail if the Java MAJOR version drifts across the
# toolchain. The app's Java major is pinned in several places that MUST agree:
#   1. apps/java/webui/pom.xml <java.version>                       (bytecode target — authoritative)
#   2. .mise.toml java = "temurin-N"                     (jump-box / local build JDK)
#   3. .github/workflows/ci.yml java-version             (CI build JDK)
#   4. apps/java/webui/Dockerfile BUILDER_IMAGE maven:...-temurin-N  (in-cluster build JDK)
#   5. apps/java/webui/Dockerfile RUNTIME_IMAGE eclipse-temurin:N... (app runtime JRE)
#   6. images/images.txt maven:...-temurin-N             (mirrored build image)
#   7. images/images.txt eclipse-temurin:N...            (mirrored runtime image)
#
# Why this gate exists: Renovate tracks the maven build image (depName=maven) and
# the eclipse-temurin runtime image (depName=eclipse-temurin) as SEPARATE deps, so
# it can bump one Java major without the other — recreating a build-vs-runtime
# split (the app once compiled for Java 21 but ran on a Java 25 image). Nothing
# couples pom/mise/ci either. This gate makes any such drift a RED CI failure.
# pom.xml is the source of truth; every other reference must match its major.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

# `|| true` on every extraction below: these are standalone `set -e` assignments in a pipefail
# script, so a `head -1` SIGPIPE (141) or a missing pattern (grep exit 1) would abort the script
# right here — killing the `[ -n "$pom" ]` guard and the DRIFT-on-<none> reporting the `check()`
# calls do. The captured value is already correct; only the spurious non-zero is neutralised.
pom="$(grep -oE '<java\.version>[0-9]+' apps/java/webui/pom.xml | grep -oE '[0-9]+' | head -1 || true)"
[ -n "$pom" ] || { echo "ERROR: could not read <java.version> from apps/java/webui/pom.xml" >&2; exit 1; }

drift=0
check() { # <label> <actual-major> — compare to $pom
  if [ "$2" != "$pom" ]; then
    echo "DRIFT ${1}: Java ${2:-<none>} vs apps/java/webui/pom.xml=${pom}"
    drift=1
  else
    echo "ok    ${1}=Java ${2}"
  fi
}

mise="$(grep -oE '^java[[:space:]]*=[[:space:]]*"temurin-[0-9]+' .mise.toml | grep -oE '[0-9]+$' || true)"
ci="$(grep -oE "java-version:[[:space:]]*'[0-9]+" .github/workflows/ci.yml | grep -oE '[0-9]+' | head -1 || true)"
df_build="$(grep -oE 'BUILDER_IMAGE=maven:[0-9.]+-eclipse-temurin-[0-9]+' apps/java/webui/Dockerfile | grep -oE '[0-9]+$' | head -1 || true)"
df_run="$(grep -oE 'RUNTIME_IMAGE=eclipse-temurin:[0-9]+' apps/java/webui/Dockerfile | grep -oE '[0-9]+$' | head -1 || true)"
img_mvn="$(grep -oE 'maven:[0-9.]+-eclipse-temurin-[0-9]+' images/images.txt | grep -oE '[0-9]+$' | head -1 || true)"
img_jre="$(grep -oE 'eclipse-temurin:[0-9]+' images/images.txt | grep -oE '[0-9]+$' | head -1 || true)"

check ".mise.toml (temurin)"                 "$mise"
check ".github/workflows/ci.yml"             "$ci"
check "apps/java/webui/Dockerfile BUILDER_IMAGE (maven)" "$df_build"
check "apps/java/webui/Dockerfile RUNTIME_IMAGE"         "$df_run"
check "images.txt maven build image"         "$img_mvn"
check "images.txt eclipse-temurin runtime"   "$img_jre"

if [ "$drift" -ne 0 ]; then
  echo "ERROR: Java major version drift across the toolchain (BLOCKING)." >&2
  echo "       pom / mise / ci / Dockerfile / images.txt must all pin the same Java major." >&2
  echo "       Renovate can bump the maven and eclipse-temurin images independently — align them." >&2
  exit 1
fi
echo "check-java-alignment: all Java references pin Java ${pom}"
