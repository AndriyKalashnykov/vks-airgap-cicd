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
        for tok, c in (('c503', 503), ('c404', 404), ('c302', 302), ('c418', 418),
                       ('c401', 401), ('c403', 403)):
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

# ── F6: an auth challenge is the STRONGEST confirmation this row's URL works ────────────────────
# 401/403 proves the route resolved AND a live app answered AND it wants the very credential
# printed beside it. They used to fall into the `HTTP %s` catch-all and read as an anomaly.
ck "401 -> serving (an auth challenge means the app ANSWERED)" "$(probe c401.local)" "serving"
ck "403 -> serving (ditto — the backend is up)"                "$(probe c403.local)" "serving"

# ── F2: THE PORT, in the shape PRODUCTION actually produces ─────────────────────────────────────
# ⚠️ `probe` above sets `_ing=127.0.0.1:$PORT` — a shape creds.sh NEVER produces (`_ing` is
# `${INGRESS_LB_IP}`, a BARE IP) — which is exactly why 14/14 passed while the route probe
# hardcoded port 80 and the TCP gate honoured INGRESS_PROBE_PORT. This case uses the real shape.
# RED-PROOF: revert the `_u`/`case` lines in _reach_ingress and this returns `silent`.
probe_bare() { # bare `_ing` + the documented port knob, i.e. what creds.sh really passes
  ( eval "$_fn"
    _ing="127.0.0.1"; _ing_live=1
    CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 INGRESS_PROBE_PORT="$PORT" _reach_ingress "$1" )
}
ck "bare-IP ingress + INGRESS_PROBE_PORT -> serving (not a false 'silent')" \
   "$(probe_bare ok.local)" "serving"

# ── F3: one dead route must not cost eight more timeouts ────────────────────────────────────────
# Every ingress row targets the SAME LB, so after one HTTP probe fails to complete the rest will
# too. MEASURED: 9 rows serial at the 2s default = 18.1s; 1.0s once the first stops the rest.
# `LB up` is what this function already says when it cannot ask about a route — not a new meaning.
_sc="$T/route-dead"
ck "after a 000 the sentinel is SET (the first row still says silent)" \
   "$( ( eval "$_fn"; _ing="127.0.0.1:1"; _ing_live=1; _route_dead="$_sc"
         CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=1 _reach_ingress dead.local ) )" "silent"
ck "the sentinel file was created" "$( [ -e "$_sc" ] && echo yes || echo no )" "yes"
ck "a LATER row short-circuits to LB up instead of timing out again" \
   "$( ( eval "$_fn"; _ing="127.0.0.1:${PORT}"; _ing_live=1; _route_dead="$_sc"
         CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress ok.local ) )" "LB up"
ck "with NO sentinel the same row probes normally (the short-circuit is not always-on)" \
   "$( ( eval "$_fn"; _ing="127.0.0.1:${PORT}"; _ing_live=1; _route_dead="$T/never-created"
         CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress ok.local ) )" "serving"

# The short-circuits must still win, or the probe would run where the report promised it would not.
ck "CREDS_NO_PROBE=1 short-circuits"  \
   "$(eval "$_fn"; CREDS_NO_PROBE=1 _ing=1.2.3.4 _ing_live=1 _reach_ingress h.local)" "not probed"
ck "no ingress -> no ingress"         \
   "$(eval "$_fn"; CREDS_NO_PROBE=0 _ing='' _ing_live=1 _reach_ingress h.local)"        "no ingress"
ck "LB not live -> silent (never a per-host verdict)" \
   "$(eval "$_fn"; CREDS_NO_PROBE=0 _ing=1.2.3.4 _ing_live=0 _reach_ingress h.local)" "silent"
# An empty host cannot name a vhost; sending `Host: ` would earn a 404 and INVENT a "no route".
ck "empty host -> LB up (does not invent a route fault)" \
   "$(probe '')" "LB up"
# Nothing answering at all is `silent`, not a fabricated status. Port 1 is closed by construction.
ck "dead endpoint -> silent" \
   "$(eval "$_fn"; _ing=127.0.0.1:1; _ing_live=1; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=2 _reach_ingress h.local)" "silent"

# ── STALE DNS: it RESOLVES, but not to THIS ingress (2026-09-06) ───────────────────────────────
# MEASURED on the live lab: /etc/hosts still carried a PREVIOUS lab's ingress (192.168.101.135)
# while the current one was .134. The name resolved, so the DNS arm passed; the route probe reaches
# the LB BY IP with a Host header and got 200; and the table printed `serving` for NINE rows a
# browser could not open. Verified three ways — curl on the URL as printed: HTTP 000 x9; Chrome:
# error page; curl --resolve to .134: 200 x9, each app serving its own marker. The LAB was healthy
# and the REPORT was wrong.
#
# `localhost` resolves to 127.0.0.1 everywhere, so pointing _ing elsewhere is a genuine stale
# condition needing no stub and no network.
# ⚠️ REAL RESOLVER, stub OFF PATH — like the DNS case below. The stub is `exit 0` with NO OUTPUT,
# which is deliberate (it isolates the route arm), but this case needs an actual ADDRESS to compare.
# Under the stub it correctly falls through to the route probe, which is the right behaviour and the
# wrong test.
ck "resolves to a DIFFERENT address than the ingress -> stale DNS" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=203.0.113.9 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "stale DNS"
# THE CONTROL. If a MATCHING address also read `stale DNS`, the check would flag every healthy host
# and the state would be worthless — a verdict that cannot be false is not a verdict.
ck "resolves to the ingress itself -> NOT stale (falls through to the route probe)" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=127.0.0.1 _ing_live=1 _reach_ingress localhost' _ "$_fn")" "silent"
# An ingress given as a NAME cannot be compared to a resolved ADDRESS. Claiming `stale DNS` there
# would INVENT a fault, so the guard must fall through and let the route probe speak instead.
ck "ingress is a NAME, not an address -> must NOT claim stale" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _ing=ingress.example.test _ing_live=1 _reach_ingress localhost' _ "$_fn")" "silent"

# The DNS arm must still win when a host genuinely does not resolve — with the stub OFF PATH.
ck "unresolvable host -> no DNS here (the arm still short-circuits)" \
   "$(PATH="$_REAL_PATH" bash -c 'eval "$1"; _ing="127.0.0.1:'"$PORT"'"; _ing_live=1; CREDS_NO_PROBE=0 CREDS_PROBE_TIMEOUT_SECONDS=5 _reach_ingress definitely-not-a-real-host.invalid' _ "$_fn")" \
   "no DNS here"

printf '\ntest-creds-reach-ingress: %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
