#!/usr/bin/env bash
# test-creds-ingress-liveness.sh — B560: the /etc/hosts hint, the NOT ANSWERING banner, and the
# third state between them.
#
# ⚠️ THIS DRIVES THE REAL creds.sh. It cannot live in either existing suite, and that is measured,
# not stylistic: test-creds-reach-ingress.sh EXTRACTS only `_reach_ingress` and sets `_ing_live` by
# hand in all 21 of its cases, so a top-level edit at creds.sh:176-190 is invisible to it; and
# test-creds-show.sh's hosts pin uses `render_with_env`, which sets CREDS_NO_PROBE=1, so no probe
# runs at all. Both are green today over this defect -- the same way test-creds-reach-ingress went
# 14/14 over the port bug for its whole life.
#
# ⚠️ THE LAST THREE CASES ARE THE ONES THAT MATTER. A fix that only made the warning appear would
# pass cases 1-2 and still be a CRITICAL regression: `_ing_live` short-circuits EVERY ingress row to
# `silent` (creds.sh:843), and suppressing the hint kills the ONLY checkable Expect literal in
# docs/scenario-1.md:1099 and docs/scenario-2.md:929, reddening the six-row walk matrix hours later.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

export VKS_STATE_FILE; VKS_STATE_FILE="$(mktemp)"
_srv=""
cleanup() { [ -n "$_srv" ] && kill "$_srv" 2>/dev/null; rm -f "$VKS_STATE_FILE" "${_LISTENER:-}" "/tmp/.b560-port.$$"; }
trap cleanup EXIT

