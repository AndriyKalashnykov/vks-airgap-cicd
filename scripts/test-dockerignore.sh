#!/usr/bin/env bash
# scripts/test-dockerignore.sh — every app's build context must EXCLUDE its build output.
#
# WHY. Both Dockerfile.builder and Dockerfile do `COPY . .`, and 14-builder-build.sh passes the
# app directory as the context. Without a .dockerignore the builder image absorbs whatever build
# output is lying in the working tree, so the image content depends on what the developer last ran
# and two developers produce DIFFERENT images from the same commit — non-determinism baked into an
# air-gap artifact every node pulls.
#
# MEASURED 2026-08-25, A/B on the same context (346 MB on disk both times, .dockerignore the only
# difference): 347 MB copied into the image WITHOUT it, 1 MB WITH it. The untracked detritus across
# the six apps totalled 438 MB. It is invisible on a clean CI checkout — `git ls-files` over apps/
# returns ZERO bin/obj/target/node_modules — which is exactly why it went unnoticed.
#
# WHAT THIS TEST DOES NOT DO: it does not build anything, so it cannot re-prove the 347->1 MB
# reduction. It asserts the file exists and names the language's build output, which is what rots.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# The build-output directory each language leaves in its context. DERIVED per app from its language
# column, never a hand-typed per-app list — a new app of a known language is covered automatically.
want_pattern() {
  case "$1" in
    java)   printf 'target/' ;;
    rust)   printf 'target/' ;;
    go)     printf 'bin/'    ;;
    nodejs) printf 'node_modules/' ;;
    python) printf '__pycache__/' ;;
    dotnet) printf 'obj/'    ;;
    *)      printf '' ;;
  esac
}

n=0
while read -r app; do
  [ -n "$app" ] || continue
  n=$((n+1))
  src="$(app_src "$app")"
  lang="$(app_lang "$app" 2>/dev/null || basename "$(dirname "$src")")"
  di="${src}/.dockerignore"
  if [ ! -f "$di" ]; then
    bad "${app}: no .dockerignore — 'COPY . .' will absorb the working tree"
    continue
  fi
  pat="$(want_pattern "$lang")"
  if [ -z "$pat" ]; then
    ok "${app}: .dockerignore present (language '${lang}' has no known build-output dir)"
  elif grep -qF "$pat" "$di"; then
    ok "${app}: .dockerignore excludes ${pat}"
  else
    bad "${app}: .dockerignore does not exclude '${pat}' (language ${lang})"
  fi
done < <(app_names)

[ "$n" -gt 0 ] || bad "app_names produced ZERO apps — the test measured nothing"
printf '  checked %s app(s)\n' "$n"

if [ "$fail" -eq 0 ]; then echo "test-dockerignore: OK"; else echo "test-dockerignore: FAILED"; exit 1; fi
