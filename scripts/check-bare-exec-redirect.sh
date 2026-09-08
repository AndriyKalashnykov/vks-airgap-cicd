#!/usr/bin/env bash
#
# Gate: a BARE `exec` must not carry a `2>` redirection.
#
# `exec` WITH NO COMMAND applies every listed redirection to the CURRENT SHELL, permanently. So
#
#     exec 8>"$legacy" 2>/dev/null        # intent: swallow ONE open error
#
# sends stderr to /dev/null for the REST OF THE PROCESS. Everything that logs to fd 2 — every
# log_info / log_warn / log_error / die in lib/os.sh — goes silent, on the SUCCESS path, and the
# script keeps running and exits with a status nobody can explain.
#
# MEASURED, three live instances on 2026-09-08, all shipped and all green under every other gate:
#   lib/os.sh                     the registry lock's legacy guard. Its own refusal path then exited
#                                 1 printing NOTHING — including the `rm -f` remedy — and all four
#                                 callers re-exec themselves, so a whole mirror-push ran blind.
#   test-env-validate.sh:36       fired only when a port was busy, so a failing assertion printed no
#                                 reason at all. That file has no ci-tier marker: it runs on EVERY PR.
#   test-ca-staleness-check.sh:56 braces present but wrapping the wrong thing — `{ exec 3>&- 2>/dev/null; }`
#                                 attaches the redirection to the exec, not to the group.
#
# THE FIX IS ALWAYS THE SAME: scope it to a group, so the redirection belongs to the GROUP.
#     { exec 8>"$legacy"; } 2>/dev/null
#
# A bare `exec` opening a descriptor (`exec 9<>"$lock"`) is NOT flagged — that is the intended use.
# Only a `2>` riding along with it is, because that is the one whose blast radius is the whole
# process and whose symptom is silence.
#
# ⚠️ COMMENT LINES ARE STRIPPED FIRST. This file, and the ones it caught, DESCRIBE the defect in
# prose — so a raw scan flags the documentation and its only remedy is deleting the explanation.
# That is the refuted-on-sight shape, and it is why the strip deletes whole comment LINES rather
# than truncating at the first `#` (truncating breaks a `#` inside a string literal).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source lib/os.sh"; exit 1; }

# ⚠️ `(` IS DELIBERATELY NOT A COMMAND POSITION HERE, and `)` is excluded from the gap. An
# `exec` opened inside a SUBSHELL is the SAFE idiom — `(exec 3<>/dev/tcp/…) 2>/dev/null` scopes
# both the fd and the suppression to the subshell, which is precisely what you want. The first
# version of this gate included `(` and flagged SIX files, every one of them correct code whose
# only remedy would have been to break it. Known false NEGATIVE, accepted: a command
# substitution in the operand (`exec 8>"$(f)" 2>/dev/null`) hides behind the `)` exclusion.
_pat='(^|[;&|]|\bthen\b|\bdo\b|\belse\b)[[:space:]]*exec[[:space:]][^;{})]*2>'
_n=0; _hits=0
for _f in scripts/*.sh scripts/lib/*.sh; do
  [ -f "$_f" ] || continue
  _n=$((_n + 1))
  # An explicit, reasoned opt-out. A bare `exec 2>` for the WHOLE script is occasionally deliberate.
  _src="$(sed -e '/^[[:space:]]*#/d' -e '/bare-exec-ok:/d' "$_f" 2>/dev/null)"
  # NOT `| grep -q`: under pipefail an early-exiting grep SIGPIPEs the producer and a FOUND match
  # reports as ABSENT — in a scan gate that direction is a false CLEAN. Herestring spools instead.
  _m="$(grep -nE "$_pat" <<< "$_src" || true)"
  if [ -n "$_m" ]; then
    _hits=$((_hits + 1))
    log_error "  $_f: a BARE \`exec\` carries a \`2>\` redirection, which is PERMANENT for this shell:"
    printf '%s\n' "$_m" | sed 's/^/        /' >&2
  fi
done

if [ "$_hits" -ne 0 ]; then
  log_error "check-bare-exec-redirect: FAILED — $_hits file(s) of $_n scanned."
  log_error "  Scope the redirection to a GROUP so it belongs to the group, not to the shell:"
  log_error "      { exec 8>\"\$legacy\"; } 2>/dev/null"
  log_error "  If a process-wide \`exec 2>\` is genuinely intended, say so on the line: # bare-exec-ok: <why>"
  exit 1
fi
log_info "check-bare-exec-redirect: OK — no bare \`exec\` carries a \`2>\` redirection ($_n files scanned)."
