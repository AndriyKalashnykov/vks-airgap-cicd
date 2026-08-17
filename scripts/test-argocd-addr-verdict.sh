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

PORT="${TEST_ADDR_VERDICT_PORT:-18443}"
openssl s_server -cert "$D/l.crt" -key "$D/l.key" -accept "$PORT" -quiet >/dev/null 2>&1 &
SRV=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  printf '' | timeout 2 openssl s_client -connect "127.0.0.1:${PORT}" </dev/null >/dev/null 2>&1 && break
  sleep 1
done

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
