#!/usr/bin/env bash
# test-secret-quoting.sh — offline unit tests for the two places a SECRET reaches a sink that
# PARSES it. Both were interpolating it raw.
#
# WHY THIS FILE EXISTS
# --------------------
# 1. curl -K config (lib/harbor.sh, 02-env.sh). A bare `"` in a password TRUNCATES it at that
#    character; a `\` is EATEN; a newline opens a NEW config line, turning the value into a curl
#    DIRECTIVE. Measured against a real HTTP server (below), not `--libcurl` — which C-escapes its
#    OWN output and produced three wrong readings while this was being written.
#      user = "admin:ab"cd"  ->  curl sends  admin:ab
#      user = "admin:ab\cd"  ->  curl sends  admin:abcd
#    -> Harbor 401 on a perfectly good password, and lib/harbor.sh's diagnostic then blames the
#    password and the install order. `pw_weak` mirrors Harbor's IsValidSec (length+case+digit, NO
#    charset limit), so `ab"cd` passes every local gate we have.
#
# 2. The `.env` line 22-harbor-robot.sh writes. A `'` in the value terminates the single quote, so
#    the rest is parsed as CODE by load_env's `set -a` source. LOW: Harbor cannot emit a `'` today
#    (secrets [a-zA-Z0-9]; robot names `^[a-z0-9]+(?:[._-][a-z0-9]+)*$` — goharbor v2.15.0), so
#    this guards an upstream charset change. A stray `'` alone still unsets the var -> a 401 that
#    blames the password.
#
# The helpers are PURE FUNCTIONS in lib/os.sh precisely so this file can EXECUTE them rather than
# grep for them (the engine_packages pattern).
#
# Every check runs BOTH directions: the escaped value must round-trip, AND the unescaped control
# must still be corrupted — a green that cannot fail is not a test.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. esc_sq: the .env line must ROUND-TRIP and must not EXECUTE.
# ---------------------------------------------------------------------------
echo "== esc_sq: a value survives a 'set -a' source, and cannot execute =="
SENTINEL="$(mktemp -u)"
while IFS= read -r v; do
  [ -n "$v" ] || continue
  f="$(mktemp)"
  printf "V='%s'\n" "$(esc_sq "$v")" > "$f"
  # shellcheck source=/dev/null  # a generated fixture: sourcing it IS the test
  got="$(set -a; . "$f" 2>/dev/null; set +a; printf '%s' "${V-}")"
  if [ "$got" = "$v" ]; then ok "round-trip $(printf '%q' "$v")"; else bad "round-trip $(printf '%q' "$v") -> $(printf '%q' "$got")"; fi
  rm -f "$f"
