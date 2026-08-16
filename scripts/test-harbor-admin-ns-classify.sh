#!/usr/bin/env bash
# test-harbor-admin-ns-classify.sh — "I could not ask" must never be read as "no" (B110).
#
# MEASURED ON THE LIVE LAB 2026-08-16: same command, same cluster, same (correct) selector — a valid
# Supervisor kubeconfig returned 1 namespace and an EXPIRED one returned 0, and 28-harbor-admin-
# password.sh then printed "no Harbor Supervisor Service on this Supervisor - install it (Step 4)"
# while Harbor was running. The probe was `kubectl … 2>/dev/null || true`, so a transport failure was
# indistinguishable from an absent service. scenario-1 §4 tells the already-exists persona "Do not
# skip Step 8.5", and Step 8.5 IS that command — so the wrong message lands on the persona least
# able to argue with it.
#
# Offline: a stub kubectl emits each real failure shape and we assert the script names the RIGHT
# cause. The stub SKIPS --request-timeout positionally, exactly as test-argocd-preflight-ns.sh's does
# — the fix adds that flag, and a stub that does not know it mis-parses and looks like a product bug.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$TMP/sup.kubeconfig"

cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args=("$@"); i=0; sub=""
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in
  --kubeconfig) i=$((i+2));; --request-timeout=*) i=$((i+1));; --request-timeout) i=$((i+2));;
  *) sub="${args[$i]}"; break;; esac; done
case "$sub" in
  version) echo "Client Version: v1.34.0"; exit 0 ;;
  get) case "${STUB_MODE:-ok}" in
         stale_ca) echo 'Unable to connect to the server: tls: failed to verify certificate: x509: certificate signed by unknown authority' >&2; exit 1 ;;
         forbidden) echo 'Error from server (Forbidden): namespaces is forbidden: User "u" cannot list resource "namespaces" at the cluster scope' >&2; exit 1 ;;
         empty)    exit 0 ;;                       # authenticated, genuinely nothing there
         *)        echo "namespace/svc-harbor-abc12"; exit 0 ;;
       esac ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"

run() {   # run <STUB_MODE> [extra env assignments...]
  ( cd "$SCRIPT_DIR/.." && env PATH="$TMP/bin:$PATH" STUB_MODE="$1" SKIP_DOTENV=1 \
      VKS_SUPERVISOR_KUBECONFIG="$TMP/sup.kubeconfig" HARBOR_URL=harbor.example.test \
      HARBOR_INSECURE=1 "${@:2}" bash scripts/28-harbor-admin-password.sh ) >"$TMP/out" 2>&1
  return $?
}
saw() { grep -qi -- "$1" "$TMP/out"; }

# --- each transport failure must name ITS OWN cause, and never "install Harbor" -----------------
run stale_ca || true
if saw 'mints a new CA'; then ok "STALE_CA names the rebuilt-CA cause"; else bad "STALE_CA names the rebuilt-CA cause" "$(tail -2 "$TMP/out")"; fi
if saw 'install it (Step 4)'; then bad "STALE_CA must NOT say 'install it'" "it did"; else ok "STALE_CA does NOT say 'install it'"; fi

run forbidden || true
if saw 'RBAC GRANT'; then ok "FORBIDDEN names the grant, not a missing service"; else bad "FORBIDDEN names the grant" "$(tail -2 "$TMP/out")"; fi
if saw 'HARBOR_SERVICE_NAMESPACE'; then ok "FORBIDDEN offers the escape hatch"; else bad "FORBIDDEN offers the escape hatch" "no way forward for a tenant"; fi
if saw 'do NOT re-fetch'; then ok "FORBIDDEN does not send them to re-login"; else bad "FORBIDDEN does not send them to re-login" "wrong remedy"; fi

# --- a CLEAN zero result is genuinely absent, and must keep today's message ---------------------
run empty || true
if saw 'install it (Step 4)'; then ok "a CLEAN empty result still says 'install it (Step 4)'"; else bad "a CLEAN empty result still says 'install it (Step 4)'" "the true-negative message was lost"; fi

# --- the escape hatch skips discovery entirely --------------------------------------------------
run forbidden HARBOR_SERVICE_NAMESPACE=svc-harbor-given || true
if saw 'svc-harbor-given'; then ok "HARBOR_SERVICE_NAMESPACE bypasses the probe"; else bad "HARBOR_SERVICE_NAMESPACE bypasses the probe" "$(tail -2 "$TMP/out")"; fi
if saw 'RBAC GRANT'; then bad "...and does not run the probe at all" "it still probed"; else ok "...and does not run the probe at all"; fi

echo
echo "harbor-admin ns classify: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
