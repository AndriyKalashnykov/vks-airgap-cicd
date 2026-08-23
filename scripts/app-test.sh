#!/usr/bin/env bash
# app-test.sh — run EVERY app's tests, dispatching by language from apps/registry.tsv.
#
# `make app-test` used to run the Java app's `mvnw test` and nothing else. With a second app that
# would have meant the Go app's tests NEVER ran in CI (a green static-check proving nothing about
# it). This loops the registry, so adding an app runs its tests automatically and adding a LANGUAGE
# is one `case` branch.
#
# Usage: app-test.sh [test|build] [app]     (default: test, every app)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

# NO_COLOR is the documented cross-tool standard (https://no-color.org) and is the RIGHT mechanism
# for this, not a regex: dotnet, cargo and others honour it. It is set once here rather than per arm.
#
# The ANSI strip in assert_ran stays as a FALLBACK, and the reason is measured, not defensive habit:
# on this box every runner already suppresses colour when stdout is a pipe, so the coloured form is
# NOT locally reproducible -- CI is the only place that produced it. Until a CI run proves NO_COLOR
# alone is sufficient, removing the strip would be asserting a fix I have not measured.
export NO_COLOR=1

ACTION="${1:-test}"
ONLY="${2:-}"

# assert_ran <app> <lang> <output-file>
#
# WHY THIS EXISTS. `make app-test` reported "OK for 6 app(s)" while the DOTNET arm discovered ZERO
# tests and exited 0 -- apps/dotnet/dotnetwebapp had no test file and no test-framework reference at
# all, so one sixth of this gate could not fail and the gate counted it as a pass. An exit code
# cannot distinguish "every test passed" from "there were no tests", and BOTH adversary rounds on
# 2026-08-23 independently named that as the top finding.
#
# So: parse the runner's OWN reported count and require it to be >= 1. Each pattern below was
# verified against that runner's real output, not assumed.
assert_ran() {
  local app="$1" lang="$2" out="$3" n=""
  [ -s "$out" ] || die "[${app}] the runner emitted ZERO BYTES — it did not run"
  # STRIP ANSI FIRST. Measured 2026-08-23: dotnet emits colour on the GitHub runner but not on the
  # dev box, so "  succeeded: 3" arrives as "\033[32m  succeeded: 3" and every ^-anchored pattern
  # misses it -- green locally, red in CI, for a run whose tests all passed. Any runner may colour
  # when TERM is set, so this is done for ALL languages rather than patched per language.
  local plain; plain="$(mktemp)"
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$out" > "$plain"
  # Single quotes below are DELIBERATE: each string is the CONTAINER's command, so its variables
  # must expand INSIDE the container, not on this host. The directive sits before the whole case,
  # not a branch - shellcheck rejects a per-branch directive (SC1124), and putting it on a branch
  # ALSO made the comment itself trip SC2016.
  # shellcheck disable=SC2016
  case "$lang" in
    go)     n=$(grep -cE '^--- PASS' "$plain" || true) ;;
    rust)   n=$(sed -n 's/.*test result: ok\. \([0-9]\+\) passed.*/\1/p' "$plain" | head -1) ;;
    # "4 passed in 0.04s" sits at LINE START, so a pattern demanding a char before the digit
    # matches nothing. Grep the phrase, not a position.
    python) n=$(grep -oE '[0-9]+ passed' "$plain" | grep -oE '[0-9]+' | head -1) ;;
    # node --test's spec reporter prints an INFO glyph then "pass N" (measured: "\u2139 pass 3"),
    # NOT "# pass N" as the TAP reporter would. Match the word, not the decoration.
    nodejs) n=$(grep -oE '(^|[^a-z])pass [0-9]+' "$plain" | grep -oE '[0-9]+' | head -1) ;;
    java)   n=$(sed -n 's/.*Tests run: \([0-9]\+\).*/\1/p' "$plain" | tail -1) ;;
    dotnet) n=$(sed -n 's/^ *succeeded: \([0-9]\+\).*/\1/p' "$plain" | head -1) ;;
  esac
  if [ -z "$n" ]; then
    sed 's/^/    | /' "$out" >&2
    die "[${app}] no test-count line in the runner's output (above) — it ran no tests"
  fi
  [ "$n" -ge 1 ] || { sed 's/^/    | /' "$out" >&2; die "[${app}] 0 tests collected"; }
  rm -f "$plain"
  TESTS_TOTAL=$((TESTS_TOTAL + n))
  log_info "[${app}] ${n} test(s) ran"
}

