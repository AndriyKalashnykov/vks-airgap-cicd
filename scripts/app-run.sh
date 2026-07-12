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

log_info "running '${APP}' (lang=$(app_lang "$APP")) on http://localhost:${port}  [health: $(app_health_path "$APP")]"
case "$(app_lang "$APP")" in
  java) ( cd "$src" && APP_INTERNAL_PORT="$port" ./mvnw -B spring-boot:run ) ;;
  go)   ( cd "$src" && APP_INTERNAL_PORT="$port" go run . ) ;;
  *)    die "app '${APP}': unknown lang — add a branch to scripts/app-run.sh" ;;
esac
