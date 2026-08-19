#!/usr/bin/env bash
# fetch-supervisor-ca.sh — scenario-1 Step 3.3 as one command.
#
# The Supervisor serves only its LEAF certificate, so the CA that signed it comes from vCENTER,
# not from the Supervisor. The doc walked the reader through six commands: curl the cert bundle,
# unzip it, print every candidate's subject, print the issuer the Supervisor presents, eyeball
# which matches, copy it, chmod it, print a fingerprint. That is exactly the kind of block a
# person gets wrong at 2am, and it is fully mechanical.
#
# WHY -k IS DELIBERATE ON THE FETCH: you are downloading a TRUST ANCHOR you then authenticate
# OUT OF BAND by its SHA-256 fingerprint. The fingerprint authenticates it, not the transport.
# This prints that fingerprint so you can confirm it with your platform team.
#
# A REBUILT lab mints a NEW CA at the SAME address, so a stale file looks valid and is not -
# which is why this refuses to install a CA that does not verify the live endpoint.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# EXPLICIT: os.sh does NOT source tls.sh (verified: zero references). Without this line
# ca_verifies_endpoint below is `command not found` -> rc 127, which no arm of its case handles.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
load_env

: "${VCENTER_HOST:?VCENTER_HOST is not set - your vCenter FQDN (NOT the Supervisor IP)}"
: "${SUPERVISOR_HOST:?SUPERVISOR_HOST is not set - the Supervisor control-plane IP}"
OUT="${VKS_CA_CERT_FILE:-./secrets/supervisor-ca.crt}"
require_cmd curl unzip openssl

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log_info "fetching vCenter's trusted roots from ${VCENTER_HOST}"
curl -sk --max-time "${VCENTER_CA_FETCH_TIMEOUT_SECONDS:-30}" -o "$tmp/vmca.zip" "https://${VCENTER_HOST}/certs/download.zip" \
  || die "could not download https://${VCENTER_HOST}/certs/download.zip - is that the vCenter FQDN, and does this box resolve it?"
[ -s "$tmp/vmca.zip" ] || die "vCenter returned an empty certificate bundle"
unzip -j -o -q "$tmp/vmca.zip" 'certs/lin/*.0' -d "$tmp/vmca/" 2>/dev/null \
  || die "the bundle did not contain certs/lin/*.0 - unexpected layout from ${VCENTER_HOST}"

# WHY THIS RETRIES, AND WHY THE PROBE IS curl AND NOT openssl.
#
# The Supervisor's control-plane IP is a FLOATING IP bound to whichever control-plane VM currently
# holds the etcd LEADER lease, re-evaluated every 5 seconds (Broadcom KB 313123; Supervisor
# Architecture: three CP VMs, "a floating IP address is assigned to one of the VMs"). During leader
# churn -- which a Supervisor-Service install/uninstall or a namespace delete provokes -- the FIP is
# bound to NO node: nothing answers ARP, SYNs blackhole, and the endpoint is simply GONE for a few
# seconds. That is a NORMAL transient, not something an operator must stop and fix.
#
# MEASURED 2026-08-11: this read failed after exactly its 10s cap while the SAME box completed the
# SAME handshake in 19-24 ms ten minutes later, and vCenter was reachable throughout. One blip cost
# a 45-minute walk at Step 3 and cascaded into 16 downstream block failures. A SINGLE ATTEMPT was
# the defect -- NOT the cap. Raising the cap only helps if you can guess the outage's length, and it
# re-creates the 132s silent hang the cap exists to delete (see .env.example).
#
# The probe is curl because `timeout N openssl s_client` CANNOT tell these apart -- measured, both
# are rc 124 with NO output:
#     connect timed out (FIP unbound)        openssl rc 124, silent   curl rc 28
#     TLS accepted but never spoke           openssl rc 124, silent   curl rc 35
# curl discriminates, needs no new dependency (require_cmd above already demands it), and rc 60
# ("TLS completed, cert untrusted") is the HEALTHY answer here -- we do not have the CA yet.
supervisor_reach() {                    # echoes a class; never dies, never retried inside
  local rc=0
  curl -s -o /dev/null --connect-timeout "${SUPERVISOR_CONNECT_TIMEOUT_SECONDS:-5}" \
       "https://${SUPERVISOR_HOST}/" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    6)  printf 'dns-failure' ;;      # the NAME does not resolve
    7)  printf 'refused' ;;          # something answered and said no -- a live host, wrong port/IP
    28) printf 'timeout' ;;          # SYN blackholed -- the FIP signature
    35) printf 'half-open' ;;        # accepted then went away mid-handshake -- a VIP mid-move
    *)  printf 'reachable' ;;        # incl. 60 = TLS fine, cert untrusted (expected: no CA yet)
  esac
}