# Run a command, capturing output. Show it ONLY on failure -- a green run stays quiet, a red one
# shows everything. `rc` is read on its OWN line: never through a pipe, which would report the
# pipe's status instead of the runner's.
capture() {
  local app="$1" out="$2"; shift 2
  local rc=0
  "$@" > "$out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || { sed 's/^/    | /' "$out" >&2; die "[${app}] runner exited ${rc}"; }
}

# app_builder_local() now lives in lib/apps.sh -- it is shared by all four offline
# consumers of the local builder image, so its default cannot drift between them.

# run_in_builder <app> <lang> <out> <cmd> — run <cmd> inside the app's builder image.
#
# THE SHAPE IS LOAD-BEARING; each flag is here for a measured reason:
#
#   -v "$src:/src:ro"        the source is READ-ONLY, so a test run can never write into the operator's
#                            tree. Under rootful docker a writable bind mount leaves ROOT-OWNED files
#                            behind; --user is not the fix (under rootless podman container uid 1000
#                            maps to host 100999 and cannot write at all). Writing nothing sidesteps
#                            both engines' ownership models instead of working around either.
#   --tmpfs /work + cp -a    3 of 6 languages HARD-FAIL on a read-only source: cargo rc=101
#                            ("Read-only file system at /src/target"), maven rc=1 (cannot create
#                            target/classes), and node cannot resolve node_modules at /src at all.
#                            Staging into a tmpfs gives them a writable tree that is discarded on exit.
#   --network=none           the builders pre-bake every dependency; if one reaches the network the
#                            air-gap claim is false, and this is what proves it rather than asserting it.
#   --pull=never             `--pull` defaults to "missing" on BOTH podman and docker, and the pull
#                            happens BEFORE the container exists, so --network=none does not stop it.
#                            Without this a stale or mistyped tag silently fetches from a registry and
#                            the run "passes" against an image nobody intended.
#
# A missing -v is caught for free: `cp -a /src/.` fails, so the run cannot pass by testing the stale
# copy every Dockerfile.builder leaves at /build via its closing `COPY . .`.
run_in_builder() {
  local app="$1" lang="$2" out="$3" cmd="$4"
  local src img eng
  src="${REPO_ROOT}/$(app_src "$app")"
  img="$(app_builder_local "$app")"
  builder_freshness_check "${app}" "${img}"
  eng="$(container_engine)"
  # `image inspect`, NOT `image exists`: the latter is podman-only. MEASURED 2026-08-23:
  # `docker image exists alpine` -> rc=1 "unknown command", so on a docker box EVERY app died
  # "builder image not present" while the image was present. `image inspect` is valid on both.
  "$eng" image inspect "$img" >/dev/null 2>&1 || \
    die "[${app}] builder image ${img} not present — build it with 'make builder-image' (or podman build -f $(app_src "$app")/Dockerfile.builder)"
  capture "$app" "$out" "$eng" run --rm --network=none --pull=never \
    -v "${src}:/src:ro" --tmpfs "/work:exec,size=${BUILDER_TMPFS_SIZE:-2g}" -w /work \
    "$img" sh -c "cp -a /src/. /work/ && ${cmd}"
}

