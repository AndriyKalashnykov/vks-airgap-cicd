#!/usr/bin/env bash
# ci-tier: fast — offline; one unroutable-IP probe (~2s) plus a local TLS oracle (~2s).
#
# test-wcp-service.sh — the `wcp-restart` wait loop must SURVIVE a transport blip and must STILL
# die on a rejected credential. Two defects, both measured on the shipped code (B133):
#
#   1. `wait_for` probed with a bare `vc_login`, which DIES on 000 and on any non-2xx. An `exit`
#      inside an `if` CONDITION does NOT stay in the `if` — MEASURED:
#          f(){ exit 7; }; if f; then :; fi; echo AFTER   ->  rc=7, AFTER never prints
#      So one blip during the very restart the loop exists to wait through killed the script at
#      ~10s with NO message, while the BENIGN timeout printed a full diagnosis. Backwards.
#   2. `wait_for` ended in `die`, and `die` ends in `exit` — which `||` cannot catch. So the
#      `stop` arm's `wait_for ... || true` could not do its job: a timed-out `wcp-stop` terminated
#      the script and SUPPRESSED the "next: make wcp-start" line, leaving the operator with
#      Workload Management down for every tenant and no instruction to bring it back.
#
# ⚠️ THE SECURITY CASE IS THE 401 ONE, AND IT IS NOT A FORMALITY. vCenter SSO locks the account
# after a small number of failures in a short window. `--soft` must NOT soften 401: dying on the
# FIRST one is what keeps this polling loop's lockout cost at exactly ONE attempt. A "bounded retry
# on 401" would turn that into 2..N and is the one change that could actually lock the account out.
# If case 3 below ever goes green having been silently skipped, this file is measuring nothing.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# ── cases 1-2: the soft/hard split on a TRANSPORT failure ────────────────────────────────────────
# 192.0.2.0/24 is TEST-NET-1 (RFC 5737) — guaranteed unroutable, so curl yields 000 without
# touching anything real. The lab is NEVER contacted by this file.
probe() {
  # $1 = extra args for vc_login. Runs in a SUBSHELL so a `die` cannot kill this suite; the
  # subshell's rc tells us which happened, and the marker tells us it RETURNED rather than exited.
  ( set -uo pipefail
    . scripts/lib/os.sh >/dev/null 2>&1
    . scripts/lib/vcenter.sh
    export VCENTER_HOST="${ORACLE_HOST:-192.0.2.1}" VCENTER_USERNAME='probe@vsphere.local' \
           VCENTER_PASSWORD='NOT-A-REAL-PASSWORD' VC_CONNECT_TIMEOUT=2 VC_API_TIMEOUT=3
    vc_login ${1:+"$1"} && exit 0
    printf 'RETURNED\n'          # only reachable if vc_login RETURNED non-zero instead of exiting
    exit 9
  ) 2>/dev/null
}

out="$(probe --soft)"; rc=$?
if [ "$rc" = 9 ] && printf '%s' "$out" | grep -q RETURNED; then
  ok "vc_login --soft on an unreachable host RETURNS (the caller survives to re-probe)"
else
  bad "vc_login --soft should RETURN non-zero on 000, not exit. rc=${rc} out='${out}'"
fi

out="$(probe)"; rc=$?
if [ "$rc" != 9 ] && ! printf '%s' "$out" | grep -q RETURNED; then
  ok "plain vc_login on an unreachable host still DIES (every other caller is unchanged)"
else
  bad "plain vc_login must remain fatal on 000 — 8 callers depend on it. rc=${rc} out='${out}'"
fi

# ── case 3: 401 STAYS FATAL under --soft (the lockout budget) ────────────────────────────────────
# Needs a real HTTPS responder, because vc_login speaks https and a plaintext listener yields 000 —
# which would make this case pass for the WRONG reason (the transport arm, not the credential arm).
if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  # LOUD. A silent skip on the security case is indistinguishable from a pass.
  printf 'SKIP  401-stays-fatal: openssl and/or python3 absent, so no TLS oracle can be built\n' >&2
else
  T="$(mktemp -d)"; SRV=""
  # shellcheck disable=SC2064  # expand T/SRV NOW: the trap must clean up even if this shell dies.
  trap "rm -rf '$T'; [ -n \"\${SRV:-}\" ] && kill \"\$SRV\" 2>/dev/null" EXIT
  if openssl req -x509 -newkey rsa:2048 -keyout "$T/k.pem" -out "$T/c.pem" -days 1 -nodes \
       -subj "/CN=localhost" >/dev/null 2>&1; then
    cat > "$T/srv.py" <<'PY'
