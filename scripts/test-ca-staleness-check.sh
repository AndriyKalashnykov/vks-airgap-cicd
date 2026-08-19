#!/usr/bin/env bash
# ci-tier: slow — asserts a real wait elapses against a dead endpoint (~31s)
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
# The arms + the token live in lib/tls.sh now (ca_status_report moved there so the preflight stops
# SOURCING an executable and calling load_env twice). The assertions follow the code — the last
# time they did not, one of them passed VACUOUSLY by grepping a file the block had left.
CS="${REPO_ROOT}/scripts/lib/tls.sh"
CS_MAIN="${REPO_ROOT}/scripts/29-ca-status.sh"   # the executable half: the summary + the token
blk="$(awk '/case "\$rc" in/,/esac/' "$CS")"
[ -n "$blk" ] || { echo "FAILED to extract the case block from $CS — aborting rather than testing nothing"; exit 1; }
# ALL SIX documented verdicts (lib/tls.sh:82-84,178,185 -> 0 1 2 3 4 5). The first version of
# this loop listed 0 1 2 5 and so ASSERTED THE ABSENCE OF NOTHING for 3 and 4 — which were
# genuinely unhandled, fell through to the catch-all, and exited 0. An enumerated list that
# rotted at birth. rc=3 is the modal tenant shape (IP in HARBOR_URL vs a DNS-only SAN).
for arm in 0 1 2 3 4 5; do
  if printf '%s' "$blk" | grep -qE "^      ${arm}\)"; then ok "29-ca-status handles rc=${arm}"
  else bad "29-ca-status handles rc=${arm}" "no case arm — it would fall through to the catch-all"; fi
done

# rc=2 must NOT increment the stale count. This assertion was VACUOUS in my first version: it
# grepped a file the block had been moved out of, so "no match" read as "does not count it".
# Anchor it to the arm that actually exists, and prove the arm that DOES count is rc=1.
# Deliberate: this greps for the LITERAL text 'stale=$((stale' in the shipped source. Expanding it
# here would search for this test's own (empty) variable instead.
# shellcheck disable=SC2016
if printf '%s' "$blk" | awk '/^      2\)/,/;;/' | grep -q 'stale=\$((stale'; then
  bad "rc=2 does NOT count as stale" "the unreachable arm increments the count — a powered-off lab would fail the preflight"
else
  ok "rc=2 does NOT count as stale"
fi
# Deliberate: this greps for the LITERAL text 'stale=$((stale' in the shipped source. Expanding it
# here would search for this test's own (empty) variable instead.
# shellcheck disable=SC2016
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

# THE TOKEN. The runbooks quote `CA-STATUS: ALL-MATCH` as their Expect, and walk-doc passes a block
# when ANY quoted literal matches — so the literal MUST be unreachable from every failure arm. An
# earlier Expect quoted "Harbor CA", which every per-certificate line begins with, including the
# failure ones: the step added to catch the failure scored GREEN on it.
if grep -q 'CA-STATUS: ALL-MATCH' "$CS_MAIN"; then ok "the success token exists"
else bad "the success token exists" "the runbooks quote CA-STATUS: ALL-MATCH"; fi
# Find the CONDITION GOVERNING the token, not a fixed window above it. A 3-line window was the
# first version and it broke the moment the token gained an explanatory comment — a positional
# assertion about source layout, masquerading as an assertion about behaviour.
tokgate="$(awk '/^ *(el)?if /{c=$0} /CA-STATUS: ALL-MATCH/{print c; exit}' "$CS_MAIN")"
if printf '%s' "$tokgate" | grep -q 'CA_STATUS_MATCHED' && printf '%s' "$tokgate" | grep -q 'CA_STATUS_CHECKED'; then
  ok "the token is gated on matched == checked (no skip, no empty run, can reach it)"
else
  bad "the token is gated on matched == checked" "governing branch was: ${tokgate:-<none found>}"
