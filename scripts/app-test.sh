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
