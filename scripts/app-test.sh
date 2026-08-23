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

run_for_app() {
  local app="$1" src lang out
  src="${REPO_ROOT}/$(app_src "$app")"
  lang="$(app_lang "$app")"
  out="$(mktemp)"; trap 'rm -f "$out"' RETURN

  case "$lang" in
    java)
      # NOT -q: surefire's "Tests run: N" is an INFO line, and -q suppresses the very number
      # assert_ran needs. Output is captured, so the verbosity costs nothing on a green run.
      case "$ACTION" in
        test)  log_info "[${app}] mvn test";    ( cd "$src" && capture "$app" "$out" ./mvnw -B test ) ;;
        build) log_info "[${app}] mvn package"; ( cd "$src" && ./mvnw -B -q -DskipTests package ) ;;
      esac
      ;;
    go)
      # -v so each test emits "--- PASS"; a bare `go test` prints one "ok <pkg>" line per PACKAGE,
      # which counts packages rather than tests and reads as 1 even when a file has 20 tests.
      case "$ACTION" in
        # `go vet` FIRST, as before the rewrite -- it catches what the compiler will not. It is not
        # counted by assert_ran (it reports no tests); only `go test` is.
        test)  log_info "[${app}] go vet + go test"
               ( cd "$src" && go vet ./... )
               ( cd "$src" && capture "$app" "$out" go test -v ./... ) ;;
        build) log_info "[${app}] go build"; ( cd "$src" && go build ./... ) ;;
      esac
      ;;
    nodejs)
      case "$ACTION" in
        # `npm ci`, NOT `npm install`: it installs from package-lock.json EXACTLY and errors when the
        # lockfile and package.json disagree -- the same "the lockfile is the contract" property go.sum
        # and Maven give the others, and exactly what the Tekton nodejs-test task runs.
        # Dropping it in the 2026-08-23 rewrite passed LOCALLY (node_modules already existed on the
        # dev box) and failed on CI's fresh checkout with "Cannot find package 'express'".
        test)  log_info "[${app}] npm ci + npm test"
               ( cd "$src" && npm ci --no-audit --no-fund --silent )
               ( cd "$src" && capture "$app" "$out" npm test ) ;;
        build) log_info "[${app}] npm build"; ( cd "$src" && npm run --silent build --if-present ) ;;
      esac
      ;;
    python)
      case "$ACTION" in
        test)  log_info "[${app}] pytest"; ( cd "$src" && capture "$app" "$out" uv run --quiet --with-requirements requirements.txt --with pytest -- pytest -q ) ;;
        build) log_info "[${app}] python compile"; ( cd "$src" && uv run --quiet -- python -m compileall -q . ) ;;
      esac
      ;;
    rust)
      case "$ACTION" in
        test)  log_info "[${app}] cargo test";  ( cd "$src" && capture "$app" "$out" cargo test --locked ) ;;
        build) log_info "[${app}] cargo build"; ( cd "$src" && cargo build --locked --release ) ;;
      esac
      ;;
    dotnet)
      # `dotnet test` CANNOT drive this: .NET 10 dropped VSTest support for Microsoft.Testing.Platform
      # (which TUnit runs on) and errors "Testing with VSTest target is no longer supported" -- while
      # STILL EXITING 0 (measured 2026-08-23). An MTP test project is an executable, so run it.
      case "$ACTION" in
        test)
          log_info "[${app}] dotnet test (TUnit/MTP)"
          # A glob loop, not `ls` (SC2012): with nullglob off an unmatched pattern stays literal,
          # so the -e test is what distinguishes "a test project exists" from "the glob did not match".
          local proj=""; local f
          for f in "$src"/tests/*.csproj; do [ -e "$f" ] && { proj="$f"; break; }; done
          [ -n "$proj" ] || die "[${app}] no test project at ${src}/tests/*.csproj"
          ( cd "$src" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
              capture "$app" "$out" dotnet run --project "$proj" -c Release )
          ;;
        build) log_info "[${app}] dotnet build"; ( cd "$src" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet build --nologo -v q -c Release ) ;;
      esac
      ;;
    *) die "app '${app}': unknown lang '${lang}' — add a branch to scripts/app-test.sh" ;;
  esac

  [ "$ACTION" = test ] && assert_ran "$app" "$lang" "$out"
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
