#!/usr/bin/env bash
# test-istio-ownership.sh — B480. The two Istio install paths both create Deployment/istiod in
# $ISTIO_NAMESPACE and neither used to check whether the other already owned it.
#
# MEASURED on the live lab 2026-08-25: running the DOCUMENTED commands in the DOCUMENTED order let
# kapp ADOPT 30 of 50 helm-created objects; it then wants kapp.k14s.io/app inside istiod's IMMUTABLE
# spec.selector and the reconcile CAN NEVER CONVERGE. Not reversible: the mesh is left permanently
# mixed, with istio-cni-node still pulling from the PUBLIC registry.
#
# ⚠️ IT CANNOT BE REPRODUCED ON KinD -- packageinstalls/packagerepositories/apps.kappctrl are all
# ABSENT there, so 43 can never run and no adoption can occur. A behavioural RED therefore has to
# come from the lab or from a FIXTURE. This is the fixture, and it is the only form that runs in CI.
#
# ⚠️ THE LOAD-BEARING CASES ARE THE GREEN ONES. A guard written as "refuse on any foreign marker"
# passes every RED case here and still breaks the idempotency of the script it protects -- the
# own-path retry. That is the objection that killed an earlier sibling design, so both retries are
# asserted explicitly below.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0; ran=0
ok()  { printf '  ok    %s\n' "$1"; ran=$((ran+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; ran=$((ran+1)); }

STUB="$(mktemp -d)"; KC="$(mktemp)"; MODE="$(mktemp)"
trap 'rm -rf "$STUB" "$KC" "$MODE"' EXIT
printf 'apiVersion: v1\nkind: Config\ncurrent-context: c\nclusters: []\ncontexts: []\nusers: []\n' > "$KC"

# A kubectl stub whose behaviour is selected by a file, so each case is one write + one call.
cat > "$STUB/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
mode="$(cat "${OWNERSHIP_MODE_FILE:-/dev/null}" 2>/dev/null || true)"
case "$mode" in
  helm)    cat <<'J'
{"metadata":{"name":"istiod","labels":{"app.kubernetes.io/managed-by":"Helm"},
 "annotations":{"meta.helm.sh/release-name":"istiod","meta.helm.sh/release-namespace":"istio-system"}}}
J
           exit 0 ;;
  kapp)    printf '{"metadata":{"name":"istiod","labels":{"kapp.k14s.io/app":"1699"}}}\n'; exit 0 ;;
  both)    printf '{"metadata":{"name":"istiod","labels":{"kapp.k14s.io/app":"1699","app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"istiod"}}}\n'; exit 0 ;;
  foreign) printf '{"metadata":{"name":"istiod","labels":{"install.operator.istio.io/owning-resource":"x"}}}\n'; exit 0 ;;
  # The server's OWN NotFound prefix -- kube_is_notfound requires it AND the token on the SAME line.
  absent)  printf 'Error from server (NotFound): deployments.apps "istiod" not found\n' >&2; exit 1 ;;
  nons)    printf 'Error from server (NotFound): namespaces "istio-system" not found\n' >&2; exit 1 ;;
  forbid)  printf 'Error from server (Forbidden): deployments.apps "istiod" is forbidden\n' >&2; exit 1 ;;
  unreach) printf 'Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout\n' >&2; exit 1 ;;
  *)       printf 'stub: unknown mode\n' >&2; exit 1 ;;
esac
STUBEOF
chmod +x "$STUB/kubectl"

