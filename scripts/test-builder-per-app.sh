#!/usr/bin/env bash
# ── test-builder-per-app.sh — the builder base/ARG must be resolved PER APP ──────────────────────
#
# WHY THIS EXISTS. Until 2026-08-22, 14-builder-build.sh resolved ONE Maven base ABOVE its loop:
#   MAVEN_SRC="maven:..."; BUILD_BASE="docker.io/library/maven@${DIGEST}"
#   for app in $BUILDER_APPS; do ... --build-arg "MAVEN_IMAGE=${BUILD_BASE}"
# The SELECTION was already generic -- app_has_builder() is a file-existence test, so ANY app that
# ships a Dockerfile.builder enrols automatically -- but the BODY was Maven-only. A node builder
# would therefore have been handed `MAVEN_IMAGE=<maven digest>`, an ARG its Dockerfile never
# declares, and MEASURED: podman answers `[Warning] one or more build args were not consumed` and
# EXITS 0. The build then uses the ARG's own default: an UNPINNED base in an air-gap build.
#
# THE POINT OF THIS TEST. The repo has exactly ONE builder app today (javawebapp), so the fix's
# whole purpose -- that two apps get DIFFERENT bases and DIFFERENT ARG names -- cannot be exercised
# by the real tree. N=1 proves nothing about N>1. This synthesises a second language so the
# per-app-ness is actually measured rather than assumed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh" >/dev/null 2>&1
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"

p=0; f=0
ok(){ p=$((p+1)); printf '  ok    %s\n' "$1"; }
bad(){ f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; }
ck(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# --- the REAL app, so a refactor cannot silently change it -------------------------------------
_first="$(app_names | head -1)"   # DERIVED: check-app-hardcodes forbids naming an app in a shared file
ck "the first registry app resolves a base" "$(app_builder_base "$_first" | grep -c .)" "1"
ck "its path is fully qualified"            "$(app_builder_base_path "$_first" | grep -cE "^[a-z0-9.]+\\.[a-z]+/|^docker\\.io/")" "1"
ck "its build-arg name is upper-snake"      "$(app_builder_arg "$_first" | grep -cE "^[A-Z][A-Z0-9_]*$")" "1"

# --- TWO apps, TWO languages: the case the real tree cannot exercise ---------------------------
# Override app_lang so a synthetic second app resolves as a different language, then require the
# two to differ in BOTH the base and the ARG name. If either is shared, the pre-2026-08-22 bug is
# back: one app would build on the other's base, or receive an ARG it does not declare.
_two() {
  app_lang(){ case "$1" in fakenode) printf 'nodejs' ;; *) printf 'java' ;; esac; }
  app_builder_base(){ case "$(app_lang "$1")" in java) printf 'maven:3.9-eclipse-temurin-25' ;; nodejs) printf 'node:24-alpine' ;; esac; }
  app_builder_arg(){  case "$(app_lang "$1")" in java) printf 'MAVEN_IMAGE' ;; nodejs) printf 'NODE_IMAGE' ;; esac; }
  printf '%s|%s|%s|%s|%s|%s' \
    "$(app_builder_base "$_first")" "$(app_builder_arg "$_first")" "$(app_builder_base_path "$_first")" \
    "$(app_builder_base fakenode)"   "$(app_builder_arg fakenode)"   "$(app_builder_base_path fakenode)"
}
_first="$(app_names | head -1)"
IFS='|' read -r jb ja jp nb na np <<< "$(_two)"
[ "$jb" != "$nb" ] && ok "two languages get DIFFERENT bases ($jb vs $nb)" || bad "both languages share a base" "$jb" "they must differ"
[ "$ja" != "$na" ] && ok "two languages get DIFFERENT build-arg names ($ja vs $na)" || bad "both languages share an ARG name" "$ja" "they must differ"
ck "the nodejs path derives correctly" "$np" "docker.io/library/node"
ck "the java path is untouched by the second app" "$jp" "docker.io/library/maven"

# --- a NON-DockerHub key must derive its own registry path (dotnet lands on mcr.microsoft.com) --
_mcr(){ app_builder_base(){ printf 'mcr.microsoft.com/dotnet/sdk:10.0-alpine'; }; app_builder_base_path x; }
ck "a non-DockerHub key keeps its own registry" "$(_mcr)" "mcr.microsoft.com/dotnet/sdk"

