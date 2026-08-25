#!/usr/bin/env bash
# scripts/test-clean-context-build.sh — every app must build from a CLEAN context.
#
# WHY THIS EXISTS. Both Dockerfiles do `COPY . .` over the app directory, so anything untracked in a
# developer's working tree silently becomes a build input. MEASURED 2026-08-25: the dotnet app's
# in-cluster build had been depending on a local `obj/` for its restore artifacts. Its own comment
# claimed "the builder already restored, and this is the flag that proves it" — but the builder
# restores at WORKDIR /build while the app builds at /src, so `/src/obj/project.assets.json` was
# never produced by it. The instant a .dockerignore excluded `obj/`, the build failed in ten seconds:
#     error NETSDK1004: Assets file '/src/obj/project.assets.json' not found
# A clean CI checkout would have failed identically. It passed for months because every run happened
# on a box that had built the app locally at least once.
#
# This builds each app from `git archive` — tracked files only, no untracked anything — which is the
# condition a fresh clone and an air-gapped Kaniko build both actually have.
#
# ci-tier: manual
#
# ⚠️ THE MARKER ABOVE IS LOAD-BEARING. `TEST_MANUAL` in the Makefile is
# `grep -l '^# ci-tier: manual' scripts/test-*.sh`, and TEST_OFFLINE filters it out. WITHOUT it the
# auto-discovery glob sweeps this file into `static-check`, where it builds SIX real images and
# needs `localhost/<app>-builder:<tag>` already present — so it would pass on the box that just
# built them and FAIL on CI and on any cold checkout. Measured while writing this: it was picked up
# and ran in 9s purely because every layer was in the local cache, which is precisely the kind of
# green that means nothing. Run it deliberately: `make check-clean-context`.
#
# CONFIGURABLE:
#   APP=<name>              build one app instead of all (default: every app in the registry)
#   CLEAN_CTX_BUILDER_TAG   builder image tag to build against (default: the repo's BUILDER_IMAGE_TAG)
#   CONTAINER_ENGINE        podman (default) or docker
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"

ENGINE="$(container_engine)"
TAG="${CLEAN_CTX_BUILDER_TAG:-${BUILDER_IMAGE_TAG:-0.3.0}}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0; n=0

# if/then, not `A && B || C` — the || arm runs when A is TRUE and B fails, which is the fake-green
# shape this repo keeps recording. (Caught by shellcheck SC2015 while writing this very file.)
if [ -n "${APP:-}" ]; then _apps="$APP"; else _apps="$(app_names)"; fi
for app in $_apps; do
  [ -n "$app" ] || continue
  n=$((n+1))
  src="$(app_src "$app")"
  rel="${src#"${REPO_ROOT}"/}"
  ctx="$TMP/$app"; mkdir -p "$ctx"
  # TRACKED PATHS, WORKING-TREE CONTENT. The invariant under test is "only tracked PATHS are build
  # inputs" — NOT "only committed content". Using `git archive HEAD` would test the committed tree,
  # so an uncommitted fix would appear to fail and an uncommitted BREAK would appear to pass; the
  # test would be measuring the wrong tree, which is the defect it exists to catch, one level up.
  ( cd "$REPO_ROOT" && git ls-files -z "$rel" ) | while IFS= read -r -d '' f; do
    d="$ctx/${f#"$rel"/}"
    mkdir -p "$(dirname "$d")"
    cp -p "${REPO_ROOT}/$f" "$d"
  done
  [ -f "$ctx/Dockerfile" ] || { printf '  FAIL  %s: no tracked Dockerfile under %s\n' "$app" "$rel"; fail=1; continue; }

  stray="$(find "$ctx" \( -name obj -o -name bin -o -name target -o -name node_modules \) | wc -l)"
  [ "$stray" -eq 0 ] || printf '  note  %s: %s build-output dir(s) are TRACKED — that is its own problem\n' "$app" "$stray"

  # DERIVE the arg from the app Dockerfile — do NOT reuse app_builder_arg(), which names the ARG of
  # the *Dockerfile.builder* (which base the BUILDER is built FROM: RUST_IMAGE, PYTHON_IMAGE, ...).
  # The APP Dockerfile declares a different one. Passing the wrong --build-arg is silently IGNORED,
  # so the app builds against a vanilla base with no warm cache and fails in a way that looks like a
  # clean-context defect. Measured while writing this: 2 of 3 "failures" were exactly that.
  barg="$(grep -oE '^ARG [A-Za-z_][A-Za-z0-9_]*' "$ctx/Dockerfile" | awk '{print $2}' | grep -E 'BUILDER' | head -1)"
  [ -n "$barg" ] || { printf '  FAIL  %s: no BUILDER-ish ARG in its Dockerfile — cannot point it at the local builder\n' "$app"; fail=1; continue; }
  if "$ENGINE" build -q --build-arg "${barg}=localhost/${app}-builder:${TAG}" \
        -f "$ctx/Dockerfile" -t "cleanctx-${app}:probe" "$ctx" >"$TMP/$app.log" 2>&1; then
    printf '  ok    %s builds from a clean context\n' "$app"
    "$ENGINE" rmi -f "cleanctx-${app}:probe" >/dev/null 2>&1 || true
  else
    printf '  FAIL  %s does NOT build from a clean context — it depends on an untracked file:\n' "$app"
    tail -6 "$TMP/$app.log" | sed 's/^/          /'
    fail=1
  fi
done

printf '  checked %s app(s) against builder tag %s\n' "$n" "$TAG"
[ "$n" -gt 0 ] || { echo "  FAIL  no apps were built — the test measured nothing"; fail=1; }
if [ "$fail" -eq 0 ]; then echo "test-clean-context-build: OK"; else echo "test-clean-context-build: FAILED"; exit 1; fi
