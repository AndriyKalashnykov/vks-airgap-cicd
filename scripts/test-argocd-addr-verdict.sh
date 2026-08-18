#!/usr/bin/env bash
# test-argocd-addr-verdict.sh — pin the ADDRESS/ANCHOR discrimination that 70-configure-argocd.sh
# prints when the argocd API probe does not answer (repo item F9, backlog B148).
#
# WHY THIS FILE EXISTS. The fix shipped with its proofs run BY HAND in /tmp. An implementation
# adversary measured `test-argocd-classify` at 10/10 on BOTH the pre- and post-fix trees — an
# IDENTICAL count across a 63-line behavioural change, i.e. a gate blind to the thing it sits next
# to (gates.md §"A gate green at the SAME COUNT as before your change is BLIND to it"). Per
# gates.md, a RED-proof that is not committed as a runnable case expires at the next commit that
# touches the code or its toolchain. This is that case.
#
# WHAT IT PINS, and every line of it was a real defect in the first draft of the fix:
#   1. The host:port PARSER. A naive ${x%:*} / ${x##*:} split was MEASURED broken on SEVEN shapes —
#      a scheme (creds.sh:76 shows a scheme IS anticipated for ARGOCD_SERVER, and unlike HARBOR_URL
#      nothing rejects one), a trailing slash, and four IPv6 spellings. Each degraded to "did not
#      answer", blaming reachability for a MALFORMED VALUE — strictly worse than the generic text
#      it replaced.
#   2. The rc -> ARM mapping, against a REAL TLS endpoint. rc 3 (chain OK, NAME wrong) is the whole
#      point: it is the arm that tells the operator NOT to re-fetch a CA that is already correct.
#   3. That the SAN block is SUPPRESSED on rc 0. The first draft printed "It carries NO IP SAN"
#      unconditionally — measured to fire directly beneath a printed `IP Address:` SAN, and on an
#      address that had just verified.
#
# HERMETIC: own CA, own leaf, `openssl s_server` on loopback. No cluster, no network, no argocd.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

# ── 1. the parser, pure ─────────────────────────────────────────────────────────────────────────
# A copy of the shipped `case` rather than a source, because the shipped one is inline in a
# die-path. If they drift this still pins the CONTRACT, and the drift surfaces as a live failure of
# section 2, which drives the shipped path end to end.
parse() {
  local hp h p
  hp="$(printf '%s' "$1" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##')"
  case "$hp" in
    \[*\]:*) h="${hp%]:*}]"; p="${hp##*]:}" ;;
    \[*\])   h="$hp";        p=443 ;;
    *:*:*)   h="$hp";        p=443 ;;
    *:*)     h="${hp%:*}";   p="${hp##*:}" ;;
    *)       h="$hp";        p=443 ;;
  esac
  case "$p" in ''|*[!0-9]*) p=443 ;; esac
  printf '%s|%s' "$h" "$p"
}
echo "== 1. host:port parser (7 of these 12 were MEASURED broken before the fix) =="
while IFS= read -r line; do
  [ -n "$line" ] || continue
  in="${line%%|*}"; want="${line#*|}"
  got="$(parse "$in")"
  if [ "$got" = "$want" ]; then ok "parse $in -> $got"; else bad "parse $in -> $got (want $want)"; fi
done <<'CASES'
argocd-server|argocd-server|443
argocd.lab.test:443|argocd.lab.test|443
192.168.101.133:8443|192.168.101.133|8443
https://argocd.lab.test|argocd.lab.test|443
https://argocd.lab.test:443|argocd.lab.test|443
http://argocd.lab.test/|argocd.lab.test|443
argocd.lab.test/|argocd.lab.test|443
argocd.lab.test:|argocd.lab.test|443
[::1]:443|[::1]|443
::1|::1|443
fd00::1|fd00::1|443
[fd00::1]|[fd00::1]|443
CASES

# ── 2. rc -> arm, against a REAL endpoint ───────────────────────────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
  echo "  SKIP: no openssl — cannot mint an oracle"
  printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
D="$(mktemp -d)"; SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true; rm -rf "$D"; }
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/ca.key" -out "$D/ca.crt" -days 1 \
  -subj "/CN=Test ArgoCD CA" >/dev/null 2>&1
# The leaf shape that matters: DNS SANs only, NO IP SAN — what an ArgoCD self-signed cert carries,
# and the reason dialling the LoadBalancer IP can never verify however correct the CA is.
openssl req -newkey rsa:2048 -nodes -keyout "$D/l.key" -out "$D/l.csr" \
  -subj "/CN=argocd-server" >/dev/null 2>&1
