#!/usr/bin/env bash
# Offline test for argocd_endpoint_probe / _answers / _last  (B486/F7).
#
# WHY THIS EXISTS: THREE sites hand-rolled this probe and disagreed on two axes, and the
# disagreement shipped unnoticed because none of them was a FUNCTION and so none had a test.
# Extraction is what made it testable; this is the test.
#
# It runs against a LOCAL plain-HTTP stub via ARGOCD_SESSION_SCHEME -- the same hook the session
# test uses -- so it needs no cluster, no TLS material and no network.
#
# ⚠️ NOTHING that sets state is called inside `$( )`. A command substitution is a SUBSHELL, so
# neither the probe's globals nor the stub's PID survive it. Writing this test bit me TWICE that
# way (`ARGOCD_ENDPOINT_HTTP: unbound variable`, then `STUB_PID: unbound variable`), which is the
# same trap that makes the diag FILE necessary in the first place. Results come back via files
# and globals, never via captured stdout.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/lib/argocd.sh" 2>/dev/null || { echo "cannot source lib/argocd.sh"; exit 1; }

pass=0; fail=0; STUB_PID=""; PORT=""
ok()    { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()   { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }

export ARGOCD_SESSION_SCHEME=http
ARGOCD_ENDPOINT_DIAG="$(mktemp)"; export ARGOCD_ENDPOINT_DIAG
STUB_OUT="$(mktemp)"
cleanup() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; rm -f "$ARGOCD_ENDPOINT_DIAG" "$STUB_OUT"; }
trap cleanup EXIT

cat > "$STUB_OUT.py" <<'PY'
import sys, http.server
code = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(code); self.send_header('Content-Length','0'); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY

start_stub() {  # $1 = status code. Sets STUB_PID and PORT in THIS shell -- never call it in $( ).
  : > "$STUB_OUT"
  python3 "$STUB_OUT.py" "$1" > "$STUB_OUT" 2>/dev/null &
  STUB_PID=$!
  PORT=""
  local i
  for i in $(seq 1 60); do
    PORT="$(cat "$STUB_OUT" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$PORT" ] && break
    sleep 0.1
  done
}
stop_stub() { [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; STUB_PID=""; }

echo "case 1: a LISTENING stub answering 200"
start_stub 200
case "$PORT" in ''|*[!0-9]*) bad "stub never reported a port"; PORT="" ;; esac
if [ -n "$PORT" ]; then
  _so="$(mktemp)"
  argocd_endpoint_probe "127.0.0.1:${PORT}" 3 > "$_so"
  check "STDOUT IS EMPTY (it is not the return value)" "$(cat "$_so")" ""
  rm -f "$_so"
  check "http recorded" "${ARGOCD_ENDPOINT_HTTP:-}" "200"
  check "rc recorded"   "${ARGOCD_ENDPOINT_RC:-}"   "0"
  check "_last echoes the PAIR, not a boolean" "$(argocd_endpoint_last)" "rc=0 http=200"
  if argocd_endpoint_answers "127.0.0.1:${PORT}" 3; then ok "_answers is TRUE"; else bad "_answers said no to a listening server"; fi
fi
stop_stub

echo "case 2: ANY status counts — a 404 is still LISTENING"
# The axis argocd-auth-check.sh:144 records: requiring 200 false-failed a healthy ArgoCD served
# under --rootpath, and an L7 LB answering 403/404 unauthenticated does the same.
start_stub 404
if [ -n "$PORT" ]; then
  if argocd_endpoint_answers "127.0.0.1:${PORT}" 3; then ok "404 counts as answering"; else bad "404 was treated as not-listening"; fi
  check "http is the real status" "${ARGOCD_ENDPOINT_HTTP:-}" "404"
fi
stop_stub

echo "case 3: NOTHING listening — refused, and the CAUSE is preserved"
if argocd_endpoint_answers "127.0.0.1:1" 3; then bad "_answers said yes with nothing listening"; else ok "_answers is FALSE"; fi
check "http is 000" "${ARGOCD_ENDPOINT_HTTP:-}" "000"
check "rc is 7 (CONNECTION REFUSED), not collapsed to a boolean" "${ARGOCD_ENDPOINT_RC:-}" "7"
_exp="$(argocd_session_explain 7 000 2>/dev/null || true)"
case "$_exp" in *REFUSED*) ok "argocd_session_explain names the cause from the pair" ;;
                *)         bad "explain did not name refused (got: ${_exp:-<empty>})" ;; esac

echo "case 3b: the DIAG FILE survives a subshell, which the globals cannot"
# The whole reason the pair is written to a file as well as to globals.
( argocd_endpoint_probe "127.0.0.1:1" 3 ) >/dev/null 2>&1
check "the pair is readable after a subshell call" "$(argocd_endpoint_last)" "rc=7 http=000"

echo "case 4: no hand-rolled poller survives at the three call sites"
for f in argocd-auth-check.sh 91-e2e-tenant-mechanism.sh 09-argocd-address.sh; do
  n="$(grep -cE 'curl .*healthz' "${SCRIPT_DIR}/${f}" 2>/dev/null || true)"
  check "${f} hand-rolls no /healthz curl" "${n:-0}" "0"
done
n="$(grep -cE '^argocd_endpoint_(probe|answers|last)\(\)' "${SCRIPT_DIR}/lib/argocd.sh" || true)"
check "the probe has exactly ONE home (3 functions in lib/argocd.sh)" "${n:-0}" "3"

printf '\nargocd-endpoint-probe: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
