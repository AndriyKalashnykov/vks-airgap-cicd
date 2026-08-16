#!/usr/bin/env bash
# ci-tier: slow — asserts the wait loop runs its full budget, `[ "$el" -ge 15 ]` (~30s)
# test-tkr-classify.sh — 24-vks-k8s-version.sh must not spend 900s to reach a wrong conclusion (B110).
#
# WHAT IT USED TO DO. `_newest_ready` was one pipeline ending in `tail -1`, so kubectl's rc was lost,
# and `2>/dev/null` threw the reason away. Any transport failure therefore looked like "no releases
# are Ready yet": the script entered its wait loop, burned up to VKS_TKR_WAIT_SECONDS (default 900),
# and then declared
#     Every release is published but unusable, which is a Supervisor/content-library problem
# — a confident platform diagnosis derived from a connection that never succeeded. Waiting cannot fix
# a stale CA or a missing grant.
#
# ASSERT ELAPSED, NOT ONLY rc. The old path also exits non-zero at its timeout, so rc alone cannot
# tell "refused up front" from "burned the budget" — which is the entire point.
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
         stale_ca)  echo 'Unable to connect to the server: tls: failed to verify certificate: x509: certificate signed by unknown authority' >&2; exit 1 ;;
         forbidden) echo 'Error from server (Forbidden): kubernetesreleases is forbidden: User "u" cannot list resource "kubernetesreleases"' >&2; exit 1 ;;
         none)      exit 0 ;;                                  # reachable, genuinely nothing Ready
         *)         echo "x v1.35.5+vmware.1 True True"; exit 0 ;;
       esac ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"

run() {   # run <STUB_MODE> <wait_seconds> -> "<rc> <elapsed>"
  local t0=$SECONDS rc
  ( cd "$SCRIPT_DIR/.." && env PATH="$TMP/bin:$PATH" STUB_MODE="$1" SKIP_DOTENV=1 \
      VKS_SUPERVISOR_KUBECONFIG="$TMP/sup.kubeconfig" VKS_TKR_WAIT_SECONDS="$2" \
      bash scripts/24-vks-k8s-version.sh ) >"$TMP/out" 2>&1
  rc=$?; printf '%s %s' "$rc" "$((SECONDS - t0))"
}
saw() { grep -qi -- "$1" "$TMP/out"; }

# --- a transport failure must refuse UP FRONT, not after the budget -----------------------------
read -r rc el <<<"$(run stale_ca 30)"
if [ "$rc" -ne 0 ]; then ok "STALE_CA refuses (rc=$rc)"; else bad "STALE_CA refuses" "rc=0"; fi
if [ "$el" -lt 5 ]; then ok "STALE_CA refuses UP FRONT (${el}s, budget was 30s)"
else bad "STALE_CA refuses UP FRONT" "took ${el}s — it burned the wait budget"; fi
if saw 'content-library'; then bad "STALE_CA must NOT blame the content library" "it did"; else ok "STALE_CA does NOT blame the content library"; fi
if saw 'mints a new CA'; then ok "STALE_CA names the rebuilt-CA cause"; else bad "STALE_CA names the rebuilt-CA cause" "$(tail -2 "$TMP/out")"; fi

read -r rc el <<<"$(run forbidden 30)"
if saw 'RBAC GRANT'; then ok "FORBIDDEN names the grant"; else bad "FORBIDDEN names the grant" "$(tail -2 "$TMP/out")"; fi
if [ "$el" -lt 5 ]; then ok "FORBIDDEN refuses UP FRONT (${el}s)"; else bad "FORBIDDEN refuses UP FRONT" "took ${el}s"; fi

# --- a REACHABLE Supervisor with nothing Ready must still WAIT, and keep its own message ---------
read -r rc el <<<"$(run none 16)"
if [ "$el" -ge 15 ]; then ok "reachable-but-empty still WAITS (${el}s >= 16s budget)"
else bad "reachable-but-empty still WAITS" "returned after ${el}s — a provisioning Supervisor was refused"; fi
if saw 'content-library'; then ok "...and keeps the content-library message, which is correct THERE"
else bad "...and keeps the content-library message" "the true-negative message was lost"; fi

echo
echo "tkr classify: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
