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
load_env

: "${VCENTER_HOST:?VCENTER_HOST is not set - your vCenter FQDN (NOT the Supervisor IP)}"
: "${SUPERVISOR_HOST:?SUPERVISOR_HOST is not set - the Supervisor control-plane IP}"
OUT="${VKS_CA_CERT_FILE:-./secrets/supervisor-ca.crt}"
require_cmd curl unzip openssl

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log_info "fetching vCenter's trusted roots from ${VCENTER_HOST}"
curl -sk --max-time "${CURL_MAX_TIME_SECONDS:-30}" -o "$tmp/vmca.zip" "https://${VCENTER_HOST}/certs/download.zip" \
  || die "could not download https://${VCENTER_HOST}/certs/download.zip - is that the vCenter FQDN, and does this box resolve it?"
[ -s "$tmp/vmca.zip" ] || die "vCenter returned an empty certificate bundle"
unzip -j -o -q "$tmp/vmca.zip" 'certs/lin/*.0' -d "$tmp/vmca/" 2>/dev/null \
  || die "the bundle did not contain certs/lin/*.0 - unexpected layout from ${VCENTER_HOST}"

# The issuer the Supervisor ACTUALLY presents is the ground truth: a vCenter with more than one
# trusted root offers several candidates and only one of them signed this endpoint.
issuer="$(timeout "${SUPERVISOR_TLS_TIMEOUT_SECONDS:-10}" \
            openssl s_client -connect "${SUPERVISOR_HOST}:443" </dev/null 2>/dev/null \
          | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//' || true)"
[ -n "$issuer" ] || die "could not read the certificate ${SUPERVISOR_HOST}:443 presents - is SUPERVISOR_HOST right, and is the Supervisor reachable from this box?"
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
openssl verify -CAfile "$match" \
  <(printf '' | openssl s_client -connect "${SUPERVISOR_HOST}:443" -showcerts 2>/dev/null \
    | openssl x509 2>/dev/null) >/dev/null 2>&1 \
  || die "the matched CA does not verify ${SUPERVISOR_HOST}'s certificate - refusing to install it"

mkdir -p "$(dirname "$OUT")"
cp "$match" "$OUT"; chmod 0644 "$OUT"      # a CA is public trust material, not a secret
log_info "installed ${OUT}"
openssl x509 -in "$OUT" -noout -fingerprint -sha256 2>/dev/null | sed 's/^/  /'
log_info "CONFIRM that fingerprint with your platform team over a channel that is NOT this connection."
log_info "next: make vks-login"
