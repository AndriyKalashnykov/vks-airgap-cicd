#!/usr/bin/env bash
# ci-tier: fast — OFFLINE. Real certs + `openssl s_server` on 127.0.0.1. No lab, no network.
#
# test-fetch-ca-name.sh — fetch-ca.sh must check the anchor against the ADDRESS, and a refusal must
# be a NO-OP on the operator's filesystem (B553).
#
# WHY. `openssl verify -CAfile X X` is verify(X,X) for a self-signed leaf — true for ANY self-signed
# cert, as fetch-ca.sh:141-143 concedes. The script proved that, printed AUTHENTICATED, and said
# `set it in .env`. Following that on a live lab with an IP address and a DNS-only cert flipped
# lib/argocd.sh:385 into a verified branch that cannot succeed: argocd-auth-check PASS -> curl rc=60.
#
# THE DISCRIMINATOR IS THE ADDRESS. Cases 1/2 share a certificate, a server and a digest; only the
# address differs. If they ever agree, the name check is gone.
#
# Cases 3-5 pin what two adversary rounds found in the FIRST version of the fix — each was green
# under cases 1-2 alone, which is why they are here:
#   3  the refusal ran AFTER `install`, so it destroyed the operator's anchor while saying "do NOT
#      set this" about a file it had already replaced. secrets/ is gitignored => unrecoverable.
#   4  a CN-only cert passes openssl's -verify_hostname (CN fallback) but every Go client refuses it,
#      and crane/Kaniko/podman/containerd/argocd are all Go => rc=0 was a false green.
#   5  the SAN list was read from the CA, not the leaf. A real CA has no SAN, so on a chain the
#      remedy printed an empty list and then said "point the address at a name above".
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null || true
# ⚠️ `cd "$(dirname ...)/.."` SUCCEEDS as `cd /..` when dirname is missing, and under `set -uo` (no
# -e) a failing $( ) is not caught — so a `|| exit 1` never fires and the suite runs from /. Assert a
# sentinel instead of trusting the cd.
if [ ! -f scripts/fetch-ca.sh ]; then
  echo "SKIP: not at the repo root — cannot find scripts/fetch-ca.sh"; exit 0
fi

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1" >&2; }
# ⚠️ "SKIP" must be at LINE START: run-test-set.sh:64 counts `^[[:space:]]*SKIP[:[:space:]]`, so a
# trailing "... — SKIP" is invisible to it and a skipped run reports a bare `ok` — a CI green that
# measured nothing.
if ! command -v openssl >/dev/null 2>&1; then echo "SKIP: openssl absent"; exit 0; fi

T="$(mktemp -d)"
# ⚠️ PIDS GO TO A FILE, NOT A VARIABLE. `_serve` is invoked as `P="$(_serve ...)"` — a command
# substitution, i.e. a SUBSHELL — so a `SRVS="$SRVS $!"` inside it never reaches the parent and
# cleanup iterates an empty list. Measured: this leaked 3 `openssl s_server` listeners PER RUN,
# each holding an ephemeral port for the life of the box. A global cannot cross a subshell; a file can.
cleanup() {
  if [ -f "$T/pids" ]; then while read -r _p; do kill "$_p" 2>/dev/null; done < "$T/pids"; fi
  rm -rf "$T"
}
trap cleanup EXIT

