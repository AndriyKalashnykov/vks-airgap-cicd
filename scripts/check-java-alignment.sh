#!/usr/bin/env bash
# check-java-alignment.sh — fail if the Java MAJOR version drifts across the
# toolchain. The app's Java major is pinned in several places that MUST agree:
#   1. apps/java/javawebapp/pom.xml <java.version>                       (bytecode target — authoritative)
#   2. .mise.toml java = "temurin-N"                     (jump-box / local / CI build JDK)
#   3. apps/java/javawebapp/Dockerfile BUILDER_IMAGE maven:...-temurin-N  (in-cluster build JDK)
#   4. apps/java/javawebapp/Dockerfile RUNTIME_IMAGE eclipse-temurin:N... (app runtime JRE)
#   5. images/images.txt maven:...-temurin-N             (mirrored build image)
#   6. images/images.txt eclipse-temurin:N...            (mirrored runtime image)
#
# CI is NOT in that list on purpose: it gets its JDK from .mise.toml via mise-action, so it
# has no Java pin of its own. This gate used to reconcile a `java-version:` in ci.yml — a
# duplicate that existed only because of a redundant actions/setup-java step (whose JDK mise
# then overrode anyway). The step is gone; instead of checking that second pin agrees, this
# gate now asserts it does NOT COME BACK.
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
# The Java app(s) come from the registry — this gate must not hardcode which app is Java, or
# adding/renaming one silently stops checking it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; export REPO_ROOT
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"
# TWO different zero states, and until 2026-07-19 they were indistinguishable:
#   "the registry has apps, none of them java"  -> HONEST emptiness, nothing to check, exit 0
#   "the registry yielded ZERO apps"            -> BLINDNESS, the ground truth is gone, must be RED
# So count the apps first, and only then decide.
app_total="$(app_names | grep -c . || true)"
[ "$app_total" -gt 0 ] || die "check-java-alignment: apps/registry.tsv yielded 0 apps — the ground truth is gone and a green here would mean nothing. The gate has gone BLIND."

# `if…fi`, NOT `[ … ] = java && { …; }`: as a loop-body TAIL that `A && B` returns non-zero when the
# LAST app is not java, the `$( )` returns non-zero, the ASSIGNMENT returns non-zero, and
# `set -euo pipefail` kills the script HERE — making the guard on the next line UNREACHABLE DEAD
# CODE, in exactly the case it was written for. Measured: registry emptied -> rc=1 with ZERO bytes
# of output, an error naming nothing. The trigger is not exotic: removing an app is ONE ROW.
JAVA_APP="$(app_names | while read -r a; do if [ "$(app_lang "$a")" = java ]; then printf '%s' "$a"; break; fi; done)"
[ -n "$JAVA_APP" ] || { echo "check-java-alignment: no java app among ${app_total} registry app(s) — nothing to check"; exit 0; }
JAVA_SRC="$(app_src "$JAVA_APP")"
pom="$(grep -oE '<java\.version>[0-9]+' "${JAVA_SRC}/pom.xml" | grep -oE '[0-9]+' | head -1 || true)"
[ -n "$pom" ] || { echo "ERROR: could not read <java.version> from ${JAVA_SRC}/pom.xml" >&2; exit 1; }

drift=0
check() { # <label> <actual-major> — compare to $pom
  if [ "$2" != "$pom" ]; then
    echo "DRIFT ${1}: Java ${2:-<none>} vs ${JAVA_SRC}/pom.xml=${pom}"
    drift=1
  else
    echo "ok    ${1}=Java ${2}"
  fi
}

mise="$(grep -oE '^java[[:space:]]*=[[:space:]]*"temurin-[0-9]+' .mise.toml | grep -oE '[0-9]+$' || true)"
df_build="$(grep -oE 'BUILDER_IMAGE=maven:[0-9.]+-eclipse-temurin-[0-9]+' "${JAVA_SRC}/Dockerfile" | grep -oE '[0-9]+$' | head -1 || true)"
df_run="$(grep -oE 'RUNTIME_IMAGE=eclipse-temurin:[0-9]+' "${JAVA_SRC}/Dockerfile" | grep -oE '[0-9]+$' | head -1 || true)"
img_mvn="$(grep -oE 'maven:[0-9.]+-eclipse-temurin-[0-9]+' images/images.txt | grep -oE '[0-9]+$' | head -1 || true)"
img_jre="$(grep -oE 'eclipse-temurin:[0-9]+' images/images.txt | grep -oE '[0-9]+$' | head -1 || true)"

check ".mise.toml (temurin)"                 "$mise"
check "${JAVA_SRC}/Dockerfile BUILDER_IMAGE (maven)" "$df_build"
check "${JAVA_SRC}/Dockerfile RUNTIME_IMAGE"        "$df_run"
check "images.txt maven build image"         "$img_mvn"
check "images.txt eclipse-temurin runtime"   "$img_jre"

# CI must have NO Java pin of its own: it installs the JDK from .mise.toml via mise-action.
# A `java-version:` (i.e. an actions/setup-java) reappearing here is a second source of truth
# for the Java major — and, since mise-action runs after it and overrides JAVA_HOME, one that
# would silently NOT be the JDK the build actually uses. That is worse than drift: it is a pin
# that lies. `grep -c` (not `grep -q`) because grep -q's early exit SIGPIPEs the upstream under
# `set -o pipefail`.
#
# Comments are stripped FIRST: the workflow's own comment explains why setup-java is absent, and
# a naive grep matches that prose and fails on the very file it certifies (it did, on the first
# run). Documentation may name the thing; the YAML may not.
ci_pin="$(sed -E 's/#.*$//' .github/workflows/ci.yml | grep -cE "java-version:|actions/setup-java" || true)"
if [ "${ci_pin:-0}" -ne 0 ]; then
  echo "DRIFT .github/workflows/ci.yml: it pins Java itself (setup-java / java-version)."
  echo "      CI gets its JDK from .mise.toml via mise-action — remove the pin, do not align it."
  drift=1
else
  echo "ok    .github/workflows/ci.yml pins no JDK (mise-action installs .mise.toml's temurin ${pom})"
fi

if [ "$drift" -ne 0 ]; then
  echo "ERROR: Java major version drift across the toolchain (BLOCKING)." >&2
  echo "       pom / mise / ci / Dockerfile / images.txt must all pin the same Java major." >&2
  echo "       Renovate can bump the maven and eclipse-temurin images independently — align them." >&2
  exit 1
fi
echo "check-java-alignment: all Java references pin Java ${pom}"
