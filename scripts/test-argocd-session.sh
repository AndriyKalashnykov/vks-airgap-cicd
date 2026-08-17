#!/usr/bin/env bash
# test-argocd-session.sh — OFFLINE tests for the argv-safe ArgoCD session helpers in lib/argocd.sh.
#
# WHY IT EXISTS AT ALL: the curl-gate round's finding was that a check with NO WAY to be tested
# against a failure class is how the failure class ships. `argocd_session_token` therefore honours
# ARGOCD_SESSION_SCHEME, and this file is the only caller that sets it — a local plain-HTTP stub
# stands in for argocd-server, so every arm is exercised with no cluster and no network.
#
# The load-bearing case is #4: a password containing " and \ must still authenticate. My first
# hand-rolled version built the body with printf '{"password":"%s"}', which CORRUPTS the JSON for
# exactly those characters and yields a 400 that reads as a wrong credential. jq escapes correctly,
# and this test is what keeps anyone from "simplifying" it back.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
# ⚠️ HARDENING, NOT A BUG FIX — say which, or the next reader over-trusts the change. An
# implementation round MEASURED that the `A && B || C` form here CANNOT misfire: `ok()`'s last
# command is `pass=$((pass+1))`, an ASSIGNMENT, whose status is 0 unconditionally — verified on the
# first call, on a call where the arithmetic result is 0, and with stdout closed, with `((n++))` at
# n=0 as the positive control proving the instrument discriminates. So `bad` could never double-fire.
# It is written as if/then/else anyway because the invariant that makes it safe lives in a DIFFERENT
# function two lines away, and shellcheck is right that the shape is fragile.
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

# ── a stub argocd-server. Echoes back the password it received so the test can prove the body
# survived transport byte-for-byte — the only way to catch a JSON-escaping bug.
PORT=0
STUB_PY="$(mktemp)"; trap 'rm -f "$STUB_PY" "${STUB_LOG:-}"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null' EXIT
cat > "$STUB_PY" <<'PY'
import json, sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length','0') or 0))
        try:
            got = json.loads(raw.decode())          # a CORRUPT body raises here -> 400, as the real server would
        except Exception:
            self.send_response(400); self.end_headers(); self.wfile.write(b'{}'); return
        # echo the received password back INSIDE the token, so the caller can assert round-trip fidelity
        tok = "tok:" + got.get("password","")
        body = json.dumps({"token": tok}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
STUB_LOG="$(mktemp)"
python3 "$STUB_PY" > "$STUB_LOG" 2>&1 &
STUB_PID=$!
# Wait for the port line rather than sleeping: a fixed sleep is a race, and the port is chosen by
# the kernel (:0) so it cannot collide with a parallel run.
for _ in $(seq 1 50); do PORT="$(head -1 "$STUB_LOG" 2>/dev/null || true)"; [ -n "$PORT" ] && break; sleep 0.1; done
case "$PORT" in ''|*[!0-9]*) printf '  FAIL  the stub server never reported a port\n'; exit 1 ;; esac
export ARGOCD_SESSION_SCHEME=http     # the stub speaks plain HTTP
SRV="127.0.0.1:${PORT}"

echo "== argocd_curl_tls_init: prefers the CA, falls back LOUDLY =="
CA="$(mktemp)"; printf 'not-a-real-ca\n' > "$CA"
ARGOCD_CA_FILE="$CA" argocd_curl_tls_init
check "with a CA -> mode is verified"      "$ARGOCD_TLS_MODE"      "verified"
check "with a CA -> curl gets --cacert"    "${ARGOCD_CURL_TLS[0]:-}" "--cacert"
ARGOCD_CA_FILE="" argocd_curl_tls_init
check "no CA -> mode is insecure"          "$ARGOCD_TLS_MODE"      "insecure"
check "no CA -> curl gets -k"              "${ARGOCD_CURL_TLS[0]:-}" "-k"
# An EMPTY file must not count as an anchor: `-s` is the guard, and a 0-byte CA would make curl fail
# with a confusing error instead of taking the honest insecure path.
EMPTY="$(mktemp)"; : > "$EMPTY"
ARGOCD_CA_FILE="$EMPTY" argocd_curl_tls_init
check "EMPTY CA file -> insecure, not verified" "$ARGOCD_TLS_MODE" "insecure"
rm -f "$CA" "$EMPTY"

