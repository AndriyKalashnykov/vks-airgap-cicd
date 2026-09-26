#!/usr/bin/env bash
# test-argocd-ca-from-cluster.sh — the anchor read from the Supervisor Secret must be the certificate
# ArgoCD actually SERVES, or nothing is written (B486).
#
# Offline: a real `openssl s_server` serves certificate A on 127.0.0.1; a kubectl stub returns either A
# (must be written) or an unrelated B (must be REFUSED, the output untouched). The verification is an
# exact SHA-256 match, so the RED is "a certificate that is a valid cert, just not the served one".
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

mint() { openssl req -x509 -newkey rsa:2048 -keyout "$T/$1.key" -out "$T/$1.crt" -days 1 -nodes \
           -subj "/CN=argocd-server" -addext "subjectAltName=DNS:argocd-server,DNS:localhost" >/dev/null 2>&1; }
mint a; mint b
# shellcheck source=scripts/lib/os.sh
. "$SCRIPT_DIR/lib/os.sh"
PORT="$(pick_port)"   # a fixed port collides when two gates run at once
openssl s_server -quiet -accept "$PORT" -cert "$T/a.crt" -key "$T/a.key" -www >/dev/null 2>&1 & SRV=$!
for _ in $(seq 1 40); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.25; done

mkdir -p "$T/bin" "$T/repo/secrets"
: > "$T/repo/.env.example"
printf 'apiVersion: v1\n' > "$T/repo/secrets/supervisor.kubeconfig"
# kubectl stub. Every call's argv is logged, so the test can assert the ONLY thing read is tls.crt.
#   TLS_MODE=notfound (default) | forbidden | present   -- what argocd-server-tls answers
#   SECRET_CERT                                         -- the cert argocd-secret (or -tls when present) holds
#   NS_MODE=exists (default) | missing                  -- get ns, and whether secrets say NotFound
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KLOG"
case "$*" in
  *"get ns "*) [ "${NS_MODE:-exists}" = missing ] && { echo 'Error from server (NotFound): namespaces "x" not found' >&2; exit 1; }; exit 0 ;;
esac
if [ "${NS_MODE:-exists}" = missing ]; then echo 'Error from server (NotFound): secrets "x" not found' >&2; exit 1; fi
case "$*" in
  *"get secret argocd-server-tls"*)
    case "${TLS_MODE:-notfound}" in
      forbidden) echo 'Error from server (Forbidden): secrets "argocd-server-tls" is forbidden' >&2; exit 1 ;;
      present)   base64 -w0 < "$SECRET_CERT"; exit 0 ;;
      *)         echo 'Error from server (NotFound): secrets "argocd-server-tls" not found' >&2; exit 1 ;;
    esac ;;
  *"get secret argocd-secret"*) base64 -w0 < "$SECRET_CERT"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/kubectl"

run() {  # run <cert-the-secret-holds> <out>
  : > "$T/klog"
  env -i HOME="$T" PATH="$T/bin:$PATH" REPO_ROOT="$T/repo" SKIP_DOTENV=1 SECRET_CERT="$1" KLOG="$T/klog" \
      TLS_MODE="${TLS_MODE:-}" NS_MODE="${NS_MODE:-}" ARGOCD_CA_SHA256="${PIN:-}" \
      ARGOCD_NAMESPACE=lab ARGOCD_SERVER="127.0.0.1:${PORT}" VKS_SUPERVISOR_KUBECONFIG="$T/repo/secrets/supervisor.kubeconfig" \
      bash "$SCRIPT_DIR/argocd-ca-from-cluster.sh" "$2" 2>&1
}

out="$(run "$T/a.crt" "$T/out-a.crt")"; rc=$?
if [ "$rc" = 0 ] && cmp -s "$T/a.crt" "$T/out-a.crt"; then ok "the Secret holds the SERVED certificate -> written, byte-identical"
else bad "matching certificate" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi
if [ "$(stat -c %a "$T/out-a.crt" 2>/dev/null)" = 644 ]; then ok "written 0644 (a public anchor any consumer uid can read)"; else bad "mode" "$(stat -c %a "$T/out-a.crt" 2>&1)"; fi

printf 'KEEP-ME\n' > "$T/out-b.crt"
out="$(run "$T/b.crt" "$T/out-b.crt")"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'is NOT the one' && grep -qx 'KEEP-ME' "$T/out-b.crt"; then
  ok "a DIFFERENT valid certificate in the Secret -> refused, output untouched"
else bad "mismatched certificate" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi

# ONLY tls.crt is ever asked for: argocd-secret also holds the admin password and tls.key.
if grep -q 'get secret' "$T/klog" && ! grep 'get secret' "$T/klog" | grep -vqF -- '-o jsonpath={.data.tls\.crt}'; then
  ok "every secret read asks for .data.tls.crt and nothing else"
else bad "argv" "$(cat "$T/klog")"; fi

out="$(TLS_MODE=forbidden run "$T/a.crt" "$T/out-f.crt")"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'FORBIDDEN' && [ ! -e "$T/out-f.crt" ] && ! grep -q argocd-secret "$T/klog"; then
  ok "Forbidden on argocd-server-tls -> dies, does NOT fall through to argocd-secret"
else bad "forbidden" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi

out="$(TLS_MODE=present run "$T/a.crt" "$T/out-p.crt")"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'from lab/argocd-server-tls' && ! grep -q 'secret argocd-secret' "$T/klog"; then
  ok "argocd-server-tls present -> it is the source, argocd-secret is never read"
else bad "precedence" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi

out="$(NS_MODE=missing run "$T/a.crt" "$T/out-n.crt")"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'does not exist on this Supervisor' && ! printf '%s' "$out" | grep -q 'fetch-argocd-ca'; then
  ok "a wrong namespace says so, and does not steer to trust-on-first-use"
else bad "namespace" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi

fp_a="$(openssl x509 -in "$T/a.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
out="$(PIN="$fp_a" run "$T/a.crt" "$T/out-pin.crt")"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'matches ARGOCD_CA_SHA256'; then ok "a matching pin -> written"
else bad "pin match" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi
fp_b="$(openssl x509 -in "$T/b.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
out="$(PIN="$fp_b" run "$T/a.crt" "$T/out-pin2.crt")"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'does NOT match ARGOCD_CA_SHA256' && [ ! -e "$T/out-pin2.crt" ]; then
  ok "a contradicting pin -> refused, nothing written"
else bad "pin mismatch" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi
out="$(PIN=':::' run "$T/a.crt" "$T/out-pin3.crt")"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not a SHA-256 digest' && [ ! -e "$T/out-pin3.crt" ]; then
  ok "a malformed pin -> refused, never silently ignored"
else bad "pin malformed" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi

kill "$SRV" 2>/dev/null; SRV=""
out="$(run "$T/a.crt" "$T/out-c.crt")"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'did not present a certificate' && [ ! -e "$T/out-c.crt" ]; then
  ok "nothing served -> a CONNECTION problem, not a verdict; nothing written"
else bad "no listener" "rc=$rc $(printf '%s' "$out" | tail -2)"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
