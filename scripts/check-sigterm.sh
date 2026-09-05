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
# ⚠️ SIX BYPASSES were found by an adversary running the FIRST version of this gate and are pinned
# by scripts/test-sigterm-gate.sh: shell-form ENTRYPOINT (docker wraps it in `/bin/sh -c`, so PID 1
# is a shell — the most natural way to write the bug); a wrapper-script ENTRYPOINT; `sh -lc`; the
# HEALTHCHECK's own CMD satisfying the `exec` test; a handler that is COMMENTED OUT; and an
# ENTRYPOINT that never runs the file the handler lives in (python under gunicorn).
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

# The container's ENTRYPOINT/CMD, at COLUMN 0 only. A HEALTHCHECK's own `CMD [...]` continuation is
# indented, and matching it was a bypass in BOTH directions: `exec` inside a healthcheck satisfied
# the check (false GREEN), and an ordinary `sh -c` healthcheck made the gate demand `exec` on a
# correct ENTRYPOINT (false RED, prescribing a fix that does nothing for SIGTERM).
_entrypoint() { grep -hE '^(ENTRYPOINT|CMD)[[:space:]]' "$1" | tr '\n' ' '; }

# Is this a JSON-array (exec) form? Anything else is SHELL form, which docker runs as
# `/bin/sh -c "<the whole string>"` — so PID 1 is a shell and SIGTERM stops at it.
_is_json_form() { grep -qE '(ENTRYPOINT|CMD)[[:space:]]*\[' <<< "$1"; }

# Does the exec-form command itself invoke a shell? Any `-*c` flag (-c, -lc, -ec), via a bare name,
# an absolute path, or `env`.
_runs_a_shell() { grep -qE '"([^"]*/)?(env[^"]*|)(ba|a|da|z|)sh"[[:space:]]*,[[:space:]]*"-[A-Za-z]*c"' <<< "$1"; }

check_app() {
  local app="$1" d f p ep src
  d="${REPO_ROOT}/$(app_src "$app")"
  checked=$((checked + 1))

  ep="$(_entrypoint "${d}/Dockerfile")"
  if [ -z "$ep" ]; then
    log_error "[${app}] Dockerfile declares no ENTRYPOINT/CMD at column 0 — cannot tell what PID 1 is"; fail=1
  elif ! _is_json_form "$ep"; then
    log_error "[${app}] SHELL-FORM ENTRYPOINT/CMD: docker runs it as \`/bin/sh -c '<...>'\`, so PID 1 is a"
    log_error "        SHELL and SIGTERM never reaches the server. Use JSON-array (exec) form."
    log_error "        ${ep}"
    fail=1
  elif _runs_a_shell "$ep" && ! grep -q 'exec ' <<< "$ep"; then
    log_error "[${app}] ENTRYPOINT runs the server under a shell WITHOUT \`exec\`, so PID 1 is the shell"
    log_error "        and SIGTERM never reaches the server. Add \`exec\`:"
    log_error "        ${ep}"
    fail=1
  fi

  # The ENTRYPOINT must actually RUN the file whose handler we are about to accept as evidence.
  # Bypass #6: a python app switched to `ENTRYPOINT ["gunicorn", ...]` never executes app.py's
  # `__main__`, so its handler is dead code and the gate happily read it. Same for a wrapper script.
  src="$(app_sigterm_file "$app")"
  case "$(app_lang "$app")" in
    nodejs|python|java)
      # Herestrings, not `printf | grep -q`: bash forks the LHS of a pipe into a subshell, so
      # `grep -q`'s early exit SIGPIPEs it and a FOUND pattern reports ABSENT at random.
      if ! grep -qF "$(basename "$src" | sed 's/\.yml$//')" <<< "$ep" \
         && ! grep -qE '\.jar|app\.py|server\.js' <<< "$ep"; then
        log_error "[${app}] the ENTRYPOINT does not run $(basename "$src") — the handler in it is DEAD CODE:"
        log_error "        ${ep}"
        fail=1
      fi ;;
  esac

  f="${d}/${src}"
  p="$(app_sigterm_pattern "$app")"
  if [ ! -f "$f" ]; then
    log_error "[${app}] ${src} does not exist — app_sigterm_file() is stale"; fail=1
  # COMMENTS STRIPPED: bypass #5 was a handler commented out, matched by the pattern anyway. The
  # comment leaders differ per language, so strip the union — `//`, `#`, and `--` at line start.
  # Herestring, NOT `sed | grep -q`: under pipefail `grep -q` exits at the first match and SIGPIPEs
  # the producer, so a FOUND pattern reports as ABSENT at random. check-grep-q-pipe caught this line.
  elif ! grep -qE "$p" <<< "$(sed -E 's@^[[:space:]]*(//|#|--).*@@' "$f")"; then
    log_error "[${app}] no LIVE SIGTERM handling in ${src} (looked for: ${p}; comments are stripped first)."
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
