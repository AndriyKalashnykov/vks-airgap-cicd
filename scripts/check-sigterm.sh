#!/usr/bin/env bash
# Every app must ACTUALLY RECEIVE and HANDLE SIGTERM. Two independent conditions, both required:
#
#   1. PID 1 must be the SERVER, not a shell. A `sh -c "java -jar ..."` ENTRYPOINT leaves `sh` as
#      PID 1, and a shell does NOT forward SIGTERM to its child — so the signal never reaches the
#      process that could act on it. `exec` fixes it.
#   2. The server must REGISTER a handler (or use a runtime that does). A container's PID 1 gets no
#      default signal dispositions, so an unregistered SIGTERM is simply IGNORED.
#
# Either one missing costs the same 30s: the kubelet waits out the whole terminationGracePeriod and
# SIGKILLs the pod, dropping in-flight requests on EVERY rollout.
#
# MEASURED 2026-09-05, container A/B per app (start it, send SIGTERM, time the exit):
#   BEFORE: java/nodejs/python/rust all STILL RUNNING after 21s.   AFTER: 0-1s.
#   And over 114 archived verify samples, the drain was 5s for the two apps that handled it and
#   30-35s for the four that did not (30s default grace + the harness's 5s poll).
#
# ⚠️ This is a STRUCTURAL check — it proves the handler is PRESENT, not that it WORKS. The behaviour
# is un-gateable offline (it needs a container and a real signal). The A/B above is the behavioural
# proof; this gate stops the code silently regressing between such runs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

fail=0 checked=0
check_app() {
  local app="$1" d f p ep
  d="${REPO_ROOT}/$(app_src "$app")"
  checked=$((checked + 1))

  # (1) PID 1 must not be a non-exec'ing shell.
  ep="$(grep -hE '^[[:space:]]*(ENTRYPOINT|CMD)' "${d}/Dockerfile" | tr -d '\n' || true)"
  if [ -z "$ep" ]; then
    log_error "[${app}] Dockerfile declares no ENTRYPOINT/CMD — cannot tell what PID 1 is"; fail=1
  elif printf '%s' "$ep" | grep -qE '"(/bin/)?(sh|bash)"[[:space:]]*,[[:space:]]*"-c"'; then
    if printf '%s' "$ep" | grep -q 'exec '; then
      :   # sh -c "exec <server> ..." — the shell is replaced, the server IS PID 1.
    else
      log_error "[${app}] ENTRYPOINT runs the server under \`sh -c\` WITHOUT \`exec\`, so PID 1 is the"
      log_error "        shell and SIGTERM never reaches the server. Add \`exec\`:"
      log_error "        ${ep}"
      fail=1
    fi
  fi

  # (2) The server must register a handler (or use a runtime that does).
  f="${d}/$(app_sigterm_file "$app")"
  p="$(app_sigterm_pattern "$app")"
  if [ ! -f "$f" ]; then
    log_error "[${app}] $(app_sigterm_file "$app") does not exist — app_sigterm_file() is stale"; fail=1
  elif ! grep -qE "$p" "$f"; then
    log_error "[${app}] no SIGTERM handling in $(app_sigterm_file "$app") (looked for: ${p})."
    log_error "        Without it the pod ignores SIGTERM, waits out the full 30s grace and is"
    log_error "        SIGKILLed — in-flight requests are dropped on every rollout."
    fail=1
  fi
}
for_each_app check_app

[ "$checked" -gt 0 ] || die "check-sigterm: scanned ZERO apps — apps/registry.tsv is empty or unreadable"
if [ "$fail" -ne 0 ]; then
  log_error "check-sigterm: FAILED (${checked} app(s) checked)."
  exit 1
fi
log_info "check-sigterm: OK — all ${checked} app(s) are PID 1 (or exec into it) AND register a SIGTERM handler."