# The issuer the Supervisor ACTUALLY presents is the ground truth: a vCenter with more than one
# trusted root offers several candidates and only one of them signed this endpoint.
#
# Budget sized from this repo's own precedent for the same class -- lib/vcenter.sh's
# VC_SS_INSTALL_RETRIES (60 x 10s = 10 min), whose comment says the budget is "sized from
# measurement, not taste". Three attempts would be two orders of magnitude below that. It costs
# nothing to be patient here: fetch-supervisor-ca is NOT on the install-all path, it is a standalone
# Step 3 command, so nothing automated is waiting on it.
issuer=""; reach=""; _t0="$(date +%s)"
_deadline=$(( _t0 + ${SUPERVISOR_TLS_BUDGET_SECONDS:-600} ))
while :; do
  # Keyed on the VALUE, not an exit code: `|| true` inside $( ) discards the rc anyway, and
  # `openssl x509` can exit before s_client finishes and SIGPIPE the producer.
  issuer="$(timeout "${SUPERVISOR_TLS_TIMEOUT_SECONDS:-10}" \
              openssl s_client -connect "${SUPERVISOR_HOST}:443" </dev/null 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)"
  [ -n "$issuer" ] && break
  reach="$(supervisor_reach)"
  # A WRONG HOST is not transient -- fail FAST and say so, which is what the 10s cap was added for.
  # Only the two blackhole classes are retried.
  case "$reach" in
    dns-failure) die "${SUPERVISOR_HOST} does not resolve from this box - SUPERVISOR_HOST is a Supervisor control-plane IP or FQDN (vCenter -> Workload Management -> Supervisors)" ;;
    refused)     die "${SUPERVISOR_HOST}:443 refused the connection - something is at that address but it is not a Supervisor. Check SUPERVISOR_HOST" ;;
  esac
  [ "$(date +%s)" -lt "$_deadline" ] || break
  log_warn "${SUPERVISOR_HOST}:443 is not answering (${reach}) - the Supervisor's floating IP moves with the etcd leader; retrying"
  sleep "${SUPERVISOR_TLS_RETRY_SECONDS:-10}"
done
# The message reports what was OBSERVED and offers both hypotheses. It must not assert "unreachable"
# the way its predecessor did: that sentence sent a reader to prove reachability for 20 minutes when
# reachability was fine.
[ -n "$issuer" ] || die "could not read the certificate ${SUPERVISOR_HOST}:443 presents after $(( $(date +%s) - _t0 ))s of retrying (last probe: ${reach}).
  Either the Supervisor's floating IP has not settled (it follows the etcd leader - check the control-plane VMs
  in vCenter), or SUPERVISOR_HOST is not this Supervisor. Raise the budget with SUPERVISOR_TLS_BUDGET_SECONDS."
log_info "the Supervisor's issuer: ${issuer}"

match=""
for f in "$tmp"/vmca/*.0; do
  [ -e "$f" ] || continue
  subj="$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  [ "$subj" = "$issuer" ] && { match="$f"; break; }
done
if [ -z "$match" ]; then
  log_error "none of vCenter's roots matches that issuer. Candidates:"
  for f in "$tmp"/vmca/*.0; do [ -e "$f" ] && openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^/    /' >&2; done
  die "cannot identify the CA for ${SUPERVISOR_HOST}"
fi

# VERIFY before installing: proves this CA really validates the live endpoint, which is what a
# stale file from a previous lab fails.
#
# This used to be a hand-rolled `openssl verify` over an `s_client` process substitution with NO
# timeout at all -- so the FIP transient above (which the read is now hardened against) would blow
# up HERE instead, ~127s later (tcp_syn_retries=6), under a message asserting "the matched CA does
# not verify". That names the wrong cause at the worst moment: the CA had just been correctly
# identified, and an operator following that sentence re-fetches a certificate that was already
# right. ca_verifies_endpoint returns TYPED codes and carries its own timeout, and rc 2 is
# explicitly "unreachable" -- which is retryable, not a verdict about the CA.
ca_tmp="$tmp/candidate.crt"; cp "$match" "$ca_tmp"
_vrc=0
while :; do
  ca_verifies_endpoint "$SUPERVISOR_HOST" 443 "$ca_tmp" || _vrc=$?
  [ "$_vrc" -ne 2 ] && break                      # 2 == unreachable: the ONLY retryable verdict
  [ "$(date +%s)" -lt "$_deadline" ] || break
  log_warn "${SUPERVISOR_HOST}:443 went away during verification - retrying (the FIP follows the etcd leader)"
  _vrc=0; sleep "${SUPERVISOR_TLS_RETRY_SECONDS:-10}"
done
case "$_vrc" in
  0) : ;;                                          # verified
  1) die "the CA that vCenter offers for this issuer does NOT verify ${SUPERVISOR_HOST}'s certificate - refusing to install it" ;;
  2) die "${SUPERVISOR_HOST}:443 stopped answering during verification and stayed away for the whole budget - this is a reachability problem, NOT a bad CA. Retry, or raise SUPERVISOR_TLS_BUDGET_SECONDS" ;;
  3) die "the chain verifies but the certificate does not name ${SUPERVISOR_HOST} - is SUPERVISOR_HOST the address this Supervisor's certificate was issued for?" ;;
  4) die "${SUPERVISOR_HOST}:443 presented no certificate" ;;
  *) die "could not verify ${SUPERVISOR_HOST}'s certificate against the matched CA (ca_verifies_endpoint rc=${_vrc})" ;;
esac

ensure_secret_dir "$(dirname "$OUT")"
cp "$match" "$OUT"; chmod 0644 "$OUT"      # a CA is public trust material, not a secret
log_info "installed ${OUT}"
openssl x509 -in "$OUT" -noout -fingerprint -sha256 2>/dev/null | sed 's/^/  /'
log_info "CONFIRM that fingerprint with your platform team over a channel that is NOT this connection."
log_info "next: make vks-login"
