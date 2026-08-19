#!/usr/bin/env bash
# fetch-vcenter-ca.sh — obtain the trust anchor that verifies vCenter, and prove it verifies.
#
# WHY THIS EXISTS: since B133 the vCenter REST path FAILS CLOSED — it will not send the SSO
# administrator password to a peer whose identity it has not checked. That is correct, and on its
# own it is an OUTAGE: scenario-1 Step 2 (`make vsphere-namespace`) is the first `vc_login`
# consumer, and nothing in this repo produced a vCenter anchor. This is the other half.
#
# ⚠️ IT IS DELIBERATELY NOT PART OF `fetch-supervisor-ca.sh`, even though that script already
# downloads the very bundle this one needs. ORDERING: scenario-1 calls `make vsphere-namespace` at
# §2 and `make fetch-supervisor-ca` much later, so folding this in would put the fetch AFTER its
# first consumer. It also earns its own name beside fetch-harbor-ca / fetch-argocd-ca /
# fetch-supervisor-ca, which is the convention here.
#
# ⚠️ SELECTION IS BY HANDSHAKE, NEVER BY SUBJECT. MEASURED on a live lab: every cut mints a NEW
# VMCA whose subject is BYTE-IDENTICAL to the old one (`CN = CA, DC = vsphere, DC = local, …`),
# so a stale file from an earlier cut compares EQUAL while verifying nothing. This box has such a
# file — `secrets/vmca-root.pem` returns rc=60 against the live vCenter. Only a handshake tells
# them apart, which is why `ca_verifies_endpoint` (lib/tls.sh) does the deciding here.
#
# ⚠️ THE `-k` ON THE DOWNLOAD IS DELIBERATE AND IS NOT A HOLE. You are fetching a trust anchor you
# then authenticate OUT OF BAND — the same posture, with the same mitigation, that
# fetch-supervisor-ca.sh already accepts for the identical bundle. The fingerprint printed at the
# end is what authenticates it, not the transport. That sentence is not decoration: without
# confirming it, this is trust-on-first-use.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

load_env
require_cmd curl unzip openssl

: "${VCENTER_HOST:?VCENTER_HOST is not set (your vCenter FQDN, e.g. vcsa.env1.lab.test)}"
OUT="${VCENTER_CA_FILE:-${REPO_ROOT}/secrets/vcenter-ca.pem}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

log_info "downloading vCenter's own root bundle from https://${VCENTER_HOST}/certs/download.zip"
curl -sk --max-time "${VCENTER_CA_FETCH_TIMEOUT_SECONDS:-30}" -o "$tmp/vmca.zip" \
  "https://${VCENTER_HOST}/certs/download.zip" \
  || die "could not download https://${VCENTER_HOST}/certs/download.zip — is that the vCenter FQDN, and does this box resolve and reach it?"
[ -s "$tmp/vmca.zip" ] || die "vCenter returned an empty certificate bundle"

unzip -j -o -q "$tmp/vmca.zip" 'certs/lin/*.0' -d "$tmp/c/" 2>/dev/null \
  || die "the bundle did not contain certs/lin/*.0 — unexpected layout from ${VCENTER_HOST}"

# ── select by HANDSHAKE, and COUNT ────────────────────────────────────────────────────────────
# ⚠️ COUNTING IS NOT BOOKKEEPING. A bundle caught mid-rotation can carry TWO certs that both
# verify, and a silent first-match is how you install the one that is about to expire. Report the
# number; install only on exactly one, and make the operator choose otherwise.
match=""; nmatch=0; ncand=0; n_namefail=0
for f in "$tmp"/c/*.0; do
  [ -e "$f" ] || continue
  ncand=$((ncand + 1))
  rc=0; ca_verifies_endpoint "$VCENTER_HOST" 443 "$f" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) nmatch=$((nmatch + 1)); [ -z "$match" ] && match="$f" ;;
    3) n_namefail=$((n_namefail + 1)) ;;   # chain verifies, NAME does not — see below
  esac
done
log_info "candidates in the bundle: ${ncand}; verified vCenter by handshake: ${nmatch}"

if [ "$nmatch" -eq 0 ]; then
  # ⚠️ rc 3 is "the chain is fine, the NAME does not match", and it has a specific, likely cause:
  # VCENTER_HOST is documented FQDN-only, and an IP there produces exactly this for every
  # candidate. Saying "no root matches" would send the operator to hunt a certificate problem.
  if [ "$n_namefail" -gt 0 ] && [ "$n_namefail" -eq "$ncand" ]; then
    die "every one of the ${ncand} roots in vCenter's bundle verifies the CHAIN but not the NAME
  '${VCENTER_HOST}'. That is what an IP address (or a short name, or an alias) in VCENTER_HOST
  produces — the certificate is fine, the name you dialled is not the one it is issued for.
  Set VCENTER_HOST to the FQDN the certificate carries:
    openssl s_client -connect '${VCENTER_HOST}:443' </dev/null 2>/dev/null | openssl x509 -noout -text | grep -A1 'Subject Alternative Name'"
  fi
  log_error "none of the ${ncand} roots in vCenter's own bundle verifies ${VCENTER_HOST}. Candidates:"
  for f in "$tmp"/c/*.0; do
    [ -e "$f" ] && openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^/    /' >&2
  done
  die "cannot identify the CA for ${VCENTER_HOST}"
fi

if [ "$nmatch" -gt 1 ]; then
  log_warn "${nmatch} roots verify ${VCENTER_HOST} — the bundle is probably mid-rotation."
  log_warn "  Installing the FIRST would be a coin flip between a fresh CA and one about to expire."
  for f in "$tmp"/c/*.0; do
    [ -e "$f" ] || continue
    rc=0; ca_verifies_endpoint "$VCENTER_HOST" 443 "$f" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && printf '    %s  notAfter=%s  sha256=%s\n' "$(basename "$f")" \
      "$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)" \
      "$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" >&2
  done
  die "pick one deliberately and set VCENTER_CA_FILE to it, rather than letting this script guess."
fi

ensure_secret_dir "$(dirname "$OUT")"
# rm -f FIRST: `umask` applies only at CREATION, so a pre-existing 0644 file would keep its mode.
# A CA is public trust material, so 0644 is correct here — same reason the Harbor CA is 0644 and
# a 0600 one is unreadable to a container uid (this repo's recorded incident).
rm -f "$OUT"
install -m 0644 "$match" "$OUT"

fp="$(openssl x509 -in "$OUT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
log_info "wrote ${OUT}"
log_info "  subject:  $(openssl x509 -in "$OUT" -noout -subject 2>/dev/null | sed 's/^subject=//')"
log_info "  notAfter: $(openssl x509 -in "$OUT" -noout -enddate 2>/dev/null | cut -d= -f2)"
log_info "  SHA-256:  ${fp}"
# ⚠️ THIS SENTENCE IS THE CONTROL, not a formality. The anchor was pulled off the very wire it is
# meant to authenticate, so until you confirm this digest through a channel that is NOT this
# connection, what you have is trust-on-first-use. Both siblings carry the same clause:
# fetch-supervisor-ca.sh ("CONFIRM that fingerprint with your platform team over a channel that is
# NOT this connection") and 30-vks-login.sh ("the fingerprint is what authenticates it, not the
# transport").
log_warn "CONFIRM that SHA-256 with your platform team over a channel that is NOT this connection."
log_warn "  The fingerprint is what authenticates this anchor — the transport it arrived over does not."