done <<EOF
plain
robot\$vks-cicd
a'b'c
'
back\`tick\`
d\$(id -u)e
"dq"
p@ss word
EOF

# The injection itself, and its RED control.
f="$(mktemp)"; evil="x'; touch ${SENTINEL}; #"
printf "V='%s'\n" "$(esc_sq "$evil")" > "$f"
# shellcheck source=/dev/null  # a generated fixture: sourcing it IS the test
( set -a; . "$f" 2>/dev/null; set +a ) >/dev/null 2>&1
if [ -f "$SENTINEL" ]; then bad "ESCAPED value EXECUTED — esc_sq is broken"; else ok "escaped injection is inert"; fi
rm -f "$f" "$SENTINEL"

# RED control: without esc_sq the SAME value must execute. If this stops firing, the test above is
# vacuous and this file is measuring nothing.
f="$(mktemp)"; printf "V='%s'\n" "$evil" > "$f"
# shellcheck source=/dev/null  # a generated fixture: sourcing it IS the test
( set -a; . "$f" 2>/dev/null; set +a ) >/dev/null 2>&1
if [ -f "$SENTINEL" ]; then ok "RED control: UNescaped value executes (the bug is real)"; else bad "RED control did NOT execute — this test can no longer fail"; fi
rm -f "$f" "$SENTINEL"

# ---------------------------------------------------------------------------
# 2. esc_curlk: the credential curl actually SENDS must equal the input.
#    Oracle: a real server decoding the Authorization header. NOT --libcurl.
# ---------------------------------------------------------------------------
echo "== esc_curlk: the credential curl SENDS equals the credential we gave it =="
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  SKIP: python3/curl absent (this leg needs a loopback oracle)"
else
  PORT="${SECRET_QUOTING_TEST_PORT:-0}"
  OUT="$(mktemp)"; PYS="$(mktemp --suffix=.py)"; PORTF="$(mktemp)"
  cat > "$PYS" <<PYEOF
import base64, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
out, portf = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        a = self.headers.get("Authorization", "")
        open(out, "w").write(base64.b64decode(a[6:]).decode("utf-8", "replace") if a.startswith("Basic ") else "")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def do_PUT(self): self.do_GET()
    def log_message(self, *a): pass
srv = HTTPServer(("127.0.0.1", int(sys.argv[3])), H)
open(portf, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PYEOF
  python3 "$PYS" "$OUT" "$PORTF" "$PORT" & ORACLE_PID=$!
  # Track the oracle by PID. NEVER pkill -f: the pattern self-matches the shell running it.
  trap 'kill "$ORACLE_PID" 2>/dev/null; rm -f "$OUT" "$PYS" "$PORTF"' EXIT
  for _ in $(seq 1 40); do [ -s "$PORTF" ] && break; sleep 0.1; done
  PORT="$(cat "$PORTF" 2>/dev/null)"
  if [ -z "$PORT" ]; then
    echo "  SKIP: oracle did not start"
  else
    send() { # <password> <escape:1|0> -> what curl actually sent
      local p="$1" esc="$2" cfg; cfg="$(mktemp)"; : > "$OUT"
      if [ "$esc" = 1 ]; then ( umask 077; printf 'user = "%s:%s"\n' admin "$(esc_curlk "$p")" > "$cfg" )
      else                    ( umask 077; printf 'user = "%s:%s"\n' admin "$p"               > "$cfg" ); fi
      curl -s --max-time 5 -K "$cfg" "http://127.0.0.1:${PORT}/" >/dev/null 2>&1
      rm -f "$cfg"; local g; g="$(cat "$OUT" 2>/dev/null)"; printf '%s' "${g#admin:}"
    }
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      got="$(send "$p" 1)"
      if [ "$got" = "$p" ]; then ok "curl sends $(printf '%q' "$p")"; else bad "curl sends $(printf '%q' "$p") -> $(printf '%q' "$got")"; fi
    done <<EOF
Harbor12345
ab"cd
ab\\cd
a"b\\c
robot\$vks-cicd
a;b|c&d
pa#ss
EOF
    # RED controls: unescaped, these MUST still be corrupted. They are the reason to believe the
    # checks above measure anything.
    if [ "$(send 'ab"cd' 0)" = "ab" ]; then ok 'RED control: unescaped ab"cd truncates to ab'; else bad 'RED control: unescaped ab"cd no longer truncates — test is vacuous'; fi
    if [ "$(send 'ab\cd' 0)" = "abcd" ]; then ok 'RED control: unescaped ab\cd loses the backslash'; else bad 'RED control: unescaped ab\cd no longer mangles — test is vacuous'; fi
  fi
fi

# ---------------------------------------------------------------------------
# 3. The robot file must be 0600 even if it ALREADY EXISTS world-readable.
#    `umask 077` applies at CREATION only — a pre-existing 0644 file keeps 0644.
# ---------------------------------------------------------------------------
echo "== the robot credentials file is 0600 even when it already exists 0644 =="
# shellcheck disable=SC2016  # the LITERAL $OUT_FILE is the point: we grep the source, not expand it.
if grep -q '^rm -f "\$OUT_FILE"' "${SCRIPT_DIR}/22-harbor-robot.sh"; then
  d="$(mktemp -d)"; f="${d}/harbor-robot.env"
  : > "$f"; chmod 644 "$f"
  rm -f "$f"; ( umask 077; printf 'HARBOR_USERNAME=x\n' > "$f" )   # the shipped sequence
  m="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)"
  if [ "$m" = "600" ]; then ok "rm -f + umask 077 yields 0600 over a pre-existing 0644"; else bad "mode is $m, want 600"; fi
  # RED control: WITHOUT the rm -f, the stale 0644 survives.
  : > "$f"; chmod 644 "$f"; ( umask 077; printf 'HARBOR_USERNAME=x\n' > "$f" )
  m2="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)"
  if [ "$m2" = "644" ]; then ok "RED control: without rm -f a pre-existing 0644 SURVIVES"; else bad "RED control: expected 644 to survive, got $m2 — this check is vacuous"; fi
  rm -rf "$d"
else
  bad "22-harbor-robot.sh no longer does 'rm -f \$OUT_FILE' before the write (mode 0644 can survive)"
fi

echo
if [ "$rc" -eq 0 ]; then
  log_info "test-secret-quoting: OK — ${checks} checks (round-trip + RED controls)"
else
  log_error "test-secret-quoting: FAILED (${checks} checks ran)"
fi
exit "$rc"
