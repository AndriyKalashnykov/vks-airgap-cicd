#!/usr/bin/env bash
# ── 09-harbor-auth-check.sh — fail in SECONDS on a Harbor credential that cannot push ─────────────
#
# WHY THIS EXISTS (B209). `make install-all` already gates: preflight -> lab-preflight ->
# harbor_auth_report, so it dies in the first seconds on a stale credential and says so. `make
# mirror` does NOT -- it is `mirror-pull mirror-push mirror-verify`, so a rejected credential is
# discovered by `mirror-push` AFTER the ~20-minute pull. Same failure, same message, 20 minutes
# later. This target closes that one gap.
#
# IT IS DELIBERATELY NOT A PREREQUISITE OF `mirror-pull`. The sneakernet INTERNET box runs
# `make mirror-pull` with NO HARBOR AT ALL and no route to one -- gating it there would break the
# air-gap flow outright. The gate belongs on `mirror`, the dual-homed target that pushes.
#
# ⚠️ WHAT IT DOES NOT CATCH, stated so its green is not over-read: harbor_auth_report is a REPORTER
# and returns 0 when there is nothing to probe (no HARBOR_URL, no credentials, no CA to verify with
# -- see lib/harbor.sh). So on an unconfigured box this exits 0 having checked nothing. It is a
# fast-fail for the CONFIGURED-but-STALE case, which is the one that costs 20 minutes; it is not a
# completeness gate, and `mirror-push` remains the authoritative check.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"

load_env

if harbor_auth_report; then
  log_info "Harbor auth gate: nothing to report (either the credential works, or there was nothing to probe)."
  exit 0
fi

log_error "Harbor auth gate FAILED — refusing to start a ~20-minute mirror that cannot push."
harbor_settle_note "  "
exit 1
