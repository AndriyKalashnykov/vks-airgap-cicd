#!/usr/bin/env bash
# fetch-ca.sh <endpoint> <out-file> [label] — fetch the CA that ISSUED a TLS endpoint's certificate,
# and PROVE the result actually verifies that endpoint.
#
# THE BUG THIS REPLACES (it was in `make fetch-harbor-ca` AND `make fetch-argocd-ca`):
#
#     openssl s_client -showcerts | openssl x509 -outform PEM > ca.crt
#
# `openssl x509` reads only the FIRST PEM block on its stdin — which is the SERVER LEAF, not the CA.
# So both targets wrote a leaf certificate into a file called "ca.crt" and handed it to crane
# (SSL_CERT_FILE), to podman (--cert-dir) and to in-cluster Kaniko (the harbor-ca ConfigMap) as a trust
# anchor. Go builds a chain from the leaf to a ROOT whose Subject matches the leaf's Issuer; a leaf is not
# that root, so verification fails with `x509: certificate signed by unknown authority` — AFTER the
# runbook has told the operator this step "handles both consumers for you".
#
# It survived because our KinD stand-in never runs it (06-install-harbor.sh mints the CA and writes
# HARBOR_CA_FILE directly), and because a Harbor that serves a SELF-SIGNED leaf happens to make leaf==CA,
# which papers over the defect in exactly the case we test. On a real lab, where cert-manager issues a
# leaf from a separate CA, it breaks.
#
# So: take the LAST certificate the server presents (its issuer), fall back to the leaf when the server
# presents a single self-signed cert, and then VERIFY — `openssl verify` must actually validate the leaf
# against what we wrote. We do not write a trust anchor we have not proven is one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

EP="${1:?usage: fetch-ca.sh <endpoint> <out-file> [label]}"
OUT="${2:?usage: fetch-ca.sh <endpoint> <out-file> [label]}"
LABEL="${3:-endpoint}"

hostport="$(printf '%s' "$EP" | sed -E 's#^https?://##; s#/.*##')"
host="${hostport%%:*}"; port="${hostport##*:}"; [ "$port" = "$host" ] && port=443

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log_info "fetching the ${LABEL} CA from ${host}:${port}"

# -showcerts prints the WHOLE chain the server sends. Keep it all; we choose from it deliberately.
openssl s_client -connect "${host}:${port}" -servername "$host" -showcerts </dev/null 2>/dev/null \
  > "${tmp}/chain.txt" \
  || die "could not connect to ${host}:${port} — is ${LABEL} reachable over HTTPS?"

# Split the chain into one file per certificate, in the order the server sent them (leaf first).
awk -v d="$tmp" '
  /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/cert-%02d.pem", d, n) }
  n && f { print > f }
  /-----END CERTIFICATE-----/   { close(f) }
' "${tmp}/chain.txt"

n="$(find "$tmp" -maxdepth 1 -name 'cert-*.pem' | wc -l | tr -d ' ')"
[ "$n" -ge 1 ] || die "${host}:${port} presented NO certificate (is it really serving TLS?)"

leaf="${tmp}/cert-01.pem"
last="$(find "$tmp" -maxdepth 1 -name 'cert-*.pem' | sort | tail -1)"

subj="$(openssl x509 -in "$last" -noout -subject 2>/dev/null | sed 's/^subject=//')"
issu="$(openssl x509 -in "$last" -noout -issuer  2>/dev/null | sed 's/^issuer=//')"

if [ "$n" -eq 1 ]; then
  # A single cert. It is a legitimate trust anchor ONLY if it is self-signed (subject == issuer);
  # otherwise the server is not sending its issuer and we cannot derive the CA from the wire at all.
  if [ "$subj" != "$issu" ]; then
    die "${host}:${port} presents ONE certificate that is NOT self-signed (subject != issuer).
  Its CA is not on the wire, so it cannot be fetched from here. Ask the platform team for the issuing CA
  (subject: ${subj} / issuer: ${issu}) and point ${LABEL^^}_CA_FILE at it."
  fi
  log_info "server presents a single SELF-SIGNED certificate — it is its own CA"
else
  log_info "server presents a chain of ${n}; taking the last (the issuer) as the CA"
fi

mkdir -p "$(dirname "$OUT")"
cp "$last" "$OUT"
# PUBLIC trust material: 0644, always. A 0600 CA is unreadable by a container user with a different uid,
# and the failure it produces ("error adding trust anchors from file") names TRUST, not PERMISSIONS.
chmod 0644 "$OUT"

# ---- THE PROOF. We do not ship a trust anchor we have not verified is one. ----------------------------
# `openssl verify -CAfile <what we wrote> <the leaf>` is the same question every consumer will ask.
if openssl verify -CAfile "$OUT" "$leaf" >/dev/null 2>&1; then
  log_info "VERIFIED: the file we wrote actually validates ${host}'s certificate"
else
  rm -f "$OUT"
  die "the certificate we extracted does NOT verify ${host}'s leaf — refusing to write a trust anchor that
  does not work (it would fail later, inside crane/Kaniko, as 'x509: certificate signed by unknown
  authority', pointing you at the wrong thing). Ask the platform team for ${LABEL}'s issuing CA."
fi

printf 'wrote %s\n' "$OUT"
printf '  subject: %s\n' "$(openssl x509 -in "$OUT" -noout -subject | sed 's/^subject=//')"
printf '  set it in .env, e.g.  %s_CA_FILE=%s\n' "$(printf '%s' "$LABEL" | tr '[:lower:]' '[:upper:]')" "$OUT"
