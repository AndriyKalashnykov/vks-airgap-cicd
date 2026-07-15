#!/usr/bin/env bash
# test-argocd-preflight-ns.sh — 23-argocd-preflight must NOT hard-block `make install-all` when the
# ArgoCD namespace is absent on a DEFAULTED (guest) kubeconfig and the write mechanism is not kubectl.
#
# WHY (C12): the ns-NotFound branch used to `block` (exit 1) unconditionally, killing install-all before
# the 20-minute mirror for exactly the tenant scenario-2 targets (ArgoCD is a Supervisor Service, so the
# guest lacks its namespace) — while 70-configure-argocd.sh treats the same NotFound as warn+continue.
# The fix: block only for ARGOCD_MECHANISM=kubectl (the one path that needs the namespace); warn+continue
# otherwise.
#
# Offline via a stub kubectl (version ok, config view returns a server, `get ns` -> NotFound) + a temp
# REPO_ROOT (23 calls load_env; a copied .env.example with ARGOCD_MECHANISM stripped keeps the per-run
# ARGOCD_MECHANISM from being clobbered). No cluster.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# stub kubectl: skips '--kubeconfig <f>'; version ok; config view -> a server; get ns -> NotFound; else fail.
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args=("$@"); i=0; sub=""; kc=""
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in --kubeconfig) kc="${args[$((i+1))]}"; i=$((i+2));; *) sub="${args[$i]}"; break;; esac; done
rest=("${args[@]:$((i+1))}")
case "$sub" in
  version) echo '{}' ;;
  # server depends on the kubeconfig path, so a 'sup' kubeconfig != the guest -> argocd_is_off_cluster true (OFF=1).
  config)  case "$kc" in *sup*) echo 'https://supervisor:6443' ;; *) echo 'https://127.0.0.1:6443' ;; esac ;;
  get) case "${rest[0]:-}" in
         ns|namespace|namespaces) echo "Error from server (NotFound): namespaces \"${rest[1]:-x}\" not found" >&2; exit 1 ;;
         *) exit 1 ;;
       esac ;;
  auth) echo no ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"
# a throwaway kubeconfig (read only via the stub) + a controlled .env.example (no per-run ARGOCD_MECHANISM).
echo "apiVersion: v1" > "$TMP/kc"
# strip the per-run selectors from the temp .env.example so our env values aren't clobbered by it.
grep -vE '^ARGOCD_MECHANISM=|^ARGOCD_DEST_SERVER=' .env.example > "$TMP/.env.example"

run23() {  # $1 = ARGOCD_MECHANISM ('' = auto) ; $2 = ARGOCD_DEST_SERVER ('' = leave UNSET)
  local dest_env=(-u ARGOCD_DEST_SERVER)
  [ -n "${2:-}" ] && dest_env=(ARGOCD_DEST_SERVER="$2")
  env -u ARGOCD_KUBECONFIG -u HARBOR_URL -u HARBOR_CA_FILE "${dest_env[@]}" \
    PATH="$TMP/bin:$PATH" REPO_ROOT="$TMP" KUBECONFIG="$TMP/kc" \
    ARGOCD_NAMESPACE=argocd-instance-1 ARGOCD_MECHANISM="${1:-}" \
    bash scripts/23-argocd-preflight.sh >"$TMP/out" 2>&1
}

# auto (mechanism unset) + defaulted-guest kubeconfig + missing ns -> must NOT block (exit 0).
if run23 ""; then ok "auto: ns-NotFound on the defaulted guest kubeconfig -> warn+continue (exit 0)"; else bad "auto: 23 BLOCKED on ns-NotFound (the C12 regression)"; cat "$TMP/out" >&2; fi
# api, no destination -> must not block, AND must WARN about the missing destination (else PREFLIGHT OK
# is a false all-clear: gitops later dies at the 70 guard for a credentialed tenant who forgot the dest).
if run23 "api"; then ok "api: ns-NotFound -> continue (exit 0)"; else bad "api: 23 BLOCKED on ns-NotFound"; fi
if grep -q 'no deploy destination' "$TMP/out"; then ok "api + no ARGOCD_DEST_SERVER -> destination warn fires"; else bad "api + no dest -> destination warn MISSING (false all-clear before gitops dies)"; fi
# api WITH a destination -> exit 0 and NO destination warn.
if run23 "api" "https://guest.example:6443"; then ok "api + dest: exit 0"; else bad "api + dest: blocked unexpectedly"; fi
if grep -q 'no deploy destination' "$TMP/out"; then bad "api + dest set -> destination warn fired anyway"; else ok "api + dest set -> no destination warn"; fi
# kubectl -> MUST block (exit != 0): that path genuinely needs the namespace.
if run23 "kubectl"; then bad "kubectl: 23 did NOT block on ns-NotFound (kubectl needs the ns)"; else ok "kubectl: ns-NotFound -> blocks (exit 1)"; fi

# SCENARIO-1 ADMIN path: OFF=1 (ARGOCD_KUBECONFIG = Supervisor, a DIFFERENT server) + no dest. The admin
# legitimately leaves ARGOCD_DEST_SERVER unset (make gitops's 71-argocd-register-guest auto-derives it),
# so the destination warn must NOT fire — else the admin gets a false "gitops will REFUSE".
echo "apiVersion: v1" > "$TMP/sup.kc"
if env -u ARGOCD_DEST_SERVER -u HARBOR_URL -u HARBOR_CA_FILE \
     PATH="$TMP/bin:$PATH" REPO_ROOT="$TMP" KUBECONFIG="$TMP/kc" ARGOCD_KUBECONFIG="$TMP/sup.kc" \
     ARGOCD_NAMESPACE=argocd-instance-1 ARGOCD_MECHANISM=api \
     bash scripts/23-argocd-preflight.sh >"$TMP/out" 2>&1; then ok "admin (OFF=1) + no dest: exit 0"; else bad "admin (OFF=1) + no dest: blocked unexpectedly"; cat "$TMP/out" >&2; fi
if grep -q 'no deploy destination' "$TMP/out"; then bad "admin (OFF=1) + no dest -> destination warn FIRED (false positive on the Scenario-1 admin path)"; else ok "admin (OFF=1) + no dest -> no destination warn (correct)"; fi

if [ "$fail" -eq 0 ]; then echo "test-argocd-preflight-ns: OK"; else echo "test-argocd-preflight-ns: FAILED"; exit 1; fi
