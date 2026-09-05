#!/usr/bin/env bash
# 29-vcenter-service-check.sh — EXERCISE vCenter's services; never ask them how they feel.
#
# WHY THIS EXISTS (measured incident, 2026-09-05, this lab)
# --------------------------------------------------------
# A hot-restored (libvirt `virsh save`/`restore`) VCF estate came back with a DEAD content
# library. Every symptom pointed somewhere else and every cheap check said the estate was fine:
#
#     /api/vcenter/services  ->  content-library  state=STARTED  health=HEALTHY
#     GET /api/content/library ->  HTTP 500                      <- on EVERY call, for 5.5 days
#
# The service self-reports HEALTHY because its health probe only checks its own database. So a
# post-restore verification built on service state or health is a FALSE GREEN, and this one was:
# the estate looked healthy while a guest VKS cluster sat at ImageCacheReady=False forever,
# because VKr node images are delivered through the content library.
#
# `govc about` ALSO passes in this state. It is a control, not a gate — if your smoke test is
# "can I reach vCenter", it passes and tells you nothing.
#
# ROOT CAUSE, and why a RESTART is the remedy rather than a certificate or NTP fix:
#     "Failed trying to retrieve token: ns0:RequestFailed:
#      EndTime: Sun Aug 30 17:22:22 GMT 2026 is not after startTime: Sat Sep 05 06:43:27 GMT 2026"
# startTime is NOW; EndTime is ~6 days in the PAST. Both competing explanations were MEASURED and
# REFUTED: clock skew is 0s on the VCSA and on ESXi, and every certificate is valid for years
# (TLS -> 2028, STS signing chain -> 2036). Nothing on disk or on the wire carries an Aug-30
# expiry, so the stale window can only come from IN-PROCESS state — which is exactly what a RAM
# snapshot freezes and carries across a multi-day suspension. A restart drops it.
#
# ⚠️ DO NOT TURN THIS INTO "ALWAYS RESTART content-library AFTER A RESTORE". That is an enumerated
# list of ONE service and it rots the first time a different token-bearing service breaks the same
# way. The durable form is what this script does: exercise the real API, and restart only what
# actually fails. Restart is the REMEDY, not a ritual.
#
# ⚠️ READ-ONLY BY DEFAULT. `--remediate` is opt-in and mutating.
#
# TENANT NOTE (CLAUDE.md RULE ZERO-B): most operators of this repo are TENANTS with no vCenter
# credentials at all. This script SKIPS CLEANLY (rc=0) when VCENTER_* is unset — it must never
# block a tenant who legitimately cannot run it. `make lab-preflight` covers the tenant-visible
# half of the same failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

REMEDIATE=0
for a in "$@"; do case "$a" in --remediate) REMEDIATE=1 ;; --help|-h)
  sed -n '2,40p' "$0"; exit 0 ;; esac; done

# Tunables. Documented in .env.example; all COMMENTED there so a per-run override survives
# load_env's `set -a` (the .env.example clobber rule).
VC_TIMEOUT="${VCENTER_API_TIMEOUT_SECONDS:-20}"
VC_RESTART_SETTLE="${VCENTER_RESTART_SETTLE_SECONDS:-45}"

if [ -z "${VCENTER_HOST:-}" ] || [ -z "${VCENTER_USERNAME:-}" ] || [ -z "${VCENTER_PASSWORD:-}" ]; then
  log_info "vcenter-service-check: SKIPPED — VCENTER_HOST/USERNAME/PASSWORD not all set."
  log_info "  This is the NORMAL state for a scenario-2 tenant, who has no vCenter credentials."
  log_info "  The tenant-visible half of this failure is covered by: make lab-preflight"
  exit 0
fi

# ⚠️ SECRETS NEVER IN ARGV, and NEVER extracted with `cut`. MEASURED 2026-09-05: an agent read
# VCENTER_PASSWORD with `grep | cut -d= -f2-`, which kept the surrounding SINGLE QUOTES from .env
# and produced an HTTP 401 — burning one of only THREE vCenter SSO attempts before a PERMANENT
# lockout. `load_env`'s `set -a` sourcing strips them correctly; `cut` does not.
# The credential goes into a curl -K config under umask 077, so it never reaches a command line.
_esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
CFG="$(mktemp)"; SESSCFG="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "$CFG" "$SESSCFG" "$BODY"' EXIT
( umask 077; printf 'user = "%s:%s"\ninsecure\nsilent\n' \
    "$(_esc "$VCENTER_USERNAME")" "$(_esc "$VCENTER_PASSWORD")" > "$CFG" )

# ⚠️ ONE authentication for the whole run. vCenter SSO locks the account PERMANENTLY after 3
# failed attempts, so this script authenticates ONCE and reuses the session for every probe.
SESSION="$(curl -sSk -K "$CFG" --max-time "$VC_TIMEOUT" -X POST \
             "https://${VCENTER_HOST}/api/session" 2>/dev/null | tr -d '"' || true)"
if [ -z "$SESSION" ]; then
  log_error "vcenter-service-check: could not open a vCenter session against ${VCENTER_HOST}."
  log_error "  STOPPING RATHER THAN RETRYING. vCenter SSO locks the account PERMANENTLY after 3"
  log_error "  failed attempts; a retry loop here would spend them. Confirm VCENTER_PASSWORD with"
  log_error "  whoever owns the lab before running this again."
  exit 2
