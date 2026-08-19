#!/usr/bin/env bash
# ci-tier: fast — offline; two load_env runs in a throwaway REPO_ROOT (~1s).
#
# test-ca-status-strict.sh — ONE LINE IN A PERSONAL `.env` USED TO DISABLE THE ONLY CHECK FOR A
# MISSING HARBOR CA.
#
# `Makefile:623` does `preflight: export CA_STATUS_STRICT = 1`, and its own comment at :620 says
# why: inside `preflight` a missing Harbor CA is fatal because "nothing else catches it". But
# `24-lab-preflight.sh` calls `load_env`, which sources `.env.example` and `.env` with `set -a`
# AFTER the caller's environment is established — so a `.env` line BEATS the Makefile's export.
# MEASURED before the fix: Makefile exports 1, operator .env says 0 -> effective 0. The gate the
# repo calls "the cheapest failure available" was disarmed, silently, by a file the operator is
# invited to edit.
#
# It is also a RATCHET: with `.env` saying 0 there is no per-run way back, because
# `CA_STATUS_STRICT=1 make preflight` loses to the same `set -a`.
#
# ⚠️ ARM 2 IS NOT PADDING. Arm 1 alone is satisfied by a "fix" that hardcodes 1 — which would make
# the check unconditionally strict and fire on every non-preflight caller. The pair is what
# discriminates a working snapshot from a stuck one, and the secure DEFAULT (0 when nobody asks)
# has to survive.
#
# There is nothing legitimate to protect: `CA_STATUS_STRICT` appears NOWHERE in `.env.example`
# (asserted below) and `check-env-coverage.sh` classifies it as internal. If that ever changes —
# if someone documents it as an operator knob — this file should go red and the design revisited,
# which is why the absence is asserted rather than assumed.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# Replay 24-lab-preflight.sh's EXACT ordering — snapshot, source, load_env, restore — in a
# throwaway REPO_ROOT carrying an operator `.env` that tries to disarm it. The real `.env` is
# never read and never written.
probe() {  # $1 = value the "Makefile" exports, or empty for "caller sets nothing"
  local T; T="$(mktemp -d)"
  cp .env.example "$T/.env.example" 2>/dev/null || { rm -rf "$T"; printf 'NOENV'; return; }
  printf 'CA_STATUS_STRICT=0\n' > "$T/.env"
  cp -r scripts "$T/scripts"
  ( cd "$T" || exit 1
    [ -n "${1:-}" ] && export CA_STATUS_STRICT="$1"
    _s="${CA_STATUS_STRICT:-0}"                       # the snapshot, BEFORE load_env
    . scripts/lib/os.sh >/dev/null 2>&1
    load_env
    export CA_STATUS_STRICT="$_s"                     # the restore, AFTER
    printf '%s' "${CA_STATUS_STRICT:-<unset>}" )
  rm -rf "$T"
}

got="$(probe 1)"
if [ "$got" = 1 ]; then
  ok "Makefile exports 1 + operator .env says 0 -> STAYS 1 (the .env cannot disarm the CA check)"
else
  bad "the preflight CA check must survive a .env line. got '${got}', want 1.
        This is the whole defect: Makefile:623 exports 1, and load_env's set -a overwrote it."
fi

got="$(probe '')"
if [ "$got" = 0 ]; then
  ok "caller sets nothing -> 0 (the secure default is unchanged; the fix is not stuck-on)"
else
  bad "with no caller value the effective setting must remain 0. got '${got}'.
        A fix that hardcodes 1 passes arm 1 and breaks every non-preflight caller."
fi

# The premise this design rests on. If CA_STATUS_STRICT ever becomes a documented operator knob,
# ignoring the operator's .env stops being obviously right — so assert the absence rather than
# carry an assumption that silently rots.
if [ "$(grep -c 'CA_STATUS_STRICT' .env.example)" = 0 ]; then
  ok "CA_STATUS_STRICT is absent from .env.example, so no documented workflow is being broken"
else
  bad "CA_STATUS_STRICT now appears in .env.example. It is documented as an operator knob, so
        the pre-load_env snapshot silently ignores what the docs invite them to set — re-open the
        design. ⚠️ This sentence USED to say the same reasoning is why HARBOR_INSECURE must NOT be
          snapshotted. That was FALSIFIED 30 minutes later by 3d68b34, which snapshots it —
          my own change, in a control's text, un-swept until an adversary found it. The real
          distinction: the toggles have a CALLER who names them on the command line, so a
          snapshot restores a choice; CA_STATUS_STRICT has only the Makefile's export, so a
          snapshot restores a POLICY the operator never set.)"
fi

# And the mechanism has to still be REACHABLE — a check nobody calls proves nothing.
if grep -q 'CA_STATUS_STRICT' scripts/lib/tls.sh && grep -q 'ca_status_report' scripts/24-lab-preflight.sh; then
  ok "the value still reaches ca_status_report from the preflight (the path is not dead)"
else
  bad "CA_STATUS_STRICT is no longer read by lib/tls.sh, or the preflight no longer calls
        ca_status_report. Either way this file is now measuring nothing — fix or delete it."
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — a personal .env can no longer disarm the preflight CA check, and the secure\n'
printf '          default is unchanged.\n'
