#!/usr/bin/env bash
# ── 09-harbor-auth-check.sh — fail in SECONDS on a Harbor credential Harbor REJECTS ──────────────
#
# ⚠️ THE TITLE USED TO SAY "that cannot push", AND THAT WAS A FALSE PROMISE (B710). This gate checks
# AUTHENTICATION, never PUSH CAPABILITY, and the two are not the same question. An idea round traced
# goharbor v2.15.2's middleware chain and found THREE separate things that let a credential
# authenticate, carry a `push` grant, and still be refused at push time — Harbor read-only mode
# (`readonly.Middleware`; the token endpoint is a GET and is skipped, the blob-upload POST is not),
# per-project QUOTA (`quota.PostInitiateBlobUploadMiddleware`), and IMMUTABLE TAG RULES
# (`immutable.Middleware`, PreconditionCode). The immutability one is the operationally likely case
# here: `make mirror` re-pushes the SAME tags every run, and immutable-tag rules are standard
# hardening on a platform team's Harbor — i.e. the RULE ZERO-B default posture. The round also
# enumerated more middlewares it did NOT check, so THREE is a floor, not a total.
#
# So: no read-only RBAC probe can promise "can push". Only a real write can, and that is a write on
# the credential path — it needs its own idea round and is NOT built here. Saying what this gate
# actually does is the fix; promising more is what B710 filed.
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
  # ⚠️ TWO STATES, NOT ONE SENTENCE. This line used to read "either the credential works, or there
  # was nothing to probe" — conflating a VERIFIED credential with a gate that checked NOTHING, which
  # is the reassuring direction. `harbor_auth_report` prints which of the two happened; this line
  # must not paper over it. And neither state is a statement about PUSH — see the header.
  log_info "Harbor auth gate: no rejection to report (see the line above, if any, for whether a credential was actually probed)."
  # ⚠️ B728: this line must NOT summarize state. It prints in the ACCEPTED arm AND in every
  # "nothing was probed" arm (harbor_auth_report returns 0 for no-URL / placeholder-password /
  # no-CA / inconclusive too), so the old "silent above = you have it" was a reassuring LIE there.
  # The per-state truth is the ok/PROBLEM line ABOVE, from report's SINGLE probe. This defers to it
  # and never re-probes. Two adversary rounds refuted keying it on harbor_auth_verdict: that re-runs
  # the GET (a second probe that can contradict the line above), and its 3-value string cannot tell
  # a 403 robot (push NOT probed here) from a 200/412 (push probed). A per-state summary keyed on the
  # http code needs harbor_auth_report to PUBLISH it (a harbor.sh touch) — deferred behind B721.
  log_info "  This says ONLY what the line above says, if any — a credential was accepted, or NOTHING was probed."
  log_info "  It does not prove PUSH: push RBAC is probed only when the line above shows http 200/412"
  log_info "  (a 403 robot is authenticated but NOT push-probed here); read-only mode, quota and"
  log_info "  immutable-tag rules can each refuse a push RBAC allows — only 'make mirror' proves push."
  exit 0
fi

log_error "Harbor auth gate FAILED — Harbor REJECTED the credential; refusing to start a ~20-minute mirror."
harbor_settle_note "  "
exit 1
