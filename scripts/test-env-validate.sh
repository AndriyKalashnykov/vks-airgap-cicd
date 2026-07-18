#!/usr/bin/env bash
# test-env-validate.sh — env-validate and env-populate had ZERO tests; PR-3 changed both. This proves
# the RED for each.
#
# Fix 2 (env-validate TLS): the old code added `-k` when https + no HARBOR_CA_FILE — a SILENT skip-verify
#   that produced a green proving nothing about the trust anchor. Now it uses curl's default trust; a
#   self-signed Harbor with no CA fails on TLS (curl exit 60) and env-validate SAYS "TLS not trusted".
#   WITHOUT the fix the `-k` skip makes the same endpoint look reachable → the "TLS not trusted"
#   assertion below fails, i.e. the test goes RED (demonstrated: temporarily re-add the -k line).
# Fix 3 (env-populate guard): DISCOVER used to `env_set HARBOR_URL` UNCONDITIONALLY, so a guest LB IP
#   could overwrite a tenant's GRANTED value. Now it writes only over a placeholder.
#
# HERMETIC: a TEMP repo root with a copied .env.example + a fabricated .env (like test-env-check.sh); a
# real self-signed HTTPS endpoint via `openssl s_server`; a mock `kubectl` on PATH for the DISCOVER path.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVSH="$REPO/scripts/02-env.sh"
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }
SRV=""
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "$SRV" ] && kill "$SRV" 2>/dev/null' EXIT
cp "$REPO/.env.example" "$TMP/.env.example"
# Fixture isolation: comment HARBOR_URL/HARBOR_CA_FILE in the COPY so load_env can't re-inject the
# committed values over our fabricated .env (the .env is the only source of these in this test).
sed -ri 's/^(HARBOR_CA_FILE=|HARBOR_URL=)/# \1/' "$TMP/.env.example"

# --- a real self-signed HTTPS endpoint (SAN=IP:127.0.0.1 so curl --cacert matches the connect IP) -----
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 1 -nodes \
  -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 \
  || { echo "test-env-validate: openssl cert gen failed — cannot run"; exit 1; }
PORT=""
for p in $(seq 34443 34560); do
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { PORT="$p"; break; }   # connect FAILS => free
  exec 3>&- 3<&- 2>/dev/null || true
done
[ -n "$PORT" ] || { echo "test-env-validate: no free port"; exit 1; }
openssl s_server -accept "$PORT" -cert "$TMP/c.pem" -key "$TMP/k.pem" -www -quiet >/dev/null 2>&1 &
SRV=$!
up=0; for _ in $(seq 1 40); do curl -sk --max-time 1 "https://127.0.0.1:$PORT/" >/dev/null 2>&1 && { up=1; break; }; sleep 0.25; done
[ "$up" = 1 ] || { echo "test-env-validate: https test server did not come up on :$PORT"; exit 1; }

write_env() {  # $1 = HARBOR_URL ; $2 = HARBOR_CA_FILE (optional)
  cat > "$TMP/.env" <<EOF
HARBOR_URL=$1
HARBOR_USERNAME=admin
HARBOR_PASSWORD=Sup3rStr0ngPw
GITEA_ADMIN_PASSWORD=Sup3rStr0ngPw
VKS_AUTH_METHOD=kubeconfig
HARBOR_INSECURE=0
EOF
  [ -n "${2:-}" ] && echo "HARBOR_CA_FILE=$2" >> "$TMP/.env"
}
run_validate() {
  env -u HARBOR_URL -u HARBOR_CA_FILE -u KUBECONFIG -u VKS_STATE_FILE -u HARBOR_INSECURE \
    REPO_ROOT="$TMP" bash "$ENVSH" validate >"$TMP/out" 2>&1 || true
}

# RED (Fix 2) — self-signed https, NO CA -> env-validate reports "TLS not trusted".
write_env "127.0.0.1:$PORT" ""
run_validate
if grep -qi "TLS not trusted" "$TMP/out"; then ok "Fix2 RED: env-validate reports TLS-not-trusted on a self-signed Harbor with no CA"
else bad "Fix2 RED: env-validate did NOT report TLS-not-trusted (the -k silent-skip regression)"; cat "$TMP/out" >&2; fi