echo
echo "== argocd_session_token: the token round-trips, and the BODY survives escaping =="
ARGOCD_CA_FILE="" argocd_curl_tls_init
check "a plain password authenticates"  "$(argocd_session_token "$SRV" 'S3cret')"          'tok:S3cret'
# THE LOAD-BEARING CASE. printf '{"password":"%s"}' corrupts both of these; jq does not.
check 'a password with a DOUBLE QUOTE'  "$(argocd_session_token "$SRV" 'a"b')"             'tok:a"b'
check 'a password with a BACKSLASH'     "$(argocd_session_token "$SRV" 'a\b')"             'tok:a\b'
# shellcheck disable=SC2016  # BOTH single-quoted spans are the POINT: this case proves a
# password containing a literal $ survives transport byte-for-byte, so neither the input nor
# the expected value may be expanded by the shell. `set -u` also protects the naive "fix":
# double-quoting these crashes with `rd: unbound variable` (rc=127), so the wrong change is
# loud rather than silent. RESIDUAL: input and expected degrade TOGETHER, so if `rd` were ever
# set in the environment a double-quoted version would pass with the $ coverage silently gone.
check 'a password with BOTH + a $'      "$(argocd_session_token "$SRV" 'p@ss"w\o$rd')"     'tok:p@ss"w\o$rd'
check 'a password with a NEWLINE'       "$(argocd_session_token "$SRV" 'a
b')"                                                                                       'tok:a
b'

echo
echo "== the password reaches NEITHER argv (jq reads the environment; curl reads stdin) =="
# Assert on the SOURCE, because a live /proc check would race the process's exit. The two forms this
# must never regress to are a jq --arg and a printf-built body.
#
# ⚠️ THE `--data @-` ASSERTION WAS BLIND FOR THE LIFE OF THIS FILE, and it is the one guarding this
# repo's argv-secret invariant. It grepped the raw file for `curl .*--data @-`; the only line that
# matched was **the COMMENT at lib/argocd.sh:294**, because the real invocation splits `curl` (:341)
# from `--data @-` (:342) across a `\` continuation and grep is line-based.
# RED-PROVEN: rewriting the code to `--data @/dev/stdin` while leaving the comment intact still
# printed `PASS curl takes the body on STDIN (--data @-)` and `14 passed, 0 failed`.
#
# So: FOLD CONTINUATIONS, then DROP COMMENTS, then match. `_libsrc` is built once.
# ⚠️ The match uses a HERESTRING, not `producer | grep -q`: under this file's `pipefail` a `grep -q`
# exits at the first hit and SIGPIPEs the producer, and the pipeline's status becomes 141 — which
# reports a FOUND pattern as ABSENT. In an assertion the failure direction would be a false FAIL;
# in a scan gate it is a false CLEAN. Neither is acceptable, and a herestring cannot SIGPIPE.
_libsrc="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "${SCRIPT_DIR}/lib/argocd.sh" | grep -v '^[[:space:]]*#')"

# POSITIVE CONTROL, first: an assertion nobody has ever seen go red is not an assertion. If the
# normalisation above silently produced nothing, every check below would "pass" over an empty string.
if [ "$(printf '%s' "$_libsrc" | wc -l)" -gt 50 ]; then
  ok "the normalised lib source is non-empty ($(printf '%s' "$_libsrc" | wc -l) non-comment lines)"
else
  bad "the normalised lib source is empty or tiny" "every source assertion below would pass vacuously"
fi

if grep -q "jq -nc '{username:\"admin\", password:env.ARGOCD_ADMIN_PW}'" <<< "$_libsrc"; then
  ok "jq reads the password from env.ARGOCD_ADMIN_PW"
else
  bad "jq reads the password from env.ARGOCD_ADMIN_PW" "the env form is gone — a --arg would put it in jq's argv"
fi
if grep -q 'curl .*--data @-' <<< "$_libsrc"; then
  ok "curl takes the body on STDIN (--data @-)"
else
  bad "curl takes the body on STDIN (--data @-)" "the body moved off stdin — a --data <value> puts the password in curl's argv"
fi
# Negative assertion, on the SAME normalised source: matching the raw file would let a comment
# rewording produce a false FAIL here, which is the mirror of the bug above.
if grep -qE "printf '\{\"username\"" <<< "$_libsrc"; then
  bad "no printf-built JSON body" "a printf body does not escape JSON — it corrupts a password containing a quote"
else
  ok "no printf-built JSON body"
fi

echo
echo "== a wrong/failed transport yields NO token (empty, never a partial) =="
check "an unreachable server -> empty" "$(ARGOCD_SESSION_TIMEOUT=2 argocd_session_token '127.0.0.1:1' 'x')" ''

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