_selfsigned() {
  openssl req -x509 -newkey rsa:2048 -keyout "$T/$1.k" -out "$T/$1.c" -days 2 -nodes \
    -subj "$2" ${3:+-addext "$3"} >/dev/null 2>&1
}
_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'; }
# A free port, retried: bind(0)+close is a TOCTOU window, and losing it made the test SKIP silently.
_serve() {  # $1=cert $2=key [$3=chain] -> prints the port
  local _i p
  for _i in 1 2 3; do
    p="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo "")"
    if [ -z "$p" ]; then return 1; fi
    openssl s_server -accept "$p" -cert "$1" -key "$2" ${3:+-cert_chain "$3"} -www -quiet >/dev/null 2>&1 &
    echo "$!" >> "$T/pids"
    sleep 1
    if kill -0 "$!" 2>/dev/null; then printf '%s' "$p"; return 0; fi
  done
  return 1
}
_run() {  # $1=pin $2=addr:port $3=out -> prints rc; leaves $T/$3.out and $T/$3.err
  TEST_CA_SHA256="$1" timeout 60 bash scripts/fetch-ca.sh "$2" "$T/$3" test >"$T/$3.out" 2>"$T/$3.err"
  echo "$?"
}
_said() { grep -qF "$2" "$T/$1.out" "$T/$1.err" 2>/dev/null; }

if ! _selfsigned dns "/CN=argocd" "subjectAltName=DNS:localhost,DNS:argocd-server"; then
  echo "SKIP: could not mint a fixture certificate"; exit 0
fi
if ! P="$(_serve "$T/dns.c" "$T/dns.k")"; then echo "SKIP: s_server did not start"; exit 0; fi
D="$(_fp "$T/dns.c")"

# ── 1. GREEN: the address IS a SAN, so prescribing the anchor is correct. ──
r="$(_run "$D" "localhost:$P" g.crt)"
if [ "$r" = 0 ] && [ -f "$T/g.crt" ]; then
  ok "a SAN address -> written, rc=0"
else
  bad "a SAN address did not produce a written anchor (rc=$r)"
fi
if _said g.crt 'set it in .env'; then
  ok "...and IS prescribed, because it works"
else
  bad "the WORKING case stopped prescribing — the fix over-corrected into a blanket refusal."
fi
# "VERIFIES" launders reachability into authenticity: an interceptor picks its own SANs.
# fetch-ca.sh:141-143 already deleted "VERIFIED" from the chain check for the same reason.
if _said g.crt 'VERIFIES'; then
  bad "reintroduced the word VERIFIES for a property a MITM forges freely."
else
  ok "...and does not claim to have VERIFIED anything"
fi

# ── 2. RED: same cert, same server, same digest — an IP address, and no IP SAN. ──
r="$(_run "$D" "127.0.0.1:$P" r.crt)"
if [ "$r" != 0 ]; then
  if [ "$r" = 3 ]; then ok "an address the cert does not present -> refused, rc=3 (per-cause)"
  else bad "refused, but rc=$r not 3 — the per-cause exit codes are what let a caller tell 'wrong
      address' from 'no usable SAN'; collapsing them loses that."; fi
else
  bad "an address with no matching SAN was accepted (rc=0). Only the NAME check can catch this:
      the chain verifies vacuously for any self-signed cert."
fi
if _said r.crt 'set it in .env'; then
  bad "STILL prescribes *_CA_FILE for an address the anchor cannot verify — that sentence is what
      broke the lab, and the warning above it is not enough."
else
  ok "...and does NOT prescribe the setting that would fail closed"
fi

# The refusal must be on STDERR: `make fetch-argocd-ca > log` otherwise swallows it whole, which is
# the lesson fetch-ca.sh:229 already paid for in 2026-08. `_said` greps BOTH streams and is blind to
# this, so it needs its own assertion — without it, reverting the `>&2` leaves the suite fully green.
if grep -qF 'REFUSING TO WRITE' "$T/r.crt.err" 2>/dev/null \
   && ! grep -qF 'REFUSING TO WRITE' "$T/r.crt.out" 2>/dev/null; then
  ok "...and the refusal is on STDERR, where a stdout redirect cannot swallow it"
else
  bad "the refusal is on stdout (or missing from stderr). 'make fetch-argocd-ca > log' then hides it
      entirely and rc is the only signal — fetch-ca.sh:229 records paying for this once already."
fi