fi
( umask 077; printf 'header = "vmware-api-session-id: %s"\ninsecure\nsilent\n' "$SESSION" > "$SESSCFG" )

_http() { # _http <path> -> prints the status code, never the body
  curl -sSk -K "$SESSCFG" --max-time "$VC_TIMEOUT" -o "$BODY" -w '%{http_code}' \
    "https://${VCENTER_HOST}/api/$1" 2>/dev/null || printf '000'
}

# The probe table: PATH|SERVICE|WHAT IT BREAKS IF DEAD.
# SERVICE is the vmon service name used to remediate; "-" means we do not know one, so a failure
# is reported and NOT auto-restarted (we never restart something we cannot name).
# ⚠️ vcenter/vm is the CONTROL. It passed throughout the incident, which is exactly why it must be
# here: a run where the control FAILS is a different problem (vCenter itself is down), and without
# it a total outage and a single dead service look identical.
PROBES="
vcenter/vm|-|CONTROL: base inventory. If THIS fails, suspect THIS SCRIPT before the estate — it caught a missing 'api/' prefix on its first live run.
content/library|content-library|VKr node images. Guest clusters never get past ImageCacheReady.
content/local-library|content-library|Local library items.
content/subscribed-library|content-library|Subscribed library sync (where VKr images come from).
cis/tagging/tag|-|Tag-based storage/VM policies.
vcenter/storage/policies|-|Storage policy selection for guest-cluster PVCs.
vcenter/namespaces/instances|-|vSphere Namespaces — where Harbor/ArgoCD Supervisor Services live.
"

log_info "vcenter-service-check: exercising the REAL APIs on ${VCENTER_HOST} (never the health field)"
checked=0; failed=0; _failed_svcs=""
while IFS='|' read -r p svc why; do
  [ -n "${p:-}" ] || continue
  checked=$((checked + 1))
  code="$(_http "$p")"
  case "$code" in
    2*) printf '  ok    %-34s %s\n' "$p" "$code" ;;
    *)  failed=$((failed + 1))
        printf '  FAIL  %-34s %s   %s\n' "$p" "$code" "$why"
        # the body names the real exception; it is the thing worth reading
        head -c 300 "$BODY" 2>/dev/null | tr -d '\n' | sed 's/^/        /'; echo
        case "$svc" in -) : ;; *) case " $_failed_svcs " in *" $svc "*) : ;; *) _failed_svcs="${_failed_svcs} ${svc}" ;; esac ;; esac ;;
  esac
done <<EOF
$(printf '%s\n' "$PROBES" | sed '/^[[:space:]]*$/d')
EOF

# ALWAYS print the denominator. A check that cannot say what it looked at cannot be trusted to
# have looked (this repo has shipped two gates that passed by not looking).
log_info "vcenter-service-check: exercised ${checked} endpoint(s), ${failed} failing"

if [ "$failed" -eq 0 ]; then
  log_info "vcenter-service-check: OK — every exercised service actually served."
  exit 0
fi

if [ "$REMEDIATE" != 1 ]; then
  log_error "vcenter-service-check: ${failed} endpoint(s) FAILED."
  [ -z "${_failed_svcs:-}" ] || log_error "  Remediable service(s):${_failed_svcs}"
  log_error "  Re-run with --remediate (or: make vcenter-repair) to restart them."
  log_error "  This is READ-ONLY by default because a restart is a mutation on someone's lab."
  exit 1
fi

if [ -z "${_failed_svcs:-}" ]; then
  log_error "vcenter-service-check: failures exist but NONE maps to a known vmon service."
  log_error "  Refusing to restart anything — we never restart a service we cannot name."
  exit 1
fi

for svc in $_failed_svcs; do
  log_info "vcenter-service-check: restarting '${svc}' (expect HTTP 204)"
  rc="$(curl -sSk -K "$SESSCFG" --max-time 90 -X POST -o /dev/null -w '%{http_code}' \
         "https://${VCENTER_HOST}/api/vcenter/services/${svc}?action=restart" 2>/dev/null || printf '000')"
  log_info "  restart ${svc}: http=${rc}"
done

log_info "vcenter-service-check: settling ${VC_RESTART_SETTLE}s before re-exercising"
sleep "$VC_RESTART_SETTLE"

# RE-EXERCISE. The restart's own 204 is a proxy; the endpoint serving again is the result.
again=0
while IFS='|' read -r p svc why; do
  [ -n "${p:-}" ] || continue
  code="$(_http "$p")"
  case "$code" in 2*) ;; *) again=$((again + 1)); printf '  STILL FAILING  %-30s %s\n' "$p" "$code" ;; esac
done <<EOF
$(printf '%s\n' "$PROBES" | sed '/^[[:space:]]*$/d')
EOF

if [ "$again" -eq 0 ]; then
  log_info "vcenter-service-check: REPAIRED — every endpoint serves again."
  exit 0
fi
log_error "vcenter-service-check: ${again} endpoint(s) still failing after restart."
log_error "  A restart clears IN-MEMORY state. If it did not help, the stale credential is"
log_error "  PERSISTED, and the next step is a full VCSA reboot — not a second service bounce."
exit 1
