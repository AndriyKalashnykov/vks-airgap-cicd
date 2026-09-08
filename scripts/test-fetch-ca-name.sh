#!/usr/bin/env bash
# ci-tier: fast — OFFLINE. A self-signed cert + `openssl s_server` on 127.0.0.1. No lab, no network.
#
# test-fetch-ca-name.sh — RED-proofs that fetch-ca.sh checks the NAME, not only the chain (B553).
#
# WHY THIS EXISTS. fetch-ca.sh proved the chain with `openssl verify -CAfile`, which for a SELF-SIGNED
# leaf is verify(X,X) — true for ANY self-signed cert, as its own :141-143 concedes. It then printed
# `AUTHENTICATED` and `set it in .env`. On a live lab, following that instruction with an IP address
# and a cert carrying no IP SAN flipped lib/argocd.sh:385 into its verified branch, which CANNOT
# succeed there: `make argocd-auth-check` went from PASS to `NO token (curl rc=60)`.
#
# THE DISCRIMINATOR IS THE ADDRESS AND NOTHING ELSE. Both cases below use the SAME certificate, the
# SAME server and the SAME digest; only the address differs — `localhost` (a SAN) vs `127.0.0.1` (no
# IP SAN). If a future change makes these agree, the name check is gone.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1" >&2; }

command -v openssl >/dev/null 2>&1 || { echo "openssl absent — SKIP"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null' EXIT

# A self-signed leaf whose ONLY SAN is the NAME localhost — deliberately no IP SAN, which is the
# shape every default self-signed server cert in this lab has (measured on ArgoCD: 5 DNS SANs, zero IP).
openssl req -x509 -newkey rsa:2048 -keyout "$T/k.pem" -out "$T/c.pem" -days 2 -nodes \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" >/dev/null 2>&1 \
  || { echo "could not mint a fixture cert — SKIP"; exit 0; }

# A free port, then serve the cert. `-www` makes s_server answer a request rather than hang.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 14443)"
openssl s_server -accept "$PORT" -cert "$T/c.pem" -key "$T/k.pem" -www -quiet >/dev/null 2>&1 & SRV=$!
sleep 1
kill -0 "$SRV" 2>/dev/null || { echo "s_server did not start — SKIP"; exit 0; }

DIG="$(openssl x509 -in "$T/c.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"

# ── GREEN: the address IS a SAN. The anchor verifies, so prescribing it is correct. ──
g="$(TEST_CA_SHA256="$DIG" timeout 60 bash scripts/fetch-ca.sh "localhost:$PORT" "$T/g.crt" test 2>&1)"
if printf '%s' "$g" | grep -q 'VERIFIES'; then
  ok "a SAN address -> 'VERIFIES … chain AND name'"
else
  bad "a SAN address did not report VERIFIES. Output:
$g"
fi
if printf '%s' "$g" | grep -q 'set it in .env'; then
  ok "...and the anchor IS prescribed, because it works"
else
  bad "the working case stopped prescribing the anchor — the fix over-corrected into a blanket refusal."
fi

# ── RED: same cert, same server, IP address. No IP SAN -> rc=3, chain OK and NAME wrong. ──
r="$(TEST_CA_SHA256="$DIG" timeout 60 bash scripts/fetch-ca.sh "127.0.0.1:$PORT" "$T/r.crt" test 2>&1)"
if printf '%s' "$r" | grep -q 'CANNOT VERIFY'; then
  ok "an address the cert does NOT present -> refused loudly"
else
  bad "an address with no matching SAN was NOT flagged. This is the live incident: the chain
      verifies vacuously for any self-signed cert, so only the NAME check can catch it. Output:
$r"
fi
# THE LOAD-BEARING ASSERTION. This exact sentence is what armed the break on a live lab.
if printf '%s' "$r" | grep -q 'set it in .env'; then
  bad "it STILL tells the operator to set *_CA_FILE for an address the anchor cannot verify.
      That instruction is the thing that broke the lab — the warning above it is not enough."
else
  ok "...and it does NOT prescribe the setting that would fail closed"
fi

printf '\nfetch-ca name check: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