# ── 3. A REFUSAL MUST NOT TOUCH THE OPERATOR'S FILE. ──
_selfsigned good "/CN=Operator Good CA"
cp "$T/good.c" "$T/keep.crt" 2>/dev/null || true
before="$(_fp "$T/keep.crt" 2>/dev/null || true)"
# Without this the comparison is empty==empty and reports `ok` having measured NOTHING.
if [ -z "$before" ]; then bad "case 3 fixture missing — this assertion measured NOTHING"; fi
r="$(_run "$D" "127.0.0.1:$P" keep.crt)"
if [ "$(_fp "$T/keep.crt")" = "$before" ]; then
  ok "a refusal leaves a pre-existing anchor UNCHANGED"
else
  bad "the refusal OVERWROTE the operator's existing anchor. *_CA_FILE defaults into ./secrets/,
      which is gitignored and untracked, so this is unrecoverable. fetch-ca.sh:125-131 records
      paying for exactly this on 2026-08-05: a refusal must be a NO-OP, not a rollback."
fi
if [ "$r" != 0 ]; then
  ok "...and exits non-zero, so a caller can tell"
else
  bad "the refusal exited 0 — an automated caller reads that as success"
fi

# ── 4. NO SubjectAltName: openssl accepts it via the CN, every Go client refuses it. ──
_selfsigned nosan "/CN=localhost"
if P2="$(_serve "$T/nosan.c" "$T/nosan.k")"; then
  r="$(_run "$(_fp "$T/nosan.c")" "localhost:$P2" n.crt)"
  if [ "$r" != 0 ]; then
    if [ "$r" = 6 ]; then ok "a CN-only cert (no SAN) -> refused rc=6, though openssl accepts it"
    else bad "refused with rc=$r, expected 6 (no usable SAN)."; fi
  else
    bad "a CN-only cert was PRESCRIBED. openssl's -verify_hostname falls back to the CN, but Go says
      'x509: certificate relies on legacy Common Name field' — and crane, Kaniko, podman, containerd
      and the argocd CLI are all Go, so this anchor fails closed for every consumer."
  fi
else
  echo "SKIP: s_server did not start for the no-SAN case"
fi

# ── 4b. A SAN OF THE WRONG TYPE. The realistic half-done shape: CN is the name, SAN carries only
# the IP. openssl's -verify_hostname falls back to the CN, so requiring merely that SOME SAN exists
# let this through. Go: "x509: certificate is not valid for any names, but wanted to match localhost".
_selfsigned iponly "/CN=localhost" "subjectAltName=IP:10.9.9.9"
if P2b="$(_serve "$T/iponly.c" "$T/iponly.k")"; then
  r="$(_run "$(_fp "$T/iponly.c")" "localhost:$P2b" i.crt)"
  if [ "$r" != 0 ]; then
    ok "a SAN of the WRONG TYPE (IP-only, addressed by name) -> refused"
  else
    bad "a cert whose only SAN is an IP was PRESCRIBED for a NAME address. openssl accepts it via the
      CN fallback; every Go consumer refuses it. This is the incident, surviving inside its own fix."
  fi
else
  echo "SKIP: s_server did not start for the wrong-SAN-type case"
fi

# ── 4c. CONTROL against over-correcting: the repo's own KinD Harbor shape is CN=IP + SAN=IP:<addr>
# (lib/tls.sh:41-45). It must still be ACCEPTED, or the type check is a blanket refusal.
_selfsigned kindshape "/CN=127.0.0.1" "subjectAltName=IP:127.0.0.1"
if P2c="$(_serve "$T/kindshape.c" "$T/kindshape.k")"; then
  r="$(_run "$(_fp "$T/kindshape.c")" "127.0.0.1:$P2c" k.crt)"
  if [ "$r" = 0 ]; then
    ok "...and an IP SAN addressed BY IP is still accepted (no blanket refusal)"
  else
    bad "the type check refuses the repo's own KinD shape (CN=IP + IP SAN, addressed by IP, rc=$r).
      That is a false REFUSE and would break make e2e-kind."
  fi
