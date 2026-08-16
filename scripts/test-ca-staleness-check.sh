#!/usr/bin/env bash
# test-ca-staleness-check.sh — pin the FOUR ARMS of ca_verifies_endpoint that lab-preflight's
# stale-trust-anchor check depends on.
#
# WHY THE ARMS AND NOT JUST "DOES IT DETECT STALE": the abstain arm is what makes the check safe to
# ship. A probe that cannot tell "this anchor is wrong" from "the lab is switched off" would flag
# every anchor as dead the moment someone powers the lab down, and the first person to see that
# would (correctly) rip the check out. rc=1 and rc=2 MUST be different, and this asserts it.
#
# HERMETIC: a local TLS listener with its own throwaway CA, plus TEST-NET-1 for the black hole.
# Nothing here touches the lab, so it runs in CI.
#
# MEASURED against a real Supervisor 2026-08-16 before the check was written: 0 / 1 / 2 / 5 exactly
# as lib/tls.sh's header claims. This test is the offline version of that measurement.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${REPO_ROOT}/scripts/lib/tls.sh"

T="$(mktemp -d)"
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# ── a throwaway CA and a leaf it signs, plus a SECOND unrelated CA ───────────────────────────
( cd "$T"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 1 \
    -subj '/CN=test-ca' >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr \
    -subj '/CN=localhost' >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > ext.cnf
  openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out srv.crt -days 1 -extfile ext.cnf >/dev/null 2>&1
  # An unrelated CA — the "stale anchor" case: a real, well-formed CA that did not sign this leaf.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout other.key -out other.crt -days 1 \
    -subj '/CN=some-other-lab-ca' >/dev/null 2>&1 ) || { echo "could not build fixtures"; exit 1; }

for f in ca.crt srv.crt srv.key other.crt; do
  [ -s "$T/$f" ] || { echo "fixture $f missing — aborting rather than testing nothing"; exit 1; }
done

# Pick a free port rather than a fixed one, so two runs cannot collide.
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
openssl s_server -quiet -accept "$PORT" -cert "$T/srv.crt" -key "$T/srv.key" -naccept 20 \
  >/dev/null 2>&1 &
SRV_PID=$!
# Wait for it to actually listen — a race here would look like the unreachable arm.
for _ in $(seq 1 40); do
  (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && { exec 3>&- 2>/dev/null; break; }
  sleep 0.25
done

probe() { local rc=0; ca_verifies_endpoint "$1" "$2" "$3" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

# ── arm 0 — the CA that signed the leaf VERIFIES ─────────────────────────────────────────────
r="$(probe 127.0.0.1 "$PORT" "$T/ca.crt")"
if [ "$r" = 0 ]; then ok "rc=0  the correct anchor VERIFIES the endpoint"
else bad "rc=0  the correct anchor VERIFIES the endpoint" "got rc=$r"; fi

# ── arm 1 — a real but UNRELATED CA is STALE/WRONG. This is the defect being detected. ────────
r="$(probe 127.0.0.1 "$PORT" "$T/other.crt")"
if [ "$r" = 1 ]; then ok "rc=1  an unrelated anchor is reported STALE"
else bad "rc=1  an unrelated anchor is reported STALE" "got rc=$r"; fi

# ── arm 2 — UNREACHABLE must NOT be reported as stale. The safety of the whole check. ─────────
# 192.0.2.1 is TEST-NET-1: reserved, unroutable, and guaranteed not to answer.
r="$(probe 192.0.2.1 443 "$T/ca.crt")"
if [ "$r" = 2 ]; then ok "rc=2  an UNREACHABLE endpoint ABSTAINS (does not claim stale)"
else bad "rc=2  an UNREACHABLE endpoint ABSTAINS" "got rc=$r — a powered-off lab would be flagged as a stale anchor"; fi

# ── arm 1 vs 2 must be DISTINCT — an always-red probe is a coin flip, not a signal ────────────
a="$(probe 127.0.0.1 "$PORT" "$T/other.crt")"; b="$(probe 192.0.2.1 443 "$T/ca.crt")"
if [ "$a" != "$b" ]; then ok "stale and unreachable are DISTINGUISHABLE (${a} vs ${b})"
else bad "stale and unreachable are DISTINGUISHABLE" "both returned $a — the check cannot be trusted"; fi

# ── arm 5 — something that is not an anchor at all ───────────────────────────────────────────
r="$(probe 127.0.0.1 "$PORT" /dev/null)"
if [ "$r" = 5 ]; then ok "rc=5  a non-anchor file is reported as not usable"
else bad "rc=5  a non-anchor file is reported as not usable" "got rc=$r"; fi

# ── the CONSUMER must handle all four arms, and must not treat 2 as a problem ────────────────
# The arms live in 29-ca-status.sh (ONE implementation; lab-preflight sources it). A missing arm
# would fall through to the catch-all and mis-report — so assert each one exists where it actually
# is, not where the first draft put it.
CS="${REPO_ROOT}/scripts/29-ca-status.sh"
blk="$(awk '/case "\$rc" in/,/esac/' "$CS")"
[ -n "$blk" ] || { echo "FAILED to extract the case block from $CS — aborting rather than testing nothing"; exit 1; }
for arm in 0 1 2 5; do
  if printf '%s' "$blk" | grep -qE "^      ${arm}\)"; then ok "29-ca-status handles rc=${arm}"
  else bad "29-ca-status handles rc=${arm}" "no case arm — it would fall through to the catch-all"; fi
done

# rc=2 must NOT increment the stale count. This assertion was VACUOUS in my first version: it
# grepped a file the block had been moved out of, so "no match" read as "does not count it".
# Anchor it to the arm that actually exists, and prove the arm that DOES count is rc=1.
if printf '%s' "$blk" | awk '/^      2\)/,/;;/' | grep -q 'stale=\$((stale'; then
  bad "rc=2 does NOT count as stale" "the unreachable arm increments the count — a powered-off lab would fail the preflight"
else
  ok "rc=2 does NOT count as stale"
fi
if printf '%s' "$blk" | awk '/^      1\)/,/;;/' | grep -q 'stale=\$((stale'; then
  ok "rc=1 DOES count as stale (the control — an arm that counts nothing is not a check)"
else
  bad "rc=1 DOES count as stale" "nothing increments the count, so the check can never fail"
fi

# And lab-preflight must actually CONSUME it, or the wiring is decorative.
LP="${REPO_ROOT}/scripts/24-lab-preflight.sh"
if grep -q 'ca_status_report' "$LP"; then ok "lab-preflight calls ca_status_report"
else bad "lab-preflight calls ca_status_report" "the check exists but nothing runs it"; fi
if grep -qE 'problems=\$\(\(problems \+ _stale\)\)' "$LP"; then ok "lab-preflight folds stale anchors into its problem count"
else bad "lab-preflight folds stale anchors into its problem count" "a stale anchor would print and not fail"; fi

printf '\ntest-ca-staleness-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-ca-staleness-check: OK\n'
