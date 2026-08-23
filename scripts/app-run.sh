#!/usr/bin/env bash
# app-run.sh — run ONE app locally, dispatched by language from apps/registry.tsv.
# Usage: app-run.sh [app]   (default: the FIRST app in the registry)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

APP="${1:-$(app_names | head -1)}"
src="${REPO_ROOT}/$(app_src "$APP")"
port="${APP_DEV_PORT:-8080}"

# CAPTURE FIRST. These were inline `$( )` in ARGUMENT position, where a `die` inside the
# substitution does NOT trip this script's `set -e` -- the same fail-open measured in creds.sh
# (FATAL printed, blank field rendered, rc=0). Note app_lang is the one that still matters here:
# making app_health_path branchless masks only HALF this line, and app_lang is what every other
# per-language `case` dispatches on.
_lang="$(app_lang "$APP")"
_health="$(app_health_path "$APP")"
log_info "running '${APP}' (lang=${_lang}) on http://localhost:${port}  [health: ${_health}]"
case "$(app_lang "$APP")" in
  java) ( cd "$src" && APP_INTERNAL_PORT="$port" ./mvnw -B spring-boot:run ) ;;
  go)   ( cd "$src" && APP_INTERNAL_PORT="$port" go run . ) ;;
  *)    die "app '${APP}': unknown lang — add a branch to scripts/app-run.sh" ;;
esac
