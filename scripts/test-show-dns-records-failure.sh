#!/usr/bin/env bash
# ci-tier: fast — offline; a stub kubectl on PATH, no cluster, no network.
# test-show-dns-records-failure.sh — a FAILED Service list must not read as an EMPTY one.
#
# show-dns-records.sh listed Services with `2>/dev/null ... || true`, so an EXPIRED Supervisor login
# (Unauthorized) became zero rows: the operator was told "no LoadBalancer address -- wait for it", and
# with DNS_RECORDS_WAIT_SECONDS=900 (which that very message suggests) waited 15 minutes for an address
# no amount of waiting could show. MEASURED 2026-09-25 on a two-day-old supervisor.kubeconfig.
#
# Pins: Unauthorized -> fails FAST naming the expired login (even with a wait configured);
#       a genuinely empty list -> still "nothing to create";  an address -> its record row.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

mkdir -p "$T/bin"; printf 'apiVersion: v1\nkind: Config\n' > "$T/kc"
# shellcheck disable=SC2016  # the stub owns its own $vars
cat > "$T/bin/kubectl" <<'EOF'
#!/bin/sh
case "$*" in
  *"config view"*) echo "https://192.0.2.10:443"; exit 0 ;;
esac
case "${FAKE_MODE:-}" in
  unauthorized) echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1 ;;
  empty)        echo '{"items":[]}' ;;
  harbor)       echo '{"items":[{"metadata":{"namespace":"svc-harbor","name":"harbor-nginx"},"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.30"}]}}}]}' ;;
  argocd)       echo '{"items":[{"metadata":{"namespace":"lab","name":"argocd-server"},"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"192.0.2.40"}]}}}]}' ;;
esac
EOF
chmod +x "$T/bin/kubectl"

run() { env PATH="$T/bin:$PATH" SKIP_DOTENV=1 ARGOCD_KUBECONFIG="$T/kc" HARBOR_URL=harbor.example.test "$@" \
          bash scripts/show-dns-records.sh 2>&1; }

s=$SECONDS; out="$(run FAKE_MODE=unauthorized DNS_RECORDS_WAIT_SECONDS=30 DNS_RECORDS_WAIT_INTERVAL_SECONDS=5)"; rc=$?; el=$((SECONDS - s))
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REJECTED' && ! printf '%s' "$out" | grep -q 'nothing to create' && [ "$el" -lt 10 ]; then
  ok "Unauthorized: fails fast (${el}s, wait budget 30s) naming the expired login"
else bad "Unauthorized: rc=$rc ${el}s: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi

out="$(run FAKE_MODE=empty DNS_RECORDS_WAIT_SECONDS=0)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'nothing to create'; then ok "an EMPTY list still says there is nothing to create"
else bad "empty: rc=$rc: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi

out="$(run FAKE_MODE=harbor DNS_RECORDS_WAIT_SECONDS=0)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE 'harbor\.example\.test +192\.0\.2\.30'; then ok "an address prints its record row"
else bad "harbor: rc=$rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi

# B486: make argocd-address publishes the SINGLE-LABEL name argocd-server. It is not an A record: it
# reaches DNS only through a search domain, and only the jump box dials ArgoCD.
out="$(run FAKE_MODE=argocd ARGOCD_SERVER=argocd-server DNS_RECORDS_WAIT_SECONDS=0)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qF '192.0.2.40 argocd-server' <<< "$out" \
   && grep -qF '/etc/hosts on THIS jump box' <<< "$out" \
   && ! grep -qF 'Create these as A records' <<< "$out"; then ok "a single-label ArgoCD name is a hosts line, not an A record"
else bad "argocd single-label: rc=$rc: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"; fi
out="$(run FAKE_MODE=argocd ARGOCD_SERVER=argocd.lab.test DNS_RECORDS_WAIT_SECONDS=0)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qE 'argocd\.lab\.test +192\.0\.2\.40' <<< "$out"; then ok "CONTROL: a dotted ArgoCD name is still an A-record row"
else bad "argocd dotted: rc=$rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi

printf 'test-show-dns-records-failure: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
