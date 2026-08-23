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
# RUN IN THE APP'S BUILDER IMAGE, not on the host. These six invocations were the LAST
# consumers of the host java/go/node/python/rust/dotnet toolchains; app-test, check-ui-contract
# and trivy-fs already run in the builders (all three MEASURED rc=0 with those toolchains
# stripped from PATH entirely).
#
# TWO DELIBERATE DIFFERENCES from the test path, and both matter:
#   -p PORT      this is a SERVER; the whole point is reaching it from the host.
#   NO --network=none   a test proves the build is offline; a dev server must be reachable.
# The source stays READ-ONLY and the work tree is a tmpfs, exactly as the test path, so a local
# run still cannot leave root-owned files in the operator's tree.
_img="$(app_builder_local "$APP")"
builder_freshness_check "${APP}" "${_img}"
_eng="$(container_engine)"
# `image inspect`, not `image exists`: the latter is podman-only (docker -> rc=1 unknown command).
"$_eng" image inspect "$_img" >/dev/null 2>&1 \
  || die "app '${APP}': builder image ${_img} not present — run 'make builder-build' (needs no Harbor)"
case "$_lang" in
  java)   _cmd='./mvnw -B spring-boot:run' ;;
  go)     _cmd='go run .' ;;
  # `node server.js`, NOT `npm start`: npm adds a process layer that swallows signals.
  nodejs) _cmd='node server.js' ;;
  python) _cmd='/opt/venv/bin/python app.py' ;;
  rust)   _cmd='cargo run --offline --locked --quiet' ;;
  dotnet) _cmd='dotnet run --no-launch-profile' ;;
  *) die "app '${APP}': unknown lang — add a branch to scripts/app-run.sh" ;;
esac
exec "$_eng" run --rm -it -p "${port}:${port}" \
  -e APP_INTERNAL_PORT="$port" -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 \
  -v "${src}:/src:ro" --tmpfs "/work:exec,size=${BUILDER_TMPFS_SIZE:-2g}" -w /work \
  "$_img" sh -c "cp -a /src/. /work/ && cp -a /build/node_modules /work/ 2>/dev/null; ${_cmd}"
