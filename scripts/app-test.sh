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

ACTION="${1:-test}"
ONLY="${2:-}"

run_for_app() {
  local app="$1" src; src="${REPO_ROOT}/$(app_src "$app")"
  case "$(app_lang "$app")" in
    java)
      case "$ACTION" in
        test)  log_info "[${app}] mvn test";     ( cd "$src" && ./mvnw -B -q test ) ;;
        build) log_info "[${app}] mvn package";  ( cd "$src" && ./mvnw -B -q -DskipTests package ) ;;
      esac
      ;;
    go)
      case "$ACTION" in
        # `go vet` too: it catches what the compiler does not, and the Tekton go-test task runs the
        # same pair — so local and in-pipeline testing are the same thing.
        test)  log_info "[${app}] go vet + go test"; ( cd "$src" && go vet ./... && go test ./... ) ;;
        build) log_info "[${app}] go build";         ( cd "$src" && CGO_ENABLED=0 go build -o /dev/null ./... ) ;;
      esac
      ;;
    nodejs)
      case "$ACTION" in
        # `npm ci`, not `npm install`: it installs from package-lock.json EXACTLY and errors when the
        # lockfile and package.json disagree -- the same "the lockfile is the contract" property go.sum
        # and Maven give the others, and exactly what the Tekton nodejs-test task runs.
        test)  log_info "[${app}] npm ci + npm test"; ( cd "$src" && npm ci --no-audit --no-fund --silent && npm test ) ;;
        # Nothing to compile. `npm ci` IS the build: it proves the lockfile resolves, which is the only
        # thing that can fail before runtime.
        build) log_info "[${app}] npm ci (no compile step)"; ( cd "$src" && npm ci --omit=dev --no-audit --no-fund --silent ) ;;
      esac
      ;;
    python)
      case "$ACTION" in
        # -q for the same output shape as the Tekton python-test task. There is no compile step, so the
        # "build" action is an IMPORT check: it proves app.py is loadable, which is the only thing that
        # can fail before runtime for an interpreted app.
        # A THROWAWAY VENV, not the bare interpreter. Python has no self-contained runner the way Java has
        # ./mvnw or Go has its module cache, so `python -m pytest` against the mise interpreter dies with
        # "No module named pytest" -- measured. The venv lives in a TEMP dir, never in the source tree: an
        # in-tree .venv would be swept into the builder image by its `COPY . .`. cwd stays $src so
        # `import app` resolves exactly as it does in the container. This fetches, like `npm ci` and mvnw
        # do here -- app-test is an INTERNET-SIDE target. The air-gap path is the Tekton python-test task,
        # which uses the builder image's pre-baked /opt/venv-dev and never reaches the network.
        test)  log_info "[${app}] pytest (throwaway venv)"
               _pyvenv="$(mktemp -d)"
               python -m venv "$_pyvenv/venv" >/dev/null
               "$_pyvenv/venv/bin/pip" install -q --disable-pip-version-check -r "$src/requirements.txt" pytest
               ( cd "$src" && "$_pyvenv/venv/bin/python" -m pytest -q ); _rc=$?
               rm -rf "$_pyvenv"; [ "$_rc" -eq 0 ] || exit "$_rc" ;;
        # "build" for an interpreted app == "the declared dependencies RESOLVE, and the source COMPILES".
        # It deliberately mirrors the nodejs arm above (`npm ci`, no compile step). It does NOT `import app`
        # with the bare interpreter -- measured, that dies "No module named flask", because the mise python
        # has only the stdlib. compileall gives the syntax half without needing the app to be importable,
        # and the venv install gives the dependency half.
        build) log_info "[${app}] resolve deps + compile check"
               _pyvenv="$(mktemp -d)"
               python -m venv "$_pyvenv/venv" >/dev/null
               "$_pyvenv/venv/bin/pip" install -q --disable-pip-version-check -r "$src/requirements.txt"
               ( cd "$src" && PYTHONDONTWRITEBYTECODE=1 "$_pyvenv/venv/bin/python" -m compileall -q . >/dev/null ); _rc=$?
               rm -rf "$_pyvenv"; [ "$_rc" -eq 0 ] || exit "$_rc" ;;
      esac
      ;;
    rust)
        case "$ACTION" in
        # --locked but NOT --offline, and the asymmetry is deliberate. app-test is the INTERNET-SIDE
        # target -- the same one where `npm ci` and the python venv are allowed to fetch -- so it must
        # populate a COLD cargo registry. MEASURED: --offline passed on a warm box and FAILED in CI with
        # "error: no matching package named `axum` found / offline mode (via `--offline`) can sometimes
        # cause surprising resolution failures". That is the warm-cache trap this repo already records
        # for ~/.m2, in a second ecosystem.
        # --locked still holds: the resolver may not CHANGE Cargo.lock, so the run stays reproducible.
        # THE AIR GAP IS TESTED ELSEWHERE BY CONSTRUCTION: k8s/tekton/tasks/rust-test.yaml and the app
        # Dockerfile both run --offline --locked, in the places that genuinely have no egress.
        test)  log_info "[${app}] cargo test";  ( cd "$src" && cargo test --locked --quiet ) ;;
        build) log_info "[${app}] cargo build"; ( cd "$src" && cargo build --release --locked --quiet ) ;;
      esac
      ;;
    dotnet)
      case "$ACTION" in
        # Telemetry off here too: the SDK phones home on first use, and app-test runs on operator boxes.
        test)  log_info "[${app}] dotnet test";  ( cd "$src" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet test --nologo -v q ) ;;
        build) log_info "[${app}] dotnet build"; ( cd "$src" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet build --nologo -v q -c Release ) ;;
      esac
      ;;
    *) die "app '${app}': unknown lang '$(app_lang "$app")' — add a branch to scripts/app-test.sh" ;;
  esac
}

n=0
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
log_info "app-${ACTION}: OK for ${n} app(s)"