fi

# THE HOST/PORT PARSER. Extracted from the shipped script, never transcribed. Two of these shapes
# produced a FALSE SKIP ("did not answer") against a healthy endpoint before it existed.
eval "$(sed -n '/^  _ca_hostport()/,/^  }/p' "$CS" | sed 's/^  //')"
if ! declare -F _ca_hostport >/dev/null; then
  bad "_ca_hostport extracted from the shipped script" "could not extract it — testing nothing"
else
  while IFS='|' read -r inp want; do
    [ -n "$inp" ] || continue
    got="$(_ca_hostport "$inp")"
    if [ "$got" = "$want" ]; then ok "hostport: $inp -> $want"
    else bad "hostport: $inp" "wanted '$want', got '$got'"; fi
  done <<'HP'
harbor.example|harbor.example|443
https://harbor.example|harbor.example|443
harbor.example:8443|harbor.example|8443
https://harbor.example:8443/|harbor.example|8443
[2001:db8::1]:8443|[2001:db8::1]|8443
HP
fi

# STRICT MODE. A missing CA is a WARNING for bare `lab-preflight` (scenario-1 §7 legitimately runs
# before §8 saves it) and a PROBLEM for the `preflight` that gates install-all — where nothing else
# catches it, because the two neighbouring probes abstain (curl -sk skips verification;
# harbor_auth_report returns 0 when HARBOR_CA_FILE is unset) and preflight runs env-check, not
# env-validate. Both directions asserted: an arm that cannot say NO is not a gate, and an arm that
# always says NO breaks the documented §7 order.
if grep -q 'CA_STATUS_STRICT' "$CS"; then ok "29-ca-status honours CA_STATUS_STRICT"
else bad "29-ca-status honours CA_STATUS_STRICT" "a missing CA cannot fail the install-all preflight"; fi
if grep -qE '^preflight: export CA_STATUS_STRICT' "${REPO_ROOT}/Makefile"; then
  ok "the preflight target EXPORTS it (wiring, not just a flag nothing sets)"
else
  bad "the preflight target exports CA_STATUS_STRICT" "the strict arm exists but nothing turns it on"
fi


# ── B166: the report must not be BLIND to the Supervisor CA in the SHIPPED configuration ──────
# ca_status_report builds its Supervisor pair only when VKS_CA_CERT_FILE is non-empty, and
# .env.example ships that COMMENTED (docs/scenario-1.md: "Set it only if you moved it"). Without a
# vks_ca_default call first, BOTH entry points examine ZERO pairs and report "nothing to check".
#
# ⚠️ THE FIRST VERSION OF THESE CASES WAS A FAKE-GREEN, and it is worth stating how, because the
# numbers looked convincing: the behavioural arms EXPORTED VkS_CA_CERT_FILE themselves, so they never
# called vks_ca_default at all. An implementation-round adversary measured that gutting the function
# to `return 0` left the arms byte-identical, and that vks_ca_default could be DELETED from tls.sh
# entirely with these cases still green. They pinned ca_status_report's `[ -n ... ]` conditional --
# a thing that was never in doubt -- while appearing to pin the fix.
#
# WIRING: require the call at a COMMAND POSITION and check EACH occurrence's own window. A bare-token
# grep passed `: vks_ca_default`, `false && vks_ca_default`, the token inside a log string, and the
# token inside an unused function (2 of 6 mutations caught). A single concatenated window also passed
# a file with one guarded and one UNGUARDED ca_status_report.
for _f in "${REPO_ROOT}/scripts/29-ca-status.sh" "${REPO_ROOT}/scripts/24-lab-preflight.sh"; do
  _n="$(basename "$_f")"; _bad=0; _seen=0
  while IFS=: read -r _ln _; do
    [ -n "${_ln:-}" ] || continue
    _seen=$((_seen + 1))
    _lo=$(( _ln - 12 )); [ "$_lo" -lt 1 ] && _lo=1
    if ! sed -n "${_lo},${_ln}p" "$_f" | sed 's/#.*//' \
         | grep -qE '^[[:space:]]*vks_ca_default[[:space:]]*$'; then
      _bad=$((_bad + 1))
    fi
  done <<EOF