import http.server, ssl, sys, os
CODE = int(os.environ["ORACLE_CODE"])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(CODE); self.send_header("Content-Length", "2"); self.end_headers()
        self.wfile.write(b'""')
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain(sys.argv[2], sys.argv[3])
s.socket = c.wrap_socket(s.socket, server_side=True); s.serve_forever()
PY
    for spec in "401:fatal" "503:soft"; do
      code="${spec%%:*}"; want="${spec##*:}"
      P=$(( 20000 + RANDOM % 10000 ))
      ORACLE_CODE="$code" python3 "$T/srv.py" "$P" "$T/c.pem" "$T/k.pem" & SRV=$!
      sleep 1.5
      out="$(ORACLE_HOST="127.0.0.1:${P}" probe --soft)"; rc=$?
      kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
      if [ "$want" = fatal ]; then
        if [ "$rc" != 9 ]; then
          ok "HTTP ${code} is FATAL even under --soft (the SSO lockout budget stays at ONE attempt)"
        else
          bad "HTTP ${code} MUST stay fatal under --soft. Softening it is what could lock the account out. rc=${rc}"
        fi
      else
        if [ "$rc" = 9 ]; then
          ok "HTTP ${code} is soft-retried under --soft (server-side; no credential was evaluated)"
        else
          bad "HTTP ${code} should be soft-retried, not fatal — it is exactly what a restarting vCenter returns. rc=${rc}"
        fi
      fi
    done
  else
    printf 'SKIP  401-stays-fatal: openssl could not mint a throwaway cert\n' >&2
  fi
fi

# ── cases 4-5: wait_for RETURNS, so each caller decides fatality ─────────────────────────────────
# End-to-end through the REAL script, with the vCenter layer stubbed to a state that NEVER reaches
# the target — so wait_for must exhaust its budget. That is the only way to exercise both arms
# without a vCenter, and it exercises the actual `case` wiring rather than a copy of it.
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
if git archive HEAD 2>/dev/null | tar -x -C "$W" 2>/dev/null; then
  cp scripts/wcp-service.sh "$W/scripts/wcp-service.sh"
  cat > "$W/scripts/lib/vcenter.sh" <<'STUB'
vc_require()   { :; }
vc_login()     { return 0; }
vc_logout()    { :; }
vc_api()       { printf '{"state":"STARTING","health":"DEGRADED"}\n'; }
vc_last_code() { printf '202'; }
STUB
  ( cd "$W" && WCP_WAIT_SECONDS=1 WCP_POLL_SECONDS=1 VCENTER_HOST=stub VCENTER_USERNAME=u VCENTER_PASSWORD=p \
      ./scripts/wcp-service.sh restart ) >"$W/r.log" 2>&1
  rrc=$?
  if [ "$rrc" != 0 ] && grep -qi 'wcp did not come back' "$W/r.log"; then
    ok "restart: a wait_for timeout is FATAL and says so (reporting success here is the fake-green)"
  else
    bad "restart must fail when wcp never reaches STARTED/HEALTHY. rc=${rrc}; log tail:
$(tail -3 "$W/r.log")"
  fi

  ( cd "$W" && CONFIRM=yes WCP_WAIT_SECONDS=1 WCP_POLL_SECONDS=1 VCENTER_HOST=stub VCENTER_USERNAME=u VCENTER_PASSWORD=p \
      ./scripts/wcp-service.sh stop ) >"$W/s.log" 2>&1
  src=$?
  if [ "$src" = 0 ] && grep -qi 'next: make wcp-start' "$W/s.log"; then
    ok "stop: a wait_for timeout is NON-fatal and the recovery line still prints (|| true now works)"
  else
    bad "stop must survive the timeout and print the recovery line — the operator has just taken
        Workload Management DOWN and needs the command that brings it back. rc=${src}; log tail:
$(tail -3 "$W/s.log")"
  fi
else
  printf 'SKIP  wait_for arms: git archive failed, so no sandbox could be built\n' >&2
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — wcp-service survives a transport blip, still dies on a bad credential, and each\n'
printf '          caller decides whether a wait_for timeout is fatal.\n'
