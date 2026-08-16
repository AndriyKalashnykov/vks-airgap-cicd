#!/usr/bin/env bash
# test-ca-anchor-validation.sh — OFFLINE unit test for ca_anchor_reject_reason (lib/tls.sh), B83c+d.
#
# THE DEFECT IT PINS. 27-harbor-ca-from-cluster.sh installs what it extracts as the machine's trust
# ANCHOR, and validated it by asking only whether it PARSED as a certificate. A LEAF parses. So a
# leaf could be installed as the anchor at exit 0 — a file that verifies nothing, whose failure
# surfaces much later as a pull that cannot establish trust, pointing anywhere but here.
#
# AND THE FIRST FIX WAS ITSELF DEFECTIVE, which is why these cases exist. It tested `case "$text" in
# *CA:TRUE*` against the WHOLE `openssl -text` dump — a substring search over operator- and
# attacker-controlled string fields. An adversary round minted three certificates with
# `basicConstraints=critical,CA:FALSE` that were ACCEPTED because the literal appeared in a CN, in
# an O, and in a subjectAltName URI. The SAN vector is the one that matters: essentially every real
# certificate carries a SAN, and it needs no strange DN at all. The function now reads
# `-ext basicConstraints`, whose output is a closed set and cannot carry an attacker string.
#
# WHY THIS FILE EXISTS AT ALL: B83(d) recorded ZERO test coverage of that script. The script itself
# needs a Supervisor kubeconfig and a live cluster, so it cannot be tested here — but the DECISION
# can, which is why it was extracted into lib/tls.sh.
#
# THE CERTS ARE REAL. A hand-written PEM would test the parser, not the predicate; every certificate
# below is minted by openssl at run time, so CA:TRUE / CA:FALSE / self-issuance are genuine.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
require_cmd openssl

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check() {  # check <name> <file> <want: ACCEPT|substring-of-the-reason>
  local name="$1" f="$2" want="$3" got ok=1
  got="$(ca_anchor_reject_reason "$f")"
  if [ "$want" = ACCEPT ]; then [ -z "$got" ] || ok=0
  else case "$got" in *"$want"*) ;; *) ok=0 ;; esac; fi
  if [ "$ok" -eq 1 ]; then
    pass=$((pass+1)); printf '  ok   %-46s -> [%s]\n' "$name" "$(printf '%s' "$got" | head -1 | cut -c1-58)"
  else
    fail=$((fail+1)); printf '  FAIL %-46s -> [%s] (want %s)\n' "$name" "$(printf '%s' "$got" | head -1)" "$want"
  fi
}

# a REAL self-signed CA — the shape that must be ACCEPTED
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Harbor CA" \
  -keyout "$TMP/ca.key" -out "$TMP/ca.crt" >/dev/null 2>&1

# a REAL leaf signed BY it — the shape that used to be installed as the anchor
openssl req -newkey rsa:2048 -nodes -subj "/CN=harbor.example.test" \
  -keyout "$TMP/leaf.key" -out "$TMP/leaf.csr" >/dev/null 2>&1
openssl x509 -req -in "$TMP/leaf.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" \
  -CAcreateserial -days 2 -out "$TMP/leaf.crt" >/dev/null 2>&1

# the three CA:FALSE certificates that DEFEATED the text-dump version, minted exactly as the
# adversary did. Each is self-signed (so it passes the subject==issuer half) and carries the
# literal `CA:TRUE` in a different string field.
# `-addext`, NOT `-extfile`: MEASURED, `openssl req` on 3.0.13 has no -extfile option and exits
# "Use -help for summary" — with stderr redirected that produced NO certificate and the three cases
# below then failed as "empty or missing", which reads like the function refusing them for the
# right reason. A fixture that never built is not a test.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=CA:TRUE" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -keyout "$TMP/n1.key" -out "$TMP/cn.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/O=CA:TRUE/CN=innocent.example" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -keyout "$TMP/n2.key" -out "$TMP/org.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=harbor.example.test" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "subjectAltName=URI:https://evil.example/CA:TRUE" \
  -keyout "$TMP/n3.key" -out "$TMP/san.crt" >/dev/null 2>&1

# ASSERT THE FIXTURES EXIST before judging anything with them — see above.
for _f in ca.crt leaf.crt cn.crt org.crt san.crt; do
  [ -s "$TMP/$_f" ] || { echo "FIXTURE MISSING: $_f — openssl did not mint it; this run judges nothing"; exit 1; }
done

# An INTERMEDIATE: CA:TRUE, but signed by the root rather than itself. This is the ONLY shape that
# proves the two checks are independent in the other direction — a leaf is CA:FALSE, so the CA:TRUE
# arm catches it even with the self-issued check deleted (measured, RED-proving this suite). An
# intermediate passes CA:TRUE and is caught ONLY by subject != issuer. It is also the exact case
# fetch-ca.sh:121's multi-cert branch would install today ("taking the last (the issuer)").
openssl req -newkey rsa:2048 -nodes -subj "/CN=Harbor Intermediate" \
  -keyout "$TMP/int.key" -out "$TMP/int.csr" >/dev/null 2>&1
openssl x509 -req -in "$TMP/int.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" -CAcreateserial -days 2 \
  -extfile <(printf 'basicConstraints=critical,CA:TRUE\n') -out "$TMP/int.crt" >/dev/null 2>&1
[ -s "$TMP/int.crt" ] || { echo "FIXTURE MISSING: int.crt — this run judges nothing"; exit 1; }

cat "$TMP/ca.crt" "$TMP/cn.crt" > "$TMP/bundle.crt"
printf 'not a certificate at all\n' > "$TMP/junk.pem"
: > "$TMP/empty.pem"

echo "== the anchor that SHOULD be accepted =="
check "a real self-signed CA"                     "$TMP/ca.crt"     ACCEPT

echo "== B83c: a LEAF must be REFUSED (it used to be installed, exit 0) =="
check "a leaf signed by that CA"                  "$TMP/leaf.crt"   "NOT self-issued"

echo "== the two checks are INDEPENDENT: an intermediate passes CA:TRUE and must still be refused =="
check "an intermediate (CA:TRUE, signed by the root)" "$TMP/int.crt" "NOT self-issued"

echo "== the text-dump defect: CA:FALSE certs carrying the literal in a string field =="
check "CA:FALSE, literal in the CN"               "$TMP/cn.crt"     "CA:TRUE"
check "CA:FALSE, literal in the O"                "$TMP/org.crt"    "CA:TRUE"
check "CA:FALSE, literal in a subjectAltName URI" "$TMP/san.crt"    "CA:TRUE"

echo "== a CAfile is a BUNDLE: every block becomes a root, only the first was validated =="
check "two certs concatenated"                    "$TMP/bundle.crt" "not 1"

echo "== extraction failures the caller must not write to the anchor =="
check "not a certificate"                         "$TMP/junk.pem"   "not a certificate"
check "empty (a jsonpath miss returns rc=0)"      "$TMP/empty.pem"  "empty or missing"
check "missing file"                              "$TMP/nope.pem"   "empty or missing"

printf '\ntest-ca-anchor-validation: %d passed, %d failed (%d cases)\n' "$pass" "$fail" "$((pass+fail))"
# FAIL-CHECK FIRST, then the ran-anything check — the reverse exits 0 on a run that printed FAIL.
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -gt 0 ] || { echo "no cases ran — this gate judged nothing"; exit 1; }