run_for_app() {
  local app="$1" lang out
  lang="$(app_lang "$app")"
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN

  if [ "$ACTION" = build ]; then
    # The build ACTION is retired. Its only caller was `make app-build`, whose only consumer was
    # `trivy-fs` -- and trivy-fs now builds the two artefacts it actually scans (a jar and a Go
    # binary) inside the builder images. Nothing else in the repo built an app on the host.
    die "app-build is retired: trivy-fs builds what it scans in the builder image. Use 'make app-verify'."
  fi

  # TEST runs in the app's own builder image -- the SAME image the Tekton task uses, so what is
  # tested here is what the pipeline builds. Every command below was MEASURED green in that image,
  # offline, on a read-only source: java 6, go ok, nodejs 3, python 4, rust 4, dotnet 3.
  log_info "[${app}] ${lang} test (in $(app_builder_local "$app"))"
  case "$lang" in
    # NOT -q: surefire's "Tests run: N" is an INFO line and -q suppresses the number assert_ran needs.
    java)   run_in_builder "$app" "$lang" "$out" './mvnw -B -o test' ;;
    # -v so each test emits "--- PASS"; a bare `go test` prints one "ok" per PACKAGE, counting
    # packages rather than tests. `go vet` first, as before -- it is not counted by assert_ran.
    go)     run_in_builder "$app" "$lang" "$out" 'go vet ./... && go test -v ./...' ;;
    # node_modules is baked at /build (Dockerfile.builder WORKDIR), NOT at /src, and ESM ignores
    # NODE_PATH -- so it must be copied into the work dir. `npm ci` is NOT run: the builder already
    # installed from the lockfile, and --network=none would make a reinstall impossible anyway.
    nodejs) run_in_builder "$app" "$lang" "$out" 'cp -a /build/node_modules /work/ 2>/dev/null; npm test' ;;
    # -p no:cacheprovider silences the .pytest_cache write; /opt/venv-dev carries pytest.
    python) run_in_builder "$app" "$lang" "$out" 'PYTHONDONTWRITEBYTECODE=1 /opt/venv-dev/bin/python -m pytest -q -p no:cacheprovider' ;;
    rust)   run_in_builder "$app" "$lang" "$out" 'cargo test --offline --locked' ;;
    # `dotnet test` CANNOT drive this: .NET 10 dropped VSTest support for Microsoft.Testing.Platform
    # (which TUnit runs on) and errors while STILL EXITING 0. An MTP test project is an executable.
    dotnet)
      # Resolve the test project ON THE HOST and pass a literal path in. Discovering it inside the
      # container needed a $-expression in a single-quoted string, which is unreadable and trips
      # SC2016 in a spot no directive can cleanly cover (a per-branch directive is SC1124).
      _proj=""; for _f in "${REPO_ROOT}/$(app_src "$app")"/tests/*.csproj; do
        [ -e "$_f" ] && { _proj="tests/$(basename "$_f")"; break; }; done
      [ -n "$_proj" ] || die "[${app}] no test project at $(app_src "$app")/tests/*.csproj"
      run_in_builder "$app" "$lang" "$out" \
        "DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet run --project ${_proj} -c Release" ;;
    *) die "app '${app}': unknown lang '${lang}' — add a branch to scripts/app-test.sh" ;;
  esac

  assert_ran "$app" "$lang" "$out"
  return 0
}

n=0
TESTS_TOTAL=0
while read -r app; do
  [ -n "$app" ] || continue
  [ -n "$ONLY" ] && [ "$ONLY" != "$app" ] && continue
  run_for_app "$app"
  n=$((n + 1))
done <<EOF
$(app_names)
EOF

# Print the denominator: a gate that cannot say how many apps it exercised cannot be trusted.
[ "$n" -gt 0 ] || die "no apps matched${ONLY:+ (APP=${ONLY})} — check apps/registry.tsv"
if [ "$ACTION" = test ]; then
  # Print TESTS, not apps. "OK for 6 app(s)" was true while one app ran zero tests; a test count
  # moves when coverage moves, and an app count does not.
  log_info "app-test: OK — ${TESTS_TOTAL} test(s) across ${n} app(s)"
else
  log_info "app-${ACTION}: OK for ${n} app(s)"
fi