else
  echo "SKIP: s_server did not start for the KinD-shape control"
fi

# ── 4d. THE PIN OUTRANKS THE ADDRESS. A round measured that running the address check FIRST replaced
# "CA FINGERPRINT MISMATCH ... something is intercepting this connection" with "the chain is fine;
# the ADDRESS is wrong" — and then told the operator to put the ATTACKER'S chosen name in /etc/hosts.
# An active-interception signal must not be reported as an addressing mistake.
r="$(_run "$(printf 'a%.0s' $(seq 64))" "127.0.0.1:$P" mm.crt)"
if grep -qF 'CA FINGERPRINT MISMATCH' "$T/mm.crt.out" "$T/mm.crt.err" 2>/dev/null; then
  ok "a wrong PIN outranks a wrong address (says MISMATCH, not 'the ADDRESS is wrong')"
else
  bad "with a MISMATCHING pin AND a wrong address, the script blamed the ADDRESS. The pin is the only
      authenticity signal here and it must be reported first; diagnosing the address instead walks the
      operator toward the interceptor."
fi
if grep -q 'etc/hosts' "$T/mm.crt.out" "$T/mm.crt.err" 2>/dev/null; then
  bad "under a pin MISMATCH it advises editing /etc/hosts — i.e. adopt the name the attacker offered."
else
  ok "...and does not advise adopting the offered name"
fi

# ── 4e. A SUBSTRING IS NOT A TYPE. `case $_sans in *"DNS:"*` accepted a cert whose ONLY SAN is a URI
# that happens to CONTAIN "DNS:" — measured rc=0, written, prescribed, while Go refuses it.
_selfsigned urisan "/CN=localhost" "subjectAltName=URI:https://x/?q=DNS:evil.com"
if P4="$(_serve "$T/urisan.c" "$T/urisan.k")"; then
  r="$(_run "$(_fp "$T/urisan.c")" "localhost:$P4" u.crt)"
  if [ "$r" = 6 ]; then
    ok "a URI SAN merely CONTAINING 'DNS:' is refused (rc=6), not read as a dNSName"
  else
    bad "a cert whose only SAN is URI:https://x/?q=DNS:evil.com was accepted (rc=$r). The gate is
      testing a SUBSTRING of openssl's rendered list, not a SAN TYPE; Go refuses this cert."
  fi
else
  echo "SKIP: s_server did not start for the URI-SAN case"
fi

# ── 5. A CHAIN: the SANs must come from the LEAF, not the CA (which carries none). ──
_selfsigned ca "/CN=Demo Root CA"
openssl req -newkey rsa:2048 -keyout "$T/lf.k" -out "$T/lf.csr" -nodes -subj "/CN=leaf" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost,DNS:argocd.example.test\n' > "$T/ext"
openssl x509 -req -in "$T/lf.csr" -CA "$T/ca.c" -CAkey "$T/ca.k" -CAcreateserial \
  -out "$T/lf.c" -days 2 -extfile "$T/ext" >/dev/null 2>&1
if P3="$(_serve "$T/lf.c" "$T/lf.k" "$T/ca.c")"; then
  r="$(_run "$(_fp "$T/ca.c")" "127.0.0.1:$P3" ch.crt)"
  if _said ch.crt 'argocd.example.test'; then
    ok "on a chain, the refusal names the LEAF's SANs"
  else
    bad "the refusal printed no usable SAN list on a multi-cert chain. It reads them from the CA,
      and a real CA carries no subjectAltName — so the remedy says 'point the address at a name
      above' with nothing above it. This is the cert-manager shape fetch-ca.sh:19 says it exists for."
  fi
else
  echo "SKIP: s_server did not start for the chain case"
fi

printf '\nfetch-ca name check: %s passed, %s failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then exit 1; fi