# ⚠️ DO NOT pass ISTIO_NAMESPACE / ISTIO_GATEWAY_NAMESPACE as env overrides here. The guard
# takes the namespace as its FIRST ARGUMENT, and the gateway namespace appears only inside an
# ESCAPED literal in the remedy text -- so neither is needed. Passing them makes
# check-env-clobber correctly refuse: it flags any var that is UNCOMMENTED in .env.example and
# ALSO passed as a per-run override, because load_env sources .env.example AFTER the override
# is in the environment, so the override LOSES. That this test also sets SKIP_DOTENV=1 (so
# load_env sources nothing at all) is not something a static gate can see -- and it should not
# have to be.
#
# `die` exits; run every assertion in a subshell and read the rc.
probe() {   # <mode> -> echoes the ownership token
  printf '%s' "$1" > "$MODE"
  ( set +e
    PATH="$STUB:$PATH" OWNERSHIP_MODE_FILE="$MODE" KUBECONFIG="$KC" SKIP_DOTENV=1 \
    bash -c '. scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/istio.sh >/dev/null 2>&1; istio_ownership istio-system' 2>/dev/null )
}
guard() {   # <mode> <helm|package> -> echoes the rc
  printf '%s' "$1" > "$MODE"
  ( set +e
    PATH="$STUB:$PATH" OWNERSHIP_MODE_FILE="$MODE" KUBECONFIG="$KC" SKIP_DOTENV=1 \
    bash -c ". scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/istio.sh >/dev/null 2>&1; istio_refuse_foreign_owner istio-system $2" >/dev/null 2>&1
    printf '%s' "$?" )
}
# if/then/else, NOT `A && B || C`: as the LAST statement of a function that form makes
# the function RETURN C's status (or B's), so a caller under `set -e` dies on a case that
# merely reported a failure. Same class as rules/shell §"a function whose LAST statement
# is `A && B`". `ok`/`bad` also tally, so their status must not leak out of here.
expect_token() {
  local got; got="$(probe "$1")"
  if [ "$got" = "$2" ]; then ok "$3"; else bad "$3 (want '$2', got '$got')"; fi
  return 0
}
expect_rc() {
  local got; got="$(guard "$1" "$2")"
  if [ "$got" = "$3" ]; then ok "$4"; else bad "$4 (want rc=$3, got rc=$got)"; fi
  return 0
}

echo "== istio_ownership: the classifier"
expect_token helm    helm    "helm-owned istiod    -> helm"
expect_token kapp    kapp    "kapp-owned istiod    -> kapp"
expect_token both    both    "BOTH markers         -> both (the damaged state is NAMED, not collapsed)"
expect_token foreign foreign "neither marker       -> foreign (istioctl/operator/hand-applied)"
expect_token absent  none    "provable NotFound    -> none (a legitimate first install)"
expect_token nons    none    "absent NAMESPACE     -> none"
expect_token forbid  unknown "Forbidden            -> unknown, NOT none (a tenant who cannot READ must not proceed)"
expect_token unreach unknown "unreachable          -> unknown, NOT none"

echo "== the guard: RED where it must refuse"
expect_rc helm    package 1 "package over HELM    -> REFUSE (kapp adopts; not reversible)"
expect_rc both    package 1 "package over BOTH    -> REFUSE"
expect_rc kapp    helm    1 "helm over KAPP       -> REFUSE before the CRD apply"
expect_rc both    helm    1 "helm over BOTH       -> REFUSE"
expect_rc foreign package 1 "package over FOREIGN -> REFUSE (would adopt a third party's mesh)"
expect_rc foreign helm    1 "helm over FOREIGN    -> REFUSE"
expect_rc forbid  package 1 "Forbidden            -> REFUSE (fail CLOSED)"
expect_rc forbid  helm    1 "Forbidden            -> REFUSE (fail CLOSED)"
expect_rc unreach package 1 "unreachable          -> REFUSE (fail CLOSED)"

echo "== the guard: GREEN where it MUST NOT refuse -- these are the load-bearing cases"
expect_rc absent  helm    0 "greenfield           -> helm proceeds"
expect_rc absent  package 0 "greenfield           -> package proceeds"
expect_rc helm    helm    0 "OWN-PATH RETRY helm  -> proceeds (idempotency of the guarded script)"
expect_rc kapp    package 0 "OWN-PATH RETRY pkg   -> proceeds (idempotency of the guarded script)"

echo "== DRY_RUN must not require a cluster"
printf 'unreach' > "$MODE"
drc="$( ( set +e
  PATH="$STUB:$PATH" OWNERSHIP_MODE_FILE="$MODE" KUBECONFIG="$KC" SKIP_DOTENV=1 DRY_RUN=1 \
  bash -c '. scripts/lib/os.sh >/dev/null 2>&1; . scripts/lib/istio.sh >/dev/null 2>&1; istio_refuse_foreign_owner istio-system package' >/dev/null 2>&1
  printf '%s' "$?" ) )"
if [ "$drc" = 0 ]; then
  ok "DRY_RUN=1 with an UNREACHABLE cluster -> proceeds (43 already skips its probe under it)"
else
  bad "DRY_RUN=1 -> want rc=0, got rc=$drc"
fi

printf '\n%s: %d case(s), %s\n' "$(basename "$0")" "$ran" "$( [ "$fail" -eq 0 ] && printf 'ALL PASS' || printf 'FAILURES ABOVE' )"
exit "$fail"
