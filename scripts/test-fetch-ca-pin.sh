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
# ⚠️ INCONCLUSIVE EXITS NON-ZERO. MEASURED 2026-08-05: these paths used `exit 0`, so forcing the
# free-port skip produced "SKIP: no free port" with rc 0 and ZERO assertions — and `make test-scripts`
# reads that as a pass. A harness that tested nothing must not be indistinguishable from one that
# tested everything. (The script(1)/pty skip further down stays rc 0: it is a PARTIAL skip of one
# case, not "the harness never ran".)
inconclusive() { echo "test-fetch-ca-pin: INCONCLUSIVE — $1 (nothing was asserted)"; exit 1; }
command -v openssl >/dev/null 2>&1 || inconclusive "openssl not available"

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
[ -n "$PORT" ] || inconclusive "no free port in 18443-18470"

# --- the oracle: a self-signed cert (the shape the lab Harbor actually presents) -------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 1 \
  -subj "/CN=127.0.0.1/O=ORACLE" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 \
  || inconclusive "could not mint a test certificate"

openssl s_server -cert "$TMP/c.pem" -key "$TMP/k.pem" -accept "$PORT" -www >/dev/null 2>&1 &
SRV_PID=$!
for _ in $(seq 1 40); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done
kill -0 "$SRV_PID" 2>/dev/null || inconclusive "the test TLS server did not start"

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
  # ⚠️ ASSERT THE DISCRIMINATOR, NOT rc + absence-of-file. MEASURED 2026-08-05: with the old assertion
  # (`rc != 0 && no file`) I mutated `if [ -t 0 ]` -> `if false`, killing the ENTIRE interactive consent
  # branch, and this file still reported 7/7 PASS rc 0 — because the non-tty branch satisfies exactly the
  # same two conditions. The comment above already named this hazard and then failed to guard it. The
  # only thing that separates the branches is WHICH MESSAGE APPEARS, so assert on that. $TMP/tty.log was
  # also captured and never read, which is what made it invisible.
  rm -f "$TMP/out.crt"
  script -qec "HARBOR_CA_SHA256= '$FETCH' '127.0.0.1:${PORT}' '$TMP/out.crt' harbor" /dev/null \
    </dev/null >"$TMP/tty.log" 2>&1
  trc=$?
  if [ "$trc" -ne 0 ] && [ ! -e "$TMP/out.crt" ] \
     && grep -q 'Does that digest match' "$TMP/tty.log" \
     && ! grep -q 'no terminal to confirm' "$TMP/tty.log"; then
    ok "no pin + tty + declined refuses VIA THE INTERACTIVE BRANCH"
  else
    bad "a declined confirmation must refuse via the PROMPT, not the no-tty path" \
        "rc=$trc prompt=$(grep -c 'Does that digest match' "$TMP/tty.log") no-tty=$(grep -c 'no terminal' "$TMP/tty.log")"
  fi
  # The ACCEPT branch had NO case at all: if `y|Y|yes|YES` were mistyped, every interactive operator
  # would be refused and nothing would notice. It fails closed, so this is completeness, not a hole.
  rm -f "$TMP/out.crt"
  printf 'y\n' | script -qec "HARBOR_CA_SHA256= '$FETCH' '127.0.0.1:${PORT}' '$TMP/out.crt' harbor" /dev/null \
    >"$TMP/tty2.log" 2>&1
  arc=$?
  if [ "$arc" -eq 0 ] && [ -s "$TMP/out.crt" ]; then ok "no pin + tty + ACCEPTED writes the anchor"
  else bad "an accepted confirmation must write the anchor" "rc=$arc"; fi
  # ...and it must SAY it is unauthenticated, or the success text reads like a verification.
  if grep -q 'NOT AUTHENTICATED — accepted on your confirmation alone' "$TMP/tty2.log"; then
    ok "the accepted path states the anchor is NOT authenticated"
  else bad "an accepted-on-consent anchor must not report like a verified one"; fi
else
  printf '  SKIP  no pin + tty cases (script(1) unavailable — cannot allocate a pty)\n'
fi

# --- 4b. A REFUSAL MUST NOT DESTROY AN EXISTING ANCHOR ---------------------------------------------------
# MEASURED 2026-08-05 (CRITICAL): fetch-ca.sh copied the candidate to $OUT ~50 lines BEFORE the first
# check, and every refusal path then `rm -f "$OUT"`. Planting a good CA and triggering a MISMATCH left
# `ls: cannot access` — DETECTING AN INTERCEPTOR DESTROYED THE OPERATOR'S GOOD ANCHOR, in ./secrets/,
# which is gitignored and untracked, so unrecoverable. The die even said "refusing to WRITE".
for scenario in "mismatch|$WRONG" "no-pin|" "malformed|:::"; do
  what="${scenario%%|*}"; pin="${scenario#*|}"
  printf 'PRECIOUS-EXISTING-ANCHOR\n' > "$TMP/out.crt"
  run "$pin" /dev/null
  if [ -e "$TMP/out.crt" ] && grep -q 'PRECIOUS-EXISTING-ANCHOR' "$TMP/out.crt"; then
    ok "a $what refusal leaves an EXISTING anchor untouched"
  else
    bad "a $what refusal DESTROYED the operator's existing anchor" \
        "$([ -e "$TMP/out.crt" ] && echo 'file was overwritten' || echo 'file was DELETED')"
  fi
done
rm -f "$TMP/out.crt"

# --- 4c. AN UNUSABLE LABEL MUST NOT FAIL OPEN ------------------------------------------------------------
# MEASURED 2026-08-05: the label becomes a variable name (${LABEL^^}_CA_SHA256, read by indirect
# expansion), so `fetch-ca.sh <ep> <out> my-registry` died with `invalid variable name` — AFTER writing
# the anchor and BEFORE any refusal path, leaving 1135 bytes of UNAUTHENTICATED 0644 trust material.
rm -f "$TMP/lbl.crt"
"$FETCH" "127.0.0.1:${PORT}" "$TMP/lbl.crt" my-registry </dev/null >/dev/null 2>&1
lrc=$?
if [ "$lrc" -ne 0 ] && [ ! -e "$TMP/lbl.crt" ]; then ok "an unusable label refuses and writes NOTHING"
else bad "an unusable label must not fail open" \
     "rc=$lrc anchor=$([ -e "$TMP/lbl.crt" ] && echo LEFT-BEHIND || echo none)"; fi

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
