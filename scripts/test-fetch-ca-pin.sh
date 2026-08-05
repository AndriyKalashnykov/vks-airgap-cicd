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

# --- 5. MALFORMED pin -> hard error, NEVER a silent downgrade to TOFU ------------------------------------
# MEASURED 2026-08-05, before the fix: a pin of ':::' normalised to EMPTY and took the trust-on-first-use
# branch. Unattended it still refused (safe by accident) — but on a TERMINAL the operator would have been
# asked y/N and would have believed they were pinned. The DISCRIMINATOR is which message appears, so assert
# on that and not merely on the exit code, or this case passes for the wrong reason.
for badpin in ':::' '   ' 'nothex' "$(printf '%s' "$REAL" | cut -c1-32)"; do
  rm -f "$TMP/out.crt"; run "$badpin" /dev/null
  label="malformed pin '$(printf '%.12s' "$badpin")'"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUTPUT" | grep -qi "not a SHA-256 digest"; then
    ok "$label is a FORMAT error"
  elif [ "$RC" -ne 0 ]; then
    bad "$label refused, but via the TOFU branch — a supplied pin was silently ignored" \
        "$(printf '%s' "$OUTPUT" | grep -i 'NOT AUTHENTICATED' | head -1)"
  else
    bad "$label MUST refuse" "rc=0"
  fi
  [ -e "$TMP/out.crt" ] && bad "$label left an anchor on disk"
done

# --- 6. the SHARED helper's five return codes, directly ---------------------------------------------------
# ca_pin_verdict is used by BOTH fetch-ca.sh and 30-vks-login.sh (the vCenter-credential path). Testing it
# through fetch-ca.sh alone would leave the login path's behaviour asserted only by inspection.
# ⚠️ 3 (not set) and 4 (set but unusable) MUST stay distinct — collapsing them is the exact defect that
# let ':::' be read as "no pin". And 2 is deliberately never returned: ca_verifies_endpoint uses it for
# UNREACHABLE and callers share `case` statements.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
vd() { local rc=0; ca_pin_verdict "$1" "${2:-}" || rc=$?; printf '%s' "$rc"; }
REAL_COLON="$(openssl x509 -in "$TMP/c.pem" -noout -fingerprint -sha256 | sed 's/^.*Fingerprint=//')"
for spec in "0|$REAL_COLON|colon-hex matches" \
            "0|$REAL|bare-hex matches" \
            "0|$(printf '%s' "$REAL" | tr '[:lower:]' '[:upper:]')|UPPERCASE matches" \
            "1|$WRONG|a valid-but-wrong digest MISMATCHES" \
            "3||an unset pin is NOT-SET (never a silent pass)" \
            "4|:::|a pin that normalises to empty is UNUSABLE, not unset" \
            "4|deadbeef|a short hex pin is UNUSABLE" ; do
  want="${spec%%|*}"; rest="${spec#*|}"; pin="${rest%%|*}"; desc="${rest#*|}"
  got="$(vd "$TMP/c.pem" "$pin")"
  if [ "$got" = "$want" ]; then ok "ca_pin_verdict: $desc (rc=$got)"
  else bad "ca_pin_verdict: $desc" "want rc=$want got rc=$got"; fi
done
got="$(vd "$TMP/definitely-absent.pem" "$REAL")"
if [ "$got" = "5" ]; then ok "ca_pin_verdict: an unreadable CA file is rc=5, distinct from a mismatch"
else bad "ca_pin_verdict: unreadable CA should be rc=5" "got rc=$got"; fi

echo
if [ "$fail" -eq 0 ]; then echo "test-fetch-ca-pin: OK (${pass} passed)"; exit 0; fi
echo "test-fetch-ca-pin: FAILED (${fail} failed, ${pass} passed)"; exit 1
