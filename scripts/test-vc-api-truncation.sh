#!/usr/bin/env bash
# ci-tier: fast — offline; one local TLS socket, ~2s.
#
# test-vc-api-truncation.sh — vc_api must NOT report success on a response that was cut short
# after its 200 headers.
#
# THE BUG (B194): `%{http_code}` is what the server SAID, not what arrived. A response whose
# body is truncated mid-transfer still reports 200, so `case 2*) return 0` handed the caller a
# SUCCESS return over incomplete JSON. vc_login already preserved curl's rc; vc_api did not.
#
# ⚠️ THE FIRST FIXTURE FOR THIS WAS WRONG AND ITS "RED-PROOF" PROVED NOTHING — worth recording,
# because it looked convincing. It used python's http.server, whose handler kept the connection
# open after the short write, so curl HUNG and then errored: BOTH arms measured `rc=1 code=000`
# and the control was the only thing that revealed the proof discriminated nothing. The instrument
# check that settled it: run bare curl against the fixture and read what it actually prints.
#   http.server fixture -> curl hangs, then errors        (the case never occurs)
#   raw-socket fixture  -> curl prints 200, rc=18,        (the case, reproduced)
#                          "transfer closed with 4991 bytes remaining to read"
# So the server below writes a COMPLETE status line + Content-Length: 5000, sends 9 bytes, and
# closes hard. Do not "simplify" it back to http.server.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  # LOUD: a silent skip on a correctness case is indistinguishable from a pass.
  printf 'SKIP  vc-api-truncation: openssl and/or python3 absent, so no TLS fixture can be built\n' >&2
  exit 0
fi

T="$(mktemp -d)"; SRV=""
# shellcheck disable=SC2064
trap "rm -rf '$T'; [ -n \"\${SRV:-}\" ] && kill \"\$SRV\" 2>/dev/null" EXIT

# IP SAN is load-bearing: the fixture is dialled as 127.0.0.1, and a CN-only cert is rejected at
# rc 60 — which would make this case "pass" by dying at TLS without ever reaching the truncation.
openssl req -x509 -newkey rsa:2048 -keyout "$T/k.pem" -out "$T/c.pem" -days 1 -nodes \
  -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 \
  || { printf 'SKIP  vc-api-truncation: openssl could not mint a throwaway cert\n' >&2; exit 0; }

cat > "$T/srv.py" <<'PY'
import socket, ssl, sys
PORT, CERT, KEY = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT, KEY)
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT)); srv.listen(1)
sys.stderr.write("ready\n"); sys.stderr.flush()
conn, _ = srv.accept()
try:
    tls = ctx.wrap_socket(conn, server_side=True)
    tls.recv(4096)
    tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                b"Content-Length: 5000\r\n\r\n" b'{"a":1234')   # promises 5000, sends 9
    tls.unwrap(); tls.close()
except Exception:
    pass
finally:
    srv.close()
PY

P="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 "$T/srv.py" "$P" "$T/c.pem" "$T/k.pem" 2>"$T/rdy" & SRV=$!
for _ in $(seq 1 40); do grep -q ready "$T/rdy" 2>/dev/null && break; sleep 0.2; done

out="$(env -i PATH="$PATH" HOME="$HOME" bash -c "
  set -uo pipefail; cd '$PWD'
  . scripts/lib/os.sh >/dev/null 2>&1
  export VCENTER_HOST='127.0.0.1:$P' VCENTER_CA_FILE='$T/c.pem'
  VC_HDR_FILE=\$(mktemp); VC_CODE_FILE=\$(mktemp); export VC_HDR_FILE VC_CODE_FILE; : > \"\$VC_HDR_FILE\"
  . scripts/lib/vcenter.sh
  body=\"\$(vc_api GET / 2>/dev/null)\"; r=\$?
  printf 'rc=%s code=%s bytes=%s\n' \"\$r\" \"\$(vc_last_code)\" \"\${#body}\"
" 2>/dev/null)"
wait "$SRV" 2>/dev/null; SRV=""

rc="$(printf '%s' "$out" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
code="$(printf '%s' "$out" | sed -n 's/.*code=\([0-9]*\).*/\1/p')"
bytes="$(printf '%s' "$out" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')"

# The fixture must have DELIVERED the case, or this file measures nothing: a short body is the
# whole premise. Assert it before judging vc_api.
if [ "${bytes:-0}" -gt 0 ] && [ "${bytes:-0}" -lt 5000 ]; then
  ok "the fixture delivered a TRUNCATED body (${bytes} of a promised 5000)"
else
  bad "the fixture did not truncate (bytes=${bytes:-?}) — this case is measuring nothing; fix the fixture, not vc_api"
fi

if [ "${rc:-0}" != 0 ] && [ "${code:-}" = 000 ]; then
  ok "vc_api REFUSES a truncated 200 (rc=${rc}, code=000) — the caller cannot mistake it for success"
else
  bad "vc_api reported rc=${rc:-?} code=${code:-?} on a TRUNCATED body. Without the rc capture this is
      rc=0 code=200 — a success return over incomplete JSON, which is exactly B194."
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — vc_api preserves curl.s exit status, so a cut-short 200 cannot read as success.\n'