# listen <mode> -> echoes the port; sets $_srv to the listener's pid. Killed by PID, never by pkill:
# a `pkill -f` pattern appears in this script's OWN argv and would kill the invoking shell (exit 144,
# measured in this repo).
#
# ⚠️ THE LISTENER IS A TEMP FILE, NOT A HEREDOC ON THE FUNCTION. `python3 - <<PY` attached to a
# function definition works ONCE when the call is BACKGROUNDED: the child inherits the heredoc's
# open file description, reads it to EOF, and every later call inherits the SAME offset and gets an
# empty program -- python exits 0, silently, printing no port. MEASURED: call 1 -> [44445],
# call 2 -> []. It presented as "cases 2, 4 and 5 say the hint was suppressed" while case 1 passed,
# i.e. as a defect in the code under test. A non-backgrounded `cat` heredoc survives a second call,
# which is why the obvious two-line check does NOT reproduce it.
_LISTENER="$(mktemp)"
cat > "$_LISTENER" <<'PYEOF'
import socket, sys, threading, time
mode = sys.argv[1]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0)); s.listen(16)
print(s.getsockname()[1], flush=True)
def serve():
    while True:
        try: c, _ = s.accept()
        except OSError: return
        if mode == 'rst':          # Envoy with no routes: accept, then RST
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b'\x01\x00\x00\x00\x00\x00\x00\x00')
            c.close(); continue
        if mode == 'slow': time.sleep(5)
        try:
            c.recv(4096)
            c.sendall(b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
        except OSError: pass
        c.close()
threading.Thread(target=serve, daemon=True).start()
time.sleep(180)
PYEOF
listen() {
  local _pf="/tmp/.b560-port.$$"
  rm -f "$_pf"
  python3 "$_LISTENER" "$1" > "$_pf" 2>&1 &
  _srv=$!
  local _t
  for _t in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    grep -qE '^[0-9]{4,5}$' "$_pf" 2>/dev/null && break
    sleep 0.3
  done
  # A non-numeric first line means python failed. Return an unusable port so the case fails on ITS
  # OWN assertion rather than on a mangled fixture -- and print the reason to stderr, because a
  # silent bad fixture is exactly what cost this file two debugging rounds.
  grep -m1 -E '^[0-9]{4,5}$' "$_pf" 2>/dev/null || {
    printf 'LISTENER FAILED (%s): %s\n' "$1" "$(head -3 "$_pf" 2>/dev/null | tr '\n' ' ')" >&2
    printf '1'
  }
}

# render <ip> <port> [extra-env-assignment...] -> creds.sh's stdout
render() {
  local _ip="$1" _port="$2"; shift 2
  printf 'INGRESS_LB_IP=%s\nINGRESS_PROBE_PORT=%s\n' "$_ip" "$_port" > "$VKS_STATE_FILE"
  env "$@" SKIP_DOTENV=1 CREDS_TOKEN=1 CREDS_PROBE_TIMEOUT_SECONDS=2 ./scripts/creds.sh 2>/dev/null
}

_HINT='add once to /etc/hosts'
_WARN='accepts TCP connections but completes no HTTP request'
_DEAD='is NOT ANSWERING on port'

# ── 1. THE RED. Accept-then-RST: TCP says alive, HTTP completes nothing. ─────────────────────────
port="$(listen rst)"; out="$(render 127.0.0.1 "$port")"; kill "$_srv" 2>/dev/null; _srv=""
if grep -qF "$_WARN" <<< "$out"; then
  ok "accept-then-RST: the routeless-gateway warning appears"
else
  bad "accept-then-RST: NO warning. The TCP probe says alive and the report hands over an
      /etc/hosts line for a gateway that completes no request -- the B560 defect."
fi
if grep -qF "$_HINT" <<< "$out"; then
  ok "...and the hint is STILL printed (the walk's only Expect literal survives)"
else
  bad "...but the hint was SUPPRESSED. That kills the only checkable Expect literal in
      docs/scenario-{1,2}.md and reddens the walk matrix."
fi

# ── 2. THE DISCRIMINATING CONTROL. A healthy 404 must NOT warn. ──────────────────────────────────
port="$(listen ok)"; out="$(render 127.0.0.1 "$port")"; kill "$_srv" 2>/dev/null; _srv=""
if grep -qF "$_HINT" <<< "$out" && ! grep -qF "$_WARN" <<< "$out"; then
  ok "healthy 404 at the bare IP: hint printed, no warning (404 is ALIVE -- no vhost was named)"
else
  bad "healthy 404: expected the hint and NO warning. Without this case the warning could fire
      unconditionally and cases 1-2 would both still pass."
fi

# ── 3. Nothing listening: the existing banner, unchanged. ────────────────────────────────────────
out="$(render 127.0.0.1 1 )"
if grep -qF "$_DEAD" <<< "$out" && ! grep -qF "$_HINT" <<< "$out"; then
  ok "nothing listening: NOT ANSWERING, and no hint (unchanged behaviour)"
else
  bad "nothing listening: expected the NOT ANSWERING banner and no hint"
fi

# ── 4. FALSE-DEAD GUARD: a slow ingress must not lose the hint. ──────────────────────────────────
# 5 s against a 2 s budget. Replacing the socket verdict with an HTTP one -- the REFUTED design --
# fails here, which is the point of measuring it.
port="$(listen slow)"; out="$(render 127.0.0.1 "$port")"; kill "$_srv" 2>/dev/null; _srv=""
if grep -qF "$_HINT" <<< "$out"; then
  ok "slow (5s) ingress: the hint still prints -- a timeout must not read as a dead LB"
else
  bad "slow ingress: the hint was suppressed. A cold-start or loaded ingress now blanks the
      operator's only actionable line AND every Reachable cell."
fi

# ── 5. FALSE-DEAD GUARD: no curl on PATH (bare Photon ships none). ───────────────────────────────
_stub="$(mktemp -d)"
for _b in bash sed grep awk cut tr sort head tail printf date mktemp rm cat wc kubectl python3 timeout env dirname basename tput stat find id; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -sf "$_p" "$_stub/$_b"
done
port="$(listen ok)"; out="$(render 127.0.0.1 "$port" "PATH=$_stub")"; kill "$_srv" 2>/dev/null; _srv=""
rm -rf "$_stub"
if grep -qF "$_HINT" <<< "$out"; then
  ok "no curl on PATH: the hint still prints (/dev/tcp is a bash builtin and needs nothing)"
else
  bad "no curl: the hint was suppressed. curl is an UNDECLARED dependency of this report -- there
      is no require_cmd curl anywhere in creds.sh -- so a bare jump box would lose the line."
fi

printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