printf 'subjectAltName=DNS:argocd-server,DNS:localhost\n' > "$D/ext"
openssl x509 -req -in "$D/l.csr" -CA "$D/ca.crt" -CAkey "$D/ca.key" -out "$D/l.crt" -days 1 \
  -extfile "$D/ext" >/dev/null 2>&1

# AN EPHEMERAL FREE PORT, then PROVE WE ARE TALKING TO OUR OWN SERVER.
#
# MEASURED 2026-08-18: this test failed with
#     FAIL  IP + correct CA -> rc 1 (want 3)
#     FAIL  the SAN probe returned nothing usable: ' DNS:vcsa.env1.lab.test'
# on a tree with NO relevant change — including on unmodified origin/main. The cause was a stray
# TLS server left behind by an earlier session, squatting on the hardcoded 18443 and presenting a
# `CN=vcsa.env1.lab.test` certificate. The failure mode is the dangerous one: `s_server`'s bind
# failure went to /dev/null, and the readiness loop below SUCCEEDED — against the squatter. So the
# whole suite then measured SOMEONE ELSE'S SERVER and reported it as a product defect.
#
# Two independent fixes, because either alone is insufficient:
#   1. Scan a DISJOINT band for a free port. B180(f) is explicit that `test-fetch-ca-pin.sh:47`
#      scans `seq 18443 18470` starting on the exact literal this file used to hardcode, that both
#      suites are in TEST_FAST, and that serial order hides the contention only by luck of $(sort) —
#      so this one takes 18471-18499 and they can never collide BY CONSTRUCTION. (My first draft of
#      this fix scanned 18443-18470, i.e. straight into the collision the row warns about.)
#      MEASURED: ip_local_port_range is 32768-60999 here, so 18471-18499 also stays clear of the
#      ephemeral range — B180(g)'s objection to `pick_port` (it moves the listener INTO that range)
#      does not apply to a fixed low band.
#      This half only lowers probability; it is NOT the primary fix, per B180(g).
#   2. ASSERT THE SERVED CERT IS THE ONE WE MINTED. This is the load-bearing half: it closes the
#      TOCTOU window and covers B180(d) — `openssl s_server -accept` fails loudly on a busy port
#      but into /dev/null, `SRV=$!` then holds a DEAD PID, and the readiness loop falls through. A
#      `kill -0 "$SRV"` liveness check would catch the dead-PID case only; asserting the CERT
#      catches that AND the live-but-foreign case, in one check.
#      It exits NON-ZERO, per B180(e): the sibling records that an `exit 0`/SKIP here once produced
#      ZERO assertions read as a pass. This is a harness fault, not a product fault, so it says so —
#      but it must never be silent and must never be green.
PORT="${TEST_ADDR_VERDICT_PORT:-}"
if [ -z "$PORT" ]; then
  for p in $(seq 18471 18499); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
  done
fi
[ -n "$PORT" ] || { printf '  INCONCLUSIVE  no free port in 18471-18499 (harness fault, not a product fault)\n'; exit 1; }
openssl s_server -cert "$D/l.crt" -key "$D/l.key" -accept "$PORT" -quiet >/dev/null 2>&1 &
SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '' | timeout 2 openssl s_client -connect "127.0.0.1:${PORT}" </dev/null >/dev/null 2>&1 && break
  sleep 1
done
# THE IDENTITY GATE — compare the FINGERPRINT, not the subject.
#
# ⚠️ A SUBSTRING TEST ON `CN=argocd-server` IS DEFEATED BY THE MOST LIKELY SQUATTER OF ALL: an
# ORPHANED `s_server` FROM A PREVIOUSLY-KILLED RUN OF THIS VERY TEST, which mints exactly that CN.
# Its `trap cleanup EXIT` does NOT fire on SIGKILL, and this repo has recorded both kill-by-PID
# orphaning detached children and a harness being killed mid-run. MEASURED 2026-08-18: an impostor
# with a DIFFERENT key but `subject=CN = argocd-server` passes a substring gate and reproduces the
# original incident shape byte-for-byte (`rc 1 (want 3)` + "returned nothing usable"), so the gate
# would have been blind to precisely its own leftovers. The fingerprint is key-bound and cannot be
# forged by re-using the name.
# `</dev/null` alone — a `printf '' |` in front of it is dead (SC2259: the redirect overrides the
# pipe), and shellcheck treats that as an ERROR, not a warning.
_srv_pem="$(timeout 5 openssl s_client -connect "127.0.0.1:${PORT}" </dev/null 2>/dev/null || true)"
_srv_subject="$(printf '%s' "$_srv_pem" | openssl x509 -noout -subject 2>/dev/null || true)"
_srv_fp="$(printf '%s' "$_srv_pem" | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true)"
_our_fp="$(openssl x509 -in "$D/l.crt" -noout -fingerprint -sha256 2>/dev/null || true)"
# The subject stays in the MESSAGE — it is what names the squatter for a human — but the DECISION
# is the fingerprint. An empty _our_fp must never compare equal to an empty _srv_fp.
if [ -n "$_our_fp" ] && [ "$_srv_fp" = "$_our_fp" ]; then
  :
