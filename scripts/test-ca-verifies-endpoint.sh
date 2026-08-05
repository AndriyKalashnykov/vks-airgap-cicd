#!/usr/bin/env bash
# ca_verifies_endpoint — its FIRST tests. It had NONE (measured: the only mention of it in
# scripts/test-*.sh was a COMMENT in test-fetch-ca-pin.sh explaining why that file's verdict 2 is
# reserved). So `make ci` was green over every change to it, including the two defects below.
#
# ⚠️ WHY A REAL ORACLE AND NOT CANNED TEXT. The two defects fixed here are BOTH about what
# `openssl s_client` actually prints in a state nobody thought to look at, and one of them
# (verdict 4) was originally "fixed" with a test that could not have caught the regression it
# introduced. Canned output would have encoded my own wrong model of the tool. Every case below
# talks to a real listener.
#
# ⚠️ THE REGRESSION ARM IS THE POINT. My first fix for verdict 4 tested `no peer certificate
# available` ALONE. That is NOT a plaintext signal: with `-verify_return_error` a FAILED
# verification aborts the handshake, so no peer cert is stored for a wrong anchor or a name
# mismatch either. MEASURED — it collapsed THREE verdicts into one (wrong CA 1->4, name mismatch
# 3->4), making the fix strictly WORSE than the bug. A plaintext-only test shows green on that.
# Cases 1-3 are what catch it; do not delete them as "unrelated to the change".
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

pass=0; fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [ -n "${TLS_PID:-}" ] && kill "$TLS_PID" 2>/dev/null; [ -n "${PLAIN_PID:-}" ] && kill "$PLAIN_PID" 2>/dev/null' EXIT

ck() { # <label> <want-rc> <got-rc>
  if [ "$2" = "$3" ]; then printf 'ok   - %s (rc=%s)\n' "$1" "$3"; pass=$((pass+1))
  else printf 'FAIL - %s: want rc=%s got rc=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

# ── oracles ────────────────────────────────────────────────────────────────────────────────────
# A leaf with an IP SAN for 127.0.0.1, plus a SECOND, unrelated CA to stand in for a stale anchor.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/ca.pem" -days 1 \
  -subj "/CN=probe" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 \
  || { echo "FAIL - could not mint a test certificate (openssl unusable) — broken test, not a clean tree"; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k2.pem" -out "$TMP/other.pem" -days 1 \
  -subj "/CN=other" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1

# Ports are EPHEMERAL, taken from the kernel: a fixed literal collides when two runs overlap (CI
# runs this suite in parallel with others), and a collision here looks like a verdict change.
pick_port() { python3 - <<'PY' 2>/dev/null || echo 0
import socket
s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()
PY
}
TLS_PORT="$(pick_port)"; PLAIN_PORT="$(pick_port)"; DEAD_PORT="$(pick_port)"
[ "$TLS_PORT" != 0 ] && [ "$PLAIN_PORT" != 0 ] && [ "$DEAD_PORT" != 0 ] \
  || { echo "FAIL - could not allocate ephemeral ports — broken test, not a clean tree"; exit 1; }

openssl s_server -accept "$TLS_PORT" -cert "$TMP/ca.pem" -key "$TMP/k.pem" -quiet >/dev/null 2>&1 &
TLS_PID=$!
python3 -m http.server "$PLAIN_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
PLAIN_PID=$!
sleep 1
# DEAD_PORT is deliberately never bound.

# POSITIVE CONTROL. Without it every case below could pass against a listener that never came up:
# an unreachable endpoint returns 2, and a suite asserting only "not 0" would read that as success.
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT" "$TMP/ca.pem" || r=$?
[ "$r" = 0 ] || { echo "FAIL - the TLS oracle is not answering (rc=$r) — every case below would be vacuous"; exit 1; }

# ── the six verdicts ───────────────────────────────────────────────────────────────────────────
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT"   "$TMP/ca.pem"    || r=$?; ck "real TLS, correct anchor -> verifies"        0 "$r"
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT"   "$TMP/other.pem" || r=$?; ck "real TLS, wrong anchor -> STALE (regression arm)" 1 "$r"
r=0; ca_verifies_endpoint localhost  "$TLS_PORT"  "$TMP/ca.pem"    || r=$?; ck "name absent from SAN -> NAME MISMATCH (regression arm)" 3 "$r"
r=0; ca_verifies_endpoint 127.0.0.1 "$PLAIN_PORT" "$TMP/ca.pem"    || r=$?; ck "PLAINTEXT endpoint -> served no certificate"  4 "$r"
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT"   "$TMP/nope.pem"  || r=$?; ck "anchor file absent -> NOT CONFIGURED"        5 "$r"
: > "$TMP/empty.pem"
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT"   "$TMP/empty.pem" || r=$?; ck "anchor file EMPTY -> NOT CONFIGURED"         5 "$r"
r=0; ca_verifies_endpoint 127.0.0.1 "$DEAD_PORT"  "$TMP/ca.pem"    || r=$?; ck "nothing listening -> UNREACHABLE"            2 "$r"

# ⚠️ THE VERDICTS MUST BE MUTUALLY DISTINCT, or a caller's `case` cannot branch on them. This is
# the check that would have caught my first fix collapsing three of them onto 4 — the per-case
# assertions above catch it too, but only because the regression arm exists; this catches it
# structurally, without depending on anyone remembering to keep those cases.
seen="$(printf '0\n1\n2\n3\n4\n5\n' | sort -u | wc -l)"
[ "$seen" = 6 ] || { echo "FAIL - the verdict set is not 6 distinct values"; fail=$((fail+1)); }

printf 'test-ca-verifies-endpoint: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