# --- an unhandled language must DIE, and NAME the function to edit ------------------------------
# 'cobol' rather than a real language: this fixture must name something we will NEVER add, or it
# silently stops testing the die. It was 'rust' until 2026-08-22, when rust became a real language
# and this case started passing for the wrong reason -- MEASURED as a FAIL by an adversary round.
out="$( app_lang(){ printf 'cobol'; }; app_builder_base fake 2>&1 )"
case "$out" in *app_builder_base*) ok "an unhandled lang dies naming app_builder_base()" ;;
                *) bad "an unhandled lang must name the function to edit" "$out" "mentions app_builder_base" ;; esac

# --- THE GUARD: 14-builder-build.sh must verify the Dockerfile DECLARES the arg -----------------
# Without it a wrong ARG name is a WARNING and exit 0 -- a silently unpinned base.
grep -qE 'grep -qE .*ARG.*builder_arg' "${SCRIPT_DIR}/14-builder-build.sh" \
  && ok "14-builder-build.sh asserts the Dockerfile declares the ARG" \
  || bad "the ARG-declaration guard is gone" "absent" "present"

# --- and the resolution must be INSIDE the loop, not above it ----------------------------------
_loop="$(awk '/^for app in \$BUILDER_APPS/,0' "${SCRIPT_DIR}/14-builder-build.sh")"
case "$_loop" in *'app_builder_base "$app"'*) ok "the base is resolved INSIDE the per-app loop" ;;
                 *) bad "the base is resolved outside the loop again" "absent from loop body" "present" ;; esac

# ── THE COLLISION INVARIANT (B1) ────────────────────────────────────────────────────────────────
# An app's builder is PUSHED to app_builder_image (22-builder-push.sh:87). If that ref ever equals
# a ref the MIRROR owns, `make builder-push` OVERWRITES a mirrored upstream image in Harbor with a
# locally-built derivative. MEASURED 2026-08-22, before the fix:
#     gowebapp push-ref: harbor/cicd/golang:1.27.0-bookworm   == the mirrored upstream, exactly
# Nothing failed: 23-mirror-verify.sh downgrades a digest mismatch to a WARN whose text blames
# "likely OCI-layout rewrap", and install-all verifies BEFORE the push. So the ONLY thing standing
# between that bug and a corrupted mirror is this assertion.
if command -v mirror_target_ref >/dev/null 2>&1; then
  : "${HARBOR_URL:=harbor.invalid}" "${HARBOR_INFRA_PROJECT:=cicd}" "${BUILDER_IMAGE_TAG:=0.0.0}"
  export HARBOR_URL HARBOR_INFRA_PROJECT BUILDER_IMAGE_TAG
  _mirrored="$(mktemp)"; trap 'rm -f "$_mirrored"' EXIT
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${SCRIPT_DIR}/../images/images.txt" \
    | while read -r _img; do mirror_target_ref "$_img" 2>/dev/null && printf '\n' || true; done > "$_mirrored"
  # RECONCILE THE DENOMINATOR, do not just print it. mirror_target_ref uses printf with NO trailing
  # newline, so a naive `... | while read; do mirror_target_ref; done` concatenates every ref onto ONE
  # line -- and `grep -qxF` (whole-line) then matches NOTHING. MEASURED: this check reported
  # "1 mirrored refs checked" against 16 images and was VACUOUS. The counts must agree.
  _want="$(grep -cvE '^[[:space:]]*#|^[[:space:]]*$' "${SCRIPT_DIR}/../images/images.txt")"
  _got="$(grep -c . "$_mirrored")"
  ck "every images.txt entry yields a mirrored ref (a short count means the collision check is vacuous)" "$_got" "$_want"
  _coll=0
  while read -r _a; do
    [ -n "$_a" ] || continue
    app_has_builder "$_a" || continue
    _r="$(app_builder_image "$_a" 2>/dev/null || true)"
    if [ -n "$_r" ] && grep -qxF "$_r" "$_mirrored"; then
      _coll=$((_coll + 1)); bad "app '$_a' builder ref COLLIDES with a mirrored image" "$_r" "a ref the mirror does not own"
    fi
  done <<EOF
$(app_names)
EOF
  [ "$_coll" -eq 0 ] && ok "no app's builder ref collides with any mirrored image ($(grep -c . "$_mirrored") mirrored refs checked)"
else
  bad "lib/mirror.sh not sourced" "absent" "sourced — the collision check cannot run without it"
fi

printf '\n  %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
