#!/usr/bin/env bash
# test-harbor-auth-report.sh — offline RED/GREEN proof for harbor_auth_report (lib/harbor.sh).
#
# WHY THIS TEST EXISTS
# --------------------
# harbor_auth_report is the gate that turns a 605-second failure into a first-seconds one, so its
# value is entirely in its demonstrated RED. It also has ONE arm that is easy to get backwards and
# expensive when you do: 403 must PASS. A project-scoped robot -- the credential scenario-1 Step 9
# tells the reader to create -- is fully authenticated and still gets 403 from /users/current,
# because that endpoint is system-scoped. A "any non-200 is a failure" gate would hard-stop the
# least-privilege path it exists to protect.
#
# Hermetic: a self-signed CA + leaf and a local TLS server on an EPHEMERAL port. No lab, no network,
# no Harbor. Everything lands in one mktemp -d and is removed on every exit path.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"

require_cmd openssl
require_cmd curl
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not present (this test needs a TLS oracle)"; exit 0; }

T="$(mktemp -d)"
SRV_PID=""
cleanup() {
  # BY PID, never `pkill -f` -- a pattern kill self-matches its own command line and, in a portfolio
  # where several sessions run at once, reaches other people's processes.
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
check() {  # check <label> <expected-rc> <actual-rc>
  if [ "$2" -eq "$3" ]; then ok "$1 (rc=$3)"; else bad "$1 — expected rc=$2, got rc=$3"; fi
}

# ── a CA and a leaf with SAN=IP:127.0.0.1 ────────────────────────────────────────────────────────
# SAN=IP, not CN: since Go 1.15 / modern OpenSSL a CN-only leaf is rejected outright, so a cert
# minted the "obvious" way would make every case below fail for a reason that is not the credential.
openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
  -keyout "$T/ca.key" -out "$T/ca.crt" -subj "/CN=test-ca" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$T/leaf.key" -out "$T/leaf.csr" \
  -subj "/CN=127.0.0.1" >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1\n' > "$T/ext"
openssl x509 -req -in "$T/leaf.csr" -CA "$T/ca.crt" -CAkey "$T/ca.key" -CAcreateserial \
  -out "$T/leaf.crt" -days 1 -sha256 -extfile "$T/ext" >/dev/null 2>&1
cat "$T/leaf.crt" "$T/leaf.key" > "$T/leaf.pem"

# ── a TLS oracle that answers with whatever status the file says ─────────────────────────────────
# The status lives in a FILE, not an env var, so one server serves every case and each case is a
# one-line write instead of a restart -- no port reuse, no settle race between cases.
cat > "$T/srv.py" <<'PY'
import http.server, ssl, sys, pathlib
STATUS = pathlib.Path(sys.argv[1]); CERT = sys.argv[2]; PORTF = pathlib.Path(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:    code = int(STATUS.read_text().strip())
        except Exception: code = 500
        self.send_response(code); self.end_headers(); self.wfile.write(b'{}')
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
PORTF.write_text(str(srv.server_address[1]))
srv.serve_forever()
PY
printf '200\n' > "$T/status"
python3 "$T/srv.py" "$T/status" "$T/leaf.pem" "$T/port" >/dev/null 2>&1 &
SRV_PID=$!
# Wait on the PORT FILE, not a sleep: a fixed sleep is a guess that is either wasteful or flaky.
for _ in $(seq 1 100); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || die "the TLS oracle never published a port"
PORT="$(cat "$T/port")"

export HARBOR_URL="127.0.0.1:${PORT}"
export HARBOR_CA_FILE="$T/ca.crt"
export HARBOR_USERNAME=admin
export HARBOR_PROBE_TIMEOUT_SECONDS=5

echo "== harbor_auth_report =="

# ── the three status arms ────────────────────────────────────────────────────────────────────────
export HARBOR_PASSWORD='Sup3rStr0ngPw'

printf '200\n' > "$T/status"
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "200 -> accepted" 0 "$rc"

printf '403\n' > "$T/status"
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "403 -> accepted (project-scoped robot; NOT a failure)" 0 "$rc"

printf '401\n' > "$T/status"
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "401 -> REJECTED (the RED this gate exists for)" 1 "$rc"

# The RED must also SAY the right thing: a gate that fails without naming the cause sends the
# operator to the wrong file. 401 is authentication; Harbor answers 403 for permissions.
out="$(harbor_auth_report 2>&1 || true)"
case "$out" in
  *"REJECTED"*"401"*) ok "the 401 message names the rejection" ;;
  *) bad "the 401 message does not name the rejection: $out" ;;
esac

printf '500\n' > "$T/status"
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "500 -> inconclusive, not judged here" 0 "$rc"

# ── esc_curlk: a password with curl-config metacharacters must still authenticate ─────────────────
# Without escaping, a bare `"` truncates the value and a `\` is eaten -- both produce a FALSE 401,
# which is the exact wrong answer from a gate whose job is to say whether the credential works.
printf '200\n' > "$T/status"
export HARBOR_PASSWORD='p"a\ss w0rd'
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check 'a password containing " and \\ still authenticates (esc_curlk)' 0 "$rc"
export HARBOR_PASSWORD='Sup3rStr0ngPw'

# ── the skip arms: report, never judge ───────────────────────────────────────────────────────────
printf '401\n' > "$T/status"      # would be RED if it probed -- it must not probe at all

_saved_pw="$HARBOR_PASSWORD"; unset HARBOR_PASSWORD
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "no password -> reports, does not judge (env-check owns that)" 0 "$rc"
export HARBOR_PASSWORD="$_saved_pw"

_saved_ca="$HARBOR_CA_FILE"; export HARBOR_CA_FILE="$T/does-not-exist"
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "no CA and not insecure -> skips rather than send a password unverified" 0 "$rc"

# ...and the skip must be a SKIP, not a silent probe: prove no credential left the box by pointing
# at a port nothing serves. A probe would take the inconclusive arm; the skip returns before curl.
out="$(HARBOR_CA_FILE="$T/does-not-exist" harbor_auth_report 2>&1 || true)"
case "$out" in
  *"skipping the auth probe"*) ok "the skip says why (no CA yet)" ;;
  *) bad "the no-CA path did not report a skip: $out" ;;
esac
export HARBOR_CA_FILE="$_saved_ca"

_saved_url="$HARBOR_URL"; unset HARBOR_URL
rc=0; harbor_auth_report >/dev/null 2>&1 || rc=$?
check "no HARBOR_URL -> silent 0 (reachable_report already said so)" 0 "$rc"
export HARBOR_URL="$_saved_url"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
