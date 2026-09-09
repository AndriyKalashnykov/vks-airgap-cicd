#!/usr/bin/env bash
# ci-tier: fast
# Offline RED/GREEN for env-validate's Harbor AUTH probe transport status (B194 class, found by the
# B721 implementation round).
#
# THE BUG THIS PINS. The probe reads `curl -w '%{http_code}'`. On a response TRUNCATED mid-body
# curl PRINTS the status it already saw and EXITS NON-ZERO — so discarding the rc reports a status
# that was never delivered. MEASURED against a threaded oracle sending `200 OK` headers then
# hanging (curl prints 200, exits 28):
#
#     `|| echo 000`   -> 200000 -> the `*)` arm -> "inconclusive"                (accidentally safe)
#     rc DISCARDED    -> 200    -> the ACCEPTED arm -> "credentials accepted"    *** FALSE GREEN ***
#     rc PRESERVED    -> 000    -> the `*)` arm -> "inconclusive"                (correct)
#
# ⚠️ THE CATEGORY IS ADJUDICATED IN THIS REPO, IN WRITING. `97-verify-ingress-rendered.sh` records
# it: a probe asking "is this host SERVING?" must collapse a truncated response to 000, while one
# asking "is the route RENDERED?" keeps the code — "same primitive, opposite correct normalisation".
# env-validate's auth probe is RULE ZERO-A0's answer to "does my Harbor credential WORK?", i.e. the
# FIRST kind. A cosmetic fix that copied the RENDERED normalisation into it is what this pins.
#
# ⚠️ AND THE OPPOSITE DIRECTION IS ASSERTED TOO: a truncated 401 must NOT become a hard FAILURE.
# Discarding the rc made env-validate exit 1 on a rejection that never completed — a false RED in
# the same change as the false GREEN.
#
# Tests the SHELL FORM, not the whole gate: env_validate needs a populated .env and a reachable
# Harbor, and the defect lives entirely in how the probe normalises curl's two outputs.
set -uo pipefail
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/oracle.py" <<'PY'
import socket, threading, sys
status = sys.argv[1].encode()
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(8)
print(srv.getsockname()[1], flush=True)
def handle(c):
    try:
        c.recv(4096)
        # headers + a Content-Length we never satisfy, then hang: a TRUNCATED response
        c.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Length: 1000\r\n\r\nxx")
        threading.Event().wait(120)
    except Exception:
        pass
while True:
    c, _ = srv.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
PY

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
      else f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; fi; }

probe() {  # probe <status> -> the normalised code the SHIPPED form produces
  local st="$1" port pid code arc
  python3 "$T/oracle.py" "$st" > "$T/port" 2>&1 & pid=$!
  sleep 1.5
  port="$(head -1 "$T/port")"
  # ⚠️ THE SHIPPED FORM, copied verbatim from 02-env.sh. `&& arc=0 || arc=$?` and NOT `; arc=$?` —
  # the latter reads the ASSIGNMENT's status, which is always 0.
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${port}/x" 2>/dev/null)" && arc=0 || arc=$?
  [ "$arc" -eq 0 ] || code=000
  case "${code:-}" in ''|*[!0-9]*) code=000 ;; esac
  # kill by PID: `pkill -f oracle.py` SELF-MATCHES this script's own command line (measured: it
  # killed the invoking shell with 144 while writing this file).
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  printf '%s' "$code"
}

arm() { case "$1" in 200|403|412) printf 'accepted' ;; 401) printf 'rejected' ;; *) printf 'inconclusive' ;; esac; }

c="$(probe 200)"
ck "truncated 200 -> normalised to 000"        "$c" "000"
ck "  ...so the arm is INCONCLUSIVE, not accepted" "$(arm "$c")" "inconclusive"

c="$(probe 401)"
ck "truncated 401 -> normalised to 000"        "$c" "000"
ck "  ...so it does NOT hard-fail env-validate"    "$(arm "$c")" "inconclusive"

# THE CONTROL THAT MUST STILL PASS: a COMPLETE response keeps its real status, or this normalisation
# would collapse every probe to 000 and the gate would be vacuous in the other direction.
python3 -c "
import http.server, threading, socket
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s): s.send_response(200); s.send_header('Content-Length','2'); s.end_headers(); s.wfile.write(b'ok')
    def log_message(s,*a): pass
srv=http.server.HTTPServer(('127.0.0.1',0),H)
print(srv.server_port, flush=True)
srv.serve_forever()" > "$T/port2" 2>&1 & OK_PID=$!
sleep 1.5; PORT2="$(head -1 "$T/port2")"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT2}/x" 2>/dev/null)" && arc=0 || arc=$?
[ "$arc" -eq 0 ] || code=000
kill "$OK_PID" 2>/dev/null; wait "$OK_PID" 2>/dev/null
ck "a COMPLETE 200 still reads 200 (the control)" "$code" "200"
ck "  ...and its arm is ACCEPTED"                 "$(arm "$code")" "accepted"

# ---- THE DRIFT GUARD. Everything above tests the FORM, replicated here; if 02-env.sh stops using
#      that form the behavioural cases still pass. Assert the product carries it. Keyed on the
#      USAGE SHAPE (the rc test that forces 000), never on a variable name, because a name also
#      appears in this file's own prose.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/02-env.sh"
# `$arc` here is a LITERAL being searched for in another file's source, not a variable to expand --
# single quotes are required. shellcheck cannot know that, hence the scoped disable.
# shellcheck disable=SC2016
_drift="$(grep -cE '\[ "\$arc" -eq 0 \] \|\| acode=000' "$SRC")"
ck "02-env.sh preserves the transport status" "$_drift" "1"
ck "02-env.sh no longer appends a second 000" \
   "$(grep -c "users/current\" 2>/dev/null || echo 000)" "$SRC")" "0"

printf '\n  %s passed, %s failed\n' "$p" "$f"
[ "$f" -eq 0 ] || exit 1