else
  { printf '  INCONCLUSIVE  port %s is serving a certificate we did NOT mint: %s\n' "$PORT" "${_srv_subject:-<none>}"
    printf '        served fp: %s\n        ours     : %s\n' "${_srv_fp:-<none>}" "${_our_fp:-<none>}"
    printf '        Our s_server could not bind, so every assertion below would measure that\n'
    printf '        server instead of ours. Find the squatter with: ss -ltnp | grep :%s\n' "$PORT"
    kill "$SRV" 2>/dev/null || true
    exit 1; }
fi

echo "== 2. ca_verifies_endpoint rc -> the arm the operator reads =="
probe() { local rc=0; ca_verifies_endpoint "$1" "$PORT" "$2" || rc=$?; printf '%s' "$rc"; }
r="$(probe 127.0.0.1 "$D/ca.crt")"
if [ "$r" = 3 ]; then ok "IP + correct CA -> rc 3 (chain OK, NAME wrong: do NOT re-fetch the CA)"
else bad "IP + correct CA -> rc $r (want 3)"; fi
r="$(probe localhost "$D/ca.crt")"
if [ "$r" = 0 ]; then ok "a SAN name + correct CA -> rc 0 (verifies)"
else bad "SAN name + correct CA -> rc $r (want 0)"; fi
r="$(probe localhost "$D/absent.crt")"
if [ "$r" = 5 ]; then ok "a SAN name + ABSENT CA -> rc 5 (anchor unusable, not a name fault)"
else bad "SAN name + absent CA -> rc $r (want 5)"; fi

# ── 3. the SAN block must be DERIVED, and SILENT on rc 0 ────────────────────────────────────────
echo "== 3. the SAN block is derived, and silent on rc 0 =="
sans="$(printf '' | timeout 10 openssl s_client -connect "localhost:${PORT}" -servername localhost 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -s ' ' || true)"
if printf '%s' "$sans" | grep -q 'DNS:argocd-server'; then
  ok "the SAN probe reads the real names"
else
  bad "the SAN probe returned nothing usable: '$sans'"
fi
# Pinned by SHAPE, not by prose, so a refactor that drops the guard fails HERE.
# shellcheck disable=SC2016  # the un-expanded $_cv is the POINT: this greps SOURCE, not a value.
if grep -q 'if \[ "\$_cv" -ne 0 \]; then' "${SCRIPT_DIR}/70-configure-argocd.sh"; then
  ok "70-configure-argocd.sh still suppresses the SAN block on rc 0"
else
  bad "the rc-0 suppression guard is GONE — the SAN advice will fire on an address that verified"
fi
if grep -q "grep -q 'IP Address'" "${SCRIPT_DIR}/70-configure-argocd.sh"; then
  ok "the NO-IP-SAN sentence is derived from the actual SANs"
else
  bad "the NO-IP-SAN sentence is not derived — it can contradict the list it prints"
fi

# ⚠️ SECTION 1 TESTS A COPY, SO IT CANNOT SEE A REGRESSION IN THE SHIPPED PARSER. That is the same
# blindness an adversary measured in test-argocd-classify (10/10 on both trees across a 63-line
# change). Stated, not hidden — and narrowed here to the cheapest thing that IS checkable offline:
# that the shipped file still carries the scheme-strip and the IPv6 arms at all. Deletion fails
# here; a subtly WRONG rewrite still would not, and closing that needs the die-path refactored so
# the parser is a callable function (filed, not done).
_shipped="${SCRIPT_DIR}/70-configure-argocd.sh"
if grep -q "s#\^\[a-zA-Z\]\[a-zA-Z0-9+.-\]\*://##" "$_shipped"; then
  ok "the shipped parser still strips a scheme (creds.sh:76 shows one is anticipated)"
else
  bad "the shipped scheme-strip is GONE — 'https://h' parses to host=https, port=//h"
fi
if grep -q '\*:\*:\*)' "$_shipped"; then
  ok "the shipped parser still has its bare-IPv6 arm"
else
  bad "the bare-IPv6 arm is GONE — 'fd00::1' parses to host=fd00:, port=1"
fi

printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