# GREEN (Fix 2) — same endpoint WITH the CA -> TLS verifies, so NOT the TLS-error branch.
write_env "127.0.0.1:$PORT" "$TMP/c.pem"
run_validate
if grep -qi "TLS not trusted" "$TMP/out"; then bad "Fix2 GREEN: env-validate wrongly said TLS-not-trusted WITH the CA (CA not exercised)"; cat "$TMP/out" >&2
else ok "Fix2 GREEN: with the CA the TLS handshake verifies (no TLS-not-trusted) — the CA is exercised"; fi

# RED (B13): with HARBOR_URL UNSET, env-validate must WARN-skip, not hard-error "HARBOR_URL is empty".
# The old format block errored on '' — dead code while .env.example shipped harbor.vks.local, ACTIVATED
# once B13 commented it (env-validate went PASS->FAIL on a partial .env). env-validate is the standalone
# reachability gate; env-check enforces presence. Revert the format-block '' branch to log_error and
# this case goes RED.
cat > "$TMP/.env" <<EOF
HARBOR_USERNAME=admin
HARBOR_PASSWORD=Sup3rStr0ngPw
GITEA_ADMIN_PASSWORD=Sup3rStr0ngPw
VKS_AUTH_METHOD=kubeconfig
EOF
run_validate
if grep -qi 'HARBOR_URL is empty' "$TMP/out"; then
  bad "B13 RED: env-validate HARD-ERRORED on an unset HARBOR_URL (the regression) — must WARN-skip"; cat "$TMP/out" >&2
elif grep -qiE 'HARBOR_URL not set yet|skipping.*reachability' "$TMP/out"; then
  ok "B13: env-validate WARN-skips an unset HARBOR_URL (standalone-runnable on a partial .env)"
else
  bad "B13: env-validate neither errored nor warn-skipped on an unset HARBOR_URL"; cat "$TMP/out" >&2
fi

kill "$SRV" 2>/dev/null; SRV=""

# --- Fix 3: env-populate DISCOVER must not clobber a GRANTED value -------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *cluster-info*)    exit 0 ;;
  *argocd-server*)   echo "10.11.12.14" ;;
  *"get svc"*)       echo "10.11.12.13" ;;
  *)                 : ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
: > "$TMP/fake.kc"
run_populate() {  # $1 = HARBOR_URL in .env
  cat > "$TMP/.env" <<EOF
HARBOR_URL=$1
HARBOR_USERNAME=admin
HARBOR_PASSWORD=Sup3rStr0ngPw
GITEA_ADMIN_PASSWORD=Sup3rStr0ngPw
VKS_AUTH_METHOD=kubeconfig
EOF
  env -u HARBOR_URL -u ARGOCD_SERVER -u KUBECONFIG -u VKS_STATE_FILE \
    PATH="$TMP/bin:$PATH" REPO_ROOT="$TMP" KUBECONFIG="$TMP/fake.kc" bash "$ENVSH" populate >"$TMP/pout" 2>&1 || true
}

run_populate "harbor.granted.example.com"
if grep -qxE 'HARBOR_URL=harbor\.granted\.example\.com' "$TMP/.env"; then ok "Fix3: env-populate did NOT overwrite a granted HARBOR_URL"
else bad "Fix3: env-populate CLOBBERED a granted HARBOR_URL with the discovered IP"; grep '^HARBOR_URL=' "$TMP/.env" >&2; fi

run_populate "harbor.vks.local"
if grep -qxE 'HARBOR_URL=10\.11\.12\.13' "$TMP/.env"; then ok "Fix3: env-populate filled the PLACEHOLDER HARBOR_URL from discovery"
else bad "Fix3: env-populate did NOT fill the placeholder HARBOR_URL"; grep '^HARBOR_URL=' "$TMP/.env" >&2; fi

if [ "$fail" -eq 0 ]; then echo "test-env-validate: OK"; else echo "test-env-validate: FAILED"; exit 1; fi
