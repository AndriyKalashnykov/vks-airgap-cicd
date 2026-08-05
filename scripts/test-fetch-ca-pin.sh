#!/usr/bin/env bash
# RED-proof for fetch-ca.sh's out-of-band fingerprint pin.
#
# WHY A TEST AND NOT A check-*.sh GATE: the pin lives in the operator's gitignored .env (or is passed
# per-run), so there is NOTHING IN THE REPO for a static gate to scan. Such a gate could only assert that
# a code path exists, and test-gate-vacuity.sh would then demand a starvation case it cannot honestly
# have. A gate that can only pass is the thing this repo calls a fake green. So: a real oracle instead.
#
# THE DEFECT THIS GUARDS (MEASURED 2026-08-05): fetch-ca.sh used to take a CA off the wire, `openssl
# verify` the leaf against it, and print "VERIFIED". A MITM's chain is self-consistent BY CONSTRUCTION,
# so that check cannot fail -- and in the single-cert branch it reduces to verify(X,X). An adversary
# served an EVIL self-signed cert to the unmodified script: it wrote the EVIL CA, printed VERIFIED,
# exited 0, and the written fingerprint matched the attacker's.
#
# WHAT A WRONG ANCHOR COSTS, so nobody weakens these cases later: lib/harbor.sh writes
# `user = "$HARBOR_USERNAME:$HARBOR_PASSWORD"` into a curl -K config and every harbor_api call submits it
# over the connection this file anchors; 22-harbor-robot.sh mints the robot with the ADMIN credential over
# the same channel. A MITM here harvests credentials, it does not merely serve bad images.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FETCH="${SCRIPT_DIR}/fetch-ca.sh"
[ -x "$FETCH" ] || { echo "INSTRUMENT MISSING: $FETCH is absent or not executable"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl not available"; exit 0; }

TMP="$(mktemp -d)"; PORT=""; SRV_PID=""
# shellcheck disable=SC2329  # invoked by the `trap ... EXIT` below; shellcheck cannot see trap dispatch
cleanup() {
  # ⚠️ Kill by PID. `pkill -f openssl` would SELF-MATCH this script's own command line (the portfolio
  # has a recorded incident where exactly that killed the invoking shell, exit 144).
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# --- an ephemeral free port; a fixed literal collides with a parallel run --------------------------------
for p in $(seq 18443 18470); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "SKIP: no free port in 18443-18470"; exit 0; }

# --- the oracle: a self-signed cert (the shape the lab Harbor actually presents) -------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 1 \
  -subj "/CN=127.0.0.1/O=ORACLE" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 \
  || { echo "SKIP: could not mint a test certificate"; exit 0; }

openssl s_server -cert "$TMP/c.pem" -key "$TMP/k.pem" -accept "$PORT" -www >/dev/null 2>&1 &
SRV_PID=$!
for _ in $(seq 1 40); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRV_PID" 2>/dev/null || { echo "SKIP: test TLS server did not start"; exit 0; }

REAL="$(openssl x509 -in "$TMP/c.pem" -noout -fingerprint -sha256 | sed 's/^.*Fingerprint=//' \
        | tr -d ':' | tr '[:upper:]' '[:lower:]')"
WRONG="$(printf '%064d' 0)"

run() {  # run <pin> <stdin-source>  -> sets RC and OUTPUT
  local pin="$1" stdin="$2"
  OUTPUT="$(HARBOR_CA_SHA256="$pin" "$FETCH" "127.0.0.1:${PORT}" "$TMP/out.crt" harbor <"$stdin" 2>&1)"
  RC=$?
}

echo "test-fetch-ca-pin: oracle on 127.0.0.1:${PORT}"

# --- 1. MATCHING pin -> proceeds -------------------------------------------------------------------------
rm -f "$TMP/out.crt"; run "$REAL" /dev/null
if [ "$RC" -eq 0 ] && [ -s "$TMP/out.crt" ]; then ok "matching pin writes the anchor"
else bad "matching pin should succeed" "rc=$RC"; fi

# --- 2. MISMATCHED pin -> refuses, names BOTH digests, writes NOTHING ------------------------------------
# This is the case that would have caught the original defect.
rm -f "$TMP/out.crt"; run "$WRONG" /dev/null
if [ "$RC" -ne 0 ]; then ok "mismatched pin refuses (rc=$RC)"; else bad "mismatched pin MUST refuse" "rc=0"; fi
if [ ! -e "$TMP/out.crt" ]; then ok "mismatched pin leaves NO anchor on disk"
else bad "a refused fetch must not leave a trust anchor behind"; fi
if printf '%s' "$OUTPUT" | grep -qi "$WRONG" && printf '%s' "$OUTPUT" | grep -qi "$REAL"; then
  ok "mismatch names BOTH the expected and the served digest"
else bad "mismatch must print both digests so the operator can tell which is wrong"; fi

# --- 3. NO pin, NO tty -> refuses ------------------------------------------------------------------------
# MEASURED: no make target depends on fetch-harbor-ca/fetch-argocd-ca and no CI workflow invokes them,
# so this refusal breaks no automated path. If that ever changes, fix the CALLER -- do not weaken this.
rm -f "$TMP/out.crt"; run "" /dev/null
if [ "$RC" -ne 0 ]; then ok "no pin + no tty refuses (rc=$RC)"; else bad "unattended TOFU MUST refuse" "rc=0"; fi
if [ ! -e "$TMP/out.crt" ]; then ok "no pin + no tty leaves NO anchor on disk"
else bad "an unconfirmed fetch must not leave a trust anchor behind"; fi

# --- 4. NO pin, a TTY, operator declines -> refuses -------------------------------------------------------
# The interactive branch needs a real pty; `printf 'n\n' | ...` would make [ -t 0 ] FALSE and silently
# re-test case 3 instead. `script` allocates one. Skipped, not faked, when it is unavailable.
if command -v script >/dev/null 2>&1; then
  rm -f "$TMP/out.crt"
  script -qec "HARBOR_CA_SHA256= '$FETCH' '127.0.0.1:${PORT}' '$TMP/out.crt' harbor" /dev/null \
    </dev/null >"$TMP/tty.log" 2>&1
  trc=$?
  if [ "$trc" -ne 0 ] && [ ! -e "$TMP/out.crt" ]; then ok "no pin + tty + declined refuses"
  else bad "a declined confirmation must refuse and write nothing" "rc=$trc"; fi
else
  printf '  SKIP  no pin + tty case (script(1) unavailable — cannot allocate a pty)\n'
fi

echo
if [ "$fail" -eq 0 ]; then echo "test-fetch-ca-pin: OK (${pass} passed)"; exit 0; fi
echo "test-fetch-ca-pin: FAILED (${fail} failed, ${pass} passed)"; exit 1