$(grep -n 'ca_status_report' "$_f" | sed 's/#.*//' | grep 'ca_status_report' || true)
EOF
  if [ "$_seen" -eq 0 ]; then
    bad "${_n}: found NO ca_status_report call" "the test cannot be measuring what it claims"
  elif [ "$_bad" -eq 0 ]; then
    ok "${_n}: every ca_status_report (${_seen}) is preceded by a real vks_ca_default call"
  else
    bad "${_n}: ${_bad} of ${_seen} ca_status_report calls lack a preceding vks_ca_default" \
        "that entry point examines ZERO pairs on a box that never set VKS_CA_CERT_FILE"
  fi
done

# BEHAVIOURAL — both arms CALL vks_ca_default; the only difference is whether the fixture REPO_ROOT
# contains the default CA file. If this ever stops discriminating, the fix has become inert.
# Capture the REAL library paths BEFORE the arms override REPO_ROOT to a fixture. Without this the
# arms would try to source the libs from the fixture root and silently source nothing, so both would
# return 0 and arm A would pass for entirely the wrong reason.
LIB_OS="${REPO_ROOT}/scripts/lib/os.sh"
LIB_TLS="${REPO_ROOT}/scripts/lib/tls.sh"
_b166="$(mktemp -d)"
mkdir -p "$_b166/withca/secrets" "$_b166/noca/secrets"
if openssl req -x509 -newkey rsa:2048 -nodes -keyout "$_b166/k" \
     -out "$_b166/withca/secrets/supervisor-ca.crt" -subj "/CN=b166" -days 1 >/dev/null 2>&1; then
  _arm() {  # _arm <fixture-root> -> count of Supervisor pairs examined
    ( set +e
      export REPO_ROOT="$1" SUPERVISOR_HOST="sup.invalid" CA_VERIFY_TIMEOUT=2
      unset VKS_CA_CERT_FILE HARBOR_URL HARBOR_CA_FILE
      # shellcheck source=scripts/lib/os.sh
      . "${LIB_OS}"  >/dev/null 2>&1
      # shellcheck source=scripts/lib/tls.sh
      . "${LIB_TLS}" >/dev/null 2>&1
      vks_ca_default >/dev/null 2>&1     # THE CALL UNDER TEST
      ca_status_report 2>&1 ) | grep -ciE 'Supervisor CA' || true
  }
  _a="$(_arm "$_b166/noca")"; _b="$(_arm "$_b166/withca")"
  if [ "${_a:-0}" -eq 0 ]; then
    ok "RED-proof: vks_ca_default finds no default CA -> NO Supervisor pair examined"
  else
    bad "RED-proof: no-CA fixture must examine 0 pairs" "got ${_a}"
  fi
  if [ "${_b:-0}" -ge 1 ]; then
    ok "RED-proof: vks_ca_default resolves the default CA -> the Supervisor pair IS examined"
  else
    bad "RED-proof: with-CA fixture must examine >=1 pair" \
        "got ${_b} — vks_ca_default is INERT; the production fix would not restore coverage"
  fi
else
  # UPPERCASE `SKIP` is the marker run-test-set.sh's skip detector anchors on
  # (`^[[:space:]]*SKIP[:[:space:]]`, case-sensitive). Lowercase here meant this skip —
  # of the B166 RED-PROOF arms — was invisible in the suite summary. Found by an adversary
  # measuring the detector's boundary, not by the detector.
  printf 'SKIP  B166 behavioural arms (openssl unavailable)\n'
fi
rm -rf "$_b166"

printf '\ntest-ca-staleness-check: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-ca-staleness-check: OK\n'
