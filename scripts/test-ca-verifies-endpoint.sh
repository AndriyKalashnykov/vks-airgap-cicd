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

OBSERVED=""
ck() { # <label> <want-rc> <got-rc>
  OBSERVED="${OBSERVED}${3}\n"   # accumulate what was ACTUALLY returned — see the distinctness check
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
TLS_PORT="$(pick_port)"; PLAIN_PORT="$(pick_port)"; DEAD_PORT="$(pick_port)"; AC_PORT="$(pick_port)"
[ "$TLS_PORT" != 0 ] && [ "$PLAIN_PORT" != 0 ] && [ "$DEAD_PORT" != 0 ] && [ "$AC_PORT" != 0 ] \
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

# ⚠️ ACCEPT-THEN-CLOSE IS NOT PLAINTEXT, and conflating them hard-stopped a RETRYABLE state.
# A listener that accepts and closes with zero bytes is what an LB VIP looks like while its
# backend is still starting. MEASURED, deterministic 6/6, and the shapes are cleanly distinct:
#   accept-close: `unexpected eof while reading` / `handshake has read 0 bytes`
#   plaintext:    `wrong version number`         / `handshake has read 5 bytes`
python3 -c "
import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$AC_PORT)); s.listen(5)
end=time.time()+20
while time.time()<end:
    try:
        s.settimeout(2); c,_=s.accept(); c.close()
    except Exception: pass
" >/dev/null 2>&1 &
AC_PID=$!
sleep 1
r=0; ca_verifies_endpoint 127.0.0.1 "$AC_PORT" "$TMP/ca.pem" || r=$?; ck "accept-then-close -> RETRYABLE, not plaintext" 2 "$r"
kill "$AC_PID" 2>/dev/null

# ⚠️ `-s` IS NOT "USABLE": five broken-but-nonempty anchors all used to report the ENDPOINT
# as unreachable, because openssl never prints CONNECTED( when it cannot load the CA.
printf 'not a certificate at all\n' > "$TMP/garbage.pem"
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT" "$TMP/garbage.pem" || r=$?; ck "GARBAGE anchor -> NOT CONFIGURED, not unreachable" 5 "$r"
mkdir -p "$TMP/adir"
r=0; ca_verifies_endpoint 127.0.0.1 "$TLS_PORT" "$TMP/adir" || r=$?; ck "anchor is a DIRECTORY -> NOT CONFIGURED" 5 "$r"

# ⚠️ THIS CHECK WAS THEATRE, AND ITS COMMENT WAS WORSE THAN THE CHECK.
# It read `printf '0\n1\n2\n3\n4\n5\n' | sort -u | wc -l` — a CONSTANT. Always 6, reading
# nothing from what the function actually returned. RED-PROVEN by an adversary: reverting the
# function to the refuted "no peer certificate available ALONE" test turned the suite red on the
# two per-case regression arms and this check emitted NOTHING.
# The comment claimed it "catches it structurally, without depending on anyone remembering to
# keep those cases" — measured FALSE, and that sentence is an invitation to delete the only
# cases that work. A vacuous check is bad; a vacuous check that licenses deleting the real ones
# is how the original bug comes back.
# It now asserts over the OBSERVED verdicts, so it fails the moment two collapse onto one.
# ⚠️ NOT "all distinct" — two cases legitimately share verdict 5 (absent anchor and empty
# anchor), so an all-distinct assertion could never hold and would be a second piece of
# theatre. The real invariant is COVERAGE: every verdict this function can return must have
# been produced by at least one case. If two collapse onto one, the other goes MISSING here.
_missing=""
for _want in 0 1 2 3 4 5; do
  printf '%b' "$OBSERVED" | command grep -qx "$_want" || _missing="${_missing} ${_want}"
done
[ -z "$_missing" ] || { printf 'FAIL - verdict(s)%s were produced by NO case — two have collapsed. observed: %s\n' \
  "$_missing" "$(printf '%b' "$OBSERVED" | tr '\n' ' ')"; fail=$((fail+1)); }

printf 'test-ca-verifies-endpoint: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
