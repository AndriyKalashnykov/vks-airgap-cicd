#!/usr/bin/env bash
# ci-tier: fast — offline; a throwaway HTTP responder on 127.0.0.1, no cluster, no network.
#
# B528: `make creds` printed `serving` for a route whose BACKEND was dead. MEASURED on the live lab
# with every app pod in ImagePullBackOff: javawebapp.vks.local answered HTTP 503 and the report said
# `serving`. The `_ing_live` TCP probe is shared by every ingress-backed row and cannot see a
# backend, but `serving` is a claim ABOUT THE BACKEND — the reader clicks a URL the report promised
# works and gets an error page.
#
# THE POINT OF THESE CASES IS DISCRIMINATION, not "does it say serving". A verdict that cannot tell
# 503 from 404 sends the reader to the wrong place: 503 means "run the pipeline" (the normal state
# after install-all, which builds no app image — B529), while 404 means the ingress does not know
# this host, i.e. a rendering/attach fault.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extract by function name up to its closing brace at column 0 — deliberately NOT a line range, so a
# shifted file cannot silently yield a fragment. An empty extraction is a HARD FAILURE: a test that
# passes over an empty function is worse than no test.
_fn="$(awk '/^_reach_ingress\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "${REPO_ROOT}/scripts/creds.sh")"
case "$_fn" in
  *"printf 'serving'"*) : ;;
  *) echo "FATAL: could not extract _reach_ingress from scripts/creds.sh — renamed or reshaped."
     echo "       Fix the extraction; do NOT let this test pass over an empty function."; exit 1 ;;
esac

T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null' EXIT

# A responder that returns whatever status the request's Host asks for, so one server covers every
# case and the test never depends on a real ingress.
cat > "$T/srv.py" <<'PY'
import http.server, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get('Host', '')
        code = 200
        for tok, c in (('c503', 503), ('c404', 404), ('c302', 302), ('c418', 418)):
            if tok in host: code = c
        self.send_response(code); self.send_header('Content-Length', '0'); self.end_headers()
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    print(s.server_address[1], flush=True)
    s.serve_forever()
PY
python3 "$T/srv.py" > "$T/port" 2>/dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(cat "$T/port")"
[ -n "$PORT" ] || { echo "FATAL: the responder never reported a port"; exit 1; }

# ⚠️ THE DNS ARM RUNS BEFORE THE HTTP ARM, and none of these test hosts resolve — so without this
# every HTTP case returns `no DNS here` and the suite measures nothing. (It did: 6 of 10 failed that
# way on the first run. The instrument, not the product.) A fake `getent` isolates the arm under
# test; the DNS arm keeps its own case below, with the stub removed from PATH.
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/getent"; chmod +x "$T/bin/getent"
_REAL_PATH="$PATH"
export PATH="$T/bin:$PATH"

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
      else f=$((f+1)); printf '  FAIL  %s (got=%q want=%q)\n' "$1" "$2" "$3"; fi; }

probe() { # probe <host> ; runs the REAL extracted function
  ( eval "$_fn"
    _ing="127.0.0.1:${PORT}"; _ing_live=1
    CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress "$1" )
}

# Positive control FIRST: if a healthy host does not read `serving`, every case below is meaningless.
ck "control: a 200 backend reads serving"        "$(probe ok.local)"   "serving"
# The discriminating cases — this is the defect.
ck "503 -> no backend (NOT serving: the B528 defect)" "$(probe c503.local)" "no backend"
ck "404 -> no route (a rendering fault, not a dead pod)" "$(probe c404.local)" "no route"
ck "302 -> serving (a redirect IS a working route)"   "$(probe c302.local)" "serving"
ck "an unexpected status is REPORTED, not swallowed"  "$(probe c418.local)" "HTTP 418"

# The short-circuits must still win, or the probe would run where the report promised it would not.
ck "CREDS_NO_PROBE=1 short-circuits"  \
   "$(eval "$_fn"; CREDS_NO_PROBE=1 _ing=1.2.3.4 _ing_live=1 _reach_ingress h.local)" "not probed"
ck "no ingress -> no ingress"         \
   "$(eval "$_fn"; CREDS_NO_PROBE=0 _ing= _ing_live=1 _reach_ingress h.local)"        "no ingress"
ck "LB not live -> silent (never a per-host verdict)" \
   "$(eval "$_fn"; CREDS_NO_PROBE=0 _ing=1.2.3.4 _ing_live=0 _reach_ingress h.local)" "silent"
# An empty host cannot name a vhost; sending `Host: ` would earn a 404 and INVENT a "no route".
ck "empty host -> LB up (does not invent a route fault)" \
   "$(probe '')" "LB up"
# Nothing answering at all is `silent`, not a fabricated status. Port 1 is closed by construction.
ck "dead endpoint -> silent" \
   "$(eval "$_fn"; _ing=127.0.0.1:1; _ing_live=1; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=2 _reach_ingress h.local)" "silent"

# The DNS arm must still win when a host genuinely does not resolve — with the stub OFF PATH.
ck "unresolvable host -> no DNS here (the arm still short-circuits)" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; _ing="127.0.0.1:'"$PORT"'"; _ing_live=1; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress definitely-not-a-real-host.invalid' _ "$_fn")" \
   "no DNS here"

printf '\ntest-creds-reach-ingress: %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
