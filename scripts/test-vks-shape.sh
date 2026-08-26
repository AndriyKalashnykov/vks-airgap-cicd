#!/usr/bin/env bash
# scripts/test-vks-shape.sh — offline unit test for vks-shape.sh (show + set). Fakes kubectl on
# PATH; touches no cluster.
#
# WHY. `wcp-vmfs` is THIS lab's VMFS policy name. An estate on vSAN or with a custom storage policy
# has a different one, so 25-vks-cluster-create.sh's code default fails there — and until now
# NOTHING discovered it (measured: zero references to VKS_STORAGE_CLASS in 02-env.sh).
#
# THE CASE THAT MATTERS IS THE AMBIGUOUS ONE. A wrong value pinned in .env is WORSE than no value,
# because .env OVERRIDES the code default that would otherwise have worked. So "two policies -> writes
# NOTHING" is the load-bearing assertion here, not the happy path.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# load_env requires .env.example AT REPO_ROOT — the harness points REPO_ROOT at $T, so it needs one.
cp .env.example "$T/.env.example"
printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$T/sup.kc"

# $2 is "name|min|max|deprecated" lines for READABILITY; the stub converts them to the JSON the
# product now asks for. The product moved from `-o jsonpath` to `-o json | jq` when the repo's
# sort -V ban forced it onto the shared vkey key — and this stub NOT being updated is what turned
# the three clusterclass cases RED, which is the evidence they are not vacuous.
mk_kubectl() { # $1 = storageClassName lines ; $2 = clusterclass lines (name|min|max|deprecated)
  printf '%s' "$1" > "$T/sc"
  printf '%s' "$2" | python3 -c '
import json,sys
items=[]
for ln in sys.stdin.read().splitlines():
    if not ln.strip(): continue
    n,mn,mx,d = (ln.split("|") + ["","","",""])[:4]
    lab={"kubernetes.vmware.com/version": n.rsplit("-",1)[-1],
         "kubernetes.vmware.com/min-version-supported": mn,
         "kubernetes.vmware.com/max-version-supported": mx}
    if d: lab["deprecated.kubernetes.vmware.com/deprecated"]=d
    items.append({"metadata":{"name":n,"labels":lab}})
json.dump({"items":items}, sys.stdout)' > "$T/cc"
  cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *storagepolicyquota*) cat "${STUB_DIR}/sc" ;;
  *clusterclass*)       cat "${STUB_DIR}/cc" ;;
esac
exit 0
EOF
  chmod +x "$T/bin/kubectl"
}

run() { # $1 = verb ; rest = extra env assignments
  local verb="$1"; shift
  env STUB_DIR="$T" PATH="$T/bin:$PATH" SKIP_DOTENV=1 REPO_ROOT="$T" \
      VKS_SUPERVISOR_KUBECONFIG="$T/sup.kc" "$@" \
      timeout 60 ./scripts/vks-shape.sh "$verb" 2>&1
}

CC3="builtin-generic-v3.6.0|v1.32|v1.35|
builtin-generic-v3.7.0|v1.33|v1.36|
builtin-generic-v3.3.0|v1.28|v1.32|true
"

# ---- show -------------------------------------------------------------------------------------
mk_kubectl "wcp-vmfs
wcp-vmfs-latebinding
" "$CC3"
out="$(run show VKS_NAMESPACE=cicd)"; rc=$?
[ $rc -eq 0 ] || bad "show must never gate (rc=$rc)"
[ $rc -eq 0 ] && ok "show exits 0"
if grep -q 'wcp-vmfs  *<- use this' <<<"$out"; then ok "show marks the immediate-binding class"; else bad "show did not mark wcp-vmfs"; fi
if grep -q 'wcp-vmfs-latebinding.*WaitForFirstConsumer' <<<"$out"; then ok "show flags the -latebinding sibling"; else bad "show did not flag latebinding"; fi
if grep -q 'builtin-generic-v3.3.0.*DEPRECATED' <<<"$out"; then ok "show marks a deprecated class"; else bad "show did not mark deprecated"; fi
if grep -q 'newest non-deprecated: builtin-generic-v3.7.0' <<<"$out"; then ok "show names what admission will pick"; else bad "show did not name the newest"; fi
# ---- set: unambiguous -------------------------------------------------------------------------
: > "$T/.env"
out="$(run set VKS_NAMESPACE=cicd)"
if grep -qx 'VKS_STORAGE_CLASS=wcp-vmfs' "$T/.env"; then ok "set writes the assigned storage class"; else bad "set did not write VKS_STORAGE_CLASS"; fi
if grep -qx 'VKS_CLUSTERCLASS=builtin-generic-v3.7.0' "$T/.env"; then ok "set writes the newest NON-deprecated class"; else bad "set wrote the wrong clusterclass"; fi
# ---- set: idempotent --------------------------------------------------------------------------
# NOT via run(): that sets SKIP_DOTENV=1, so load_env never reads the .env we just wrote and the
# second pass sees the vars UNSET — idempotence would be structurally unreachable and the case
# would fail for a harness reason. This one deliberately lets .env be read.
out="$(env STUB_DIR="$T" PATH="$T/bin:$PATH" REPO_ROOT="$T" \
        VKS_SUPERVISOR_KUBECONFIG="$T/sup.kc" VKS_NAMESPACE=cicd \
        timeout 60 ./scripts/vks-shape.sh set 2>&1)"
if grep -q 'already set' <<<"$out"; then ok "set is idempotent (does not overwrite)"; else bad "set overwrote an existing value"; fi
# ---- set: AMBIGUOUS must write NOTHING (the load-bearing case) ---------------------------------
mk_kubectl "wcp-vmfs
wcp-vsan
" "$CC3"
: > "$T/.env"
out="$(run set VKS_NAMESPACE=cicd)"
if grep -q '^VKS_STORAGE_CLASS=' "$T/.env"; then
  bad "AMBIGUOUS: set WROTE a storage class when two policies are assigned — a wrong pin overrides a working default"
else ok "AMBIGUOUS: set wrote NOTHING and left the default in force"; fi
if grep -q 'AMBIGUOUS' <<<"$out"; then ok "AMBIGUOUS: it says so, and lists the choices"; else bad "AMBIGUOUS: no explanation printed"; fi
# ---- degrade: no namespace --------------------------------------------------------------------
out="$(run show)"; rc=$?
if [ $rc -eq 0 ] && grep -q 'VKS_NAMESPACE is not set' <<<"$out"; then
  ok "no VKS_NAMESPACE: warns, exits 0 (per-NAMESPACE lookup is impossible)"
else bad "no VKS_NAMESPACE: should warn and exit 0"; fi

# ---- degrade: nothing readable (a tenant without RBAC) ----------------------------------------
mk_kubectl "" ""
: > "$T/.env"
out="$(run set VKS_NAMESPACE=cicd)"
if grep -q '^VKS_STORAGE_CLASS=' "$T/.env"; then bad "no-RBAC: wrote a value from an empty read"
else ok "no-RBAC: wrote nothing"; fi
if grep -q 'not discovered' <<<"$out"; then ok "no-RBAC: says it could not discover"; else bad "no-RBAC: silent"; fi
printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
