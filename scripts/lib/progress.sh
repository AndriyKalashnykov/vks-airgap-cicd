#!/usr/bin/env bash
# scripts/lib/progress.sh — lightweight progress + completion-notify helpers for
# the long-running steps (mirror pull/push/verify, and any future long target).
# Source AFTER lib/os.sh (uses its _log/log_* stderr convention). All output goes
# to STDERR (like _log) so it never pollutes a stdout capture.
#
# Design notes:
#   - Progress is a COUNTER + ELAPSED timer, never a fake ETA — image/layer sizes
#     vary 100x, so a per-item ETA would lie. Count + elapsed is honest.
#   - The completion BELL is tty-gated ([ -t 2 ]); desktop notify (notify-send /
#     osascript) is BEST-EFFORT and must NEVER fail the caller (headless / no
#     DISPLAY / no dbus / missing binary all degrade silently).
#   - Does NOT add sleeps/delays — readiness polling already lives in the scripts
#     (kubectl wait, mirror_retry, K1.5 route polls); this only DISPLAYS progress.
#
# shellcheck shell=bash
[ -n "${__VKS_PROGRESS_SH_LOADED:-}" ] && return 0
__VKS_PROGRESS_SH_LOADED=1

# pg_fmt_dur SECONDS -> "Mm Ss" (or "Ss" under a minute). Pure arithmetic; no date.
pg_fmt_dur() {
  local s="${1:-0}" m
  if [ "$s" -ge 60 ]; then m=$((s / 60)); printf '%dm %02ds' "$m" $((s % 60));
  else printf '%ds' "$s"; fi
}

# pg_init TOTAL — begin a counted phase of TOTAL items. Records the start second.
pg_init() {
  _PG_TOTAL="${1:?pg_init needs a total}"
  _PG_I=0
  _PG_START=$SECONDS          # bash builtin: seconds since shell start (resume-safe, no Date.now)
}

# pg_step MSG — advance the counter and log "[i/N] (elapsed …) MSG" at INFO.
pg_step() {
  _PG_I=$((${_PG_I:-0} + 1))
  local elapsed=$((SECONDS - ${_PG_START:-$SECONDS}))
  printf '%s level=INFO msg=[%d/%d] (%s) %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_PG_I" "${_PG_TOTAL:-?}" "$(pg_fmt_dur "$elapsed")" "$*" >&2
}

# pg_done LABEL — emit the completion banner (elapsed since pg_init) + best-effort
# notification. Safe to call even if pg_init was never called (elapsed shows from
# shell start). LABEL is the human summary, e.g. "mirror-push: 34 images".
pg_done() {
  local label="$*" elapsed=$((SECONDS - ${_PG_START:-$SECONDS}))
  local dur; dur="$(pg_fmt_dur "$elapsed")"
  printf '%s level=INFO msg=✓ %s — done in %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$dur" >&2
  pg_notify "$label" "done in $dur"
}

# pg_notify TITLE MSG — best-effort completion signal. Terminal bell only when
# stderr is a tty; desktop notification only when a notifier + display exist.
# NEVER fails: every path is guarded and swallowed.
pg_notify() {
  local title="${1:-vks}" msg="${2:-done}"
  # Terminal bell — only to an interactive tty, never into a log file / CI.
  [ -t 2 ] && printf '\a' >&2 2>/dev/null || true
  # Desktop notify — Linux notify-send (needs a display/dbus) or macOS osascript.
  if command -v notify-send >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    notify-send "vks: $title" "$msg" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/}\" with title \"vks: ${title//\"/}\"" >/dev/null 2>&1 || true
  fi
  return 0
}
