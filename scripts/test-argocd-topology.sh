#!/usr/bin/env bash
# test-argocd-topology.sh — unit-test lib/argocd.sh: the two guards that stand between this demo and
# the two CRITICAL bugs that made the REAL LAB impossible.
#
# THE BUGS THESE GUARDS EXIST TO PREVENT (both shipped; neither was reproducible on KinD):
#
#   #1  70-configure-argocd.sh applied the ArgoCD Application + repo Secret to $KUBECONFIG — the
#       GUEST cluster. ArgoCD is a VCF Supervisor SERVICE: it runs on the SUPERVISOR. So `make
#       gitops` died on a real lab at its own namespace check. Fixing that (apply to the ArgoCD
#       cluster instead) is necessary — but ON ITS OWN IT IS MORE DANGEROUS THAN THE BUG: the
#       destination still defaulted to `https://kubernetes.default.svc` = "the cluster ArgoCD runs
#       in" = the SUPERVISOR, so the first misconfigured run would deploy the tenant's app, with
#       prune+selfHeal, onto the Supervisor. Hence argocd_is_off_cluster: DERIVE the topology from
#       the two kubeconfigs, never remember it from a file (the file is `.env.kind`, which
#       `make kind-down` deletes).
#
#   #2  The Application's repoURL was the guest's cluster-local Gitea DNS name
#       (gitea-http.gitea.svc:3000). An off-cluster repo-server cannot resolve it — every sync fails
#       with `dial tcp: lookup ...`, and because an Application ArgoCD never reconciled has NO
#       status at all, it fails SILENTLY. Hence argocd_assert_clonable_url.
#
# Offline by construction: `kubectl config view` PARSES the kubeconfig file, it never dials the API
# server — so both guards are fully testable with two synthetic files and no cluster.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

command -v kubectl >/dev/null 2>&1 || { echo "SKIP: kubectl not installed"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0

mk_kubeconfig() { # <file> <api-server>
  cat > "$1" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: c
    cluster: { server: $2 }
contexts:
  - name: c
    context: { cluster: c, user: u }
current-context: c
users:
  - name: u
    user: {}
EOF
}

GUEST="${WORK}/guest.kubeconfig"; mk_kubeconfig "$GUEST" "https://guest.example:6443"
SUPER="${WORK}/supervisor.kubeconfig"; mk_kubeconfig "$SUPER" "https://supervisor.example:6443"

ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# --- 1. topology is DERIVED, not remembered -------------------------------------------------------
if argocd_is_off_cluster "$SUPER" "$GUEST"; then
  ok "off-cluster DETECTED (ArgoCD on the Supervisor, workload in the guest)"
else
  bad "off-cluster NOT detected — 70 would apply to the wrong cluster / deploy onto the Supervisor"
fi

if argocd_is_off_cluster "$GUEST" "$GUEST"; then
  bad "same-cluster wrongly reported as off-cluster (this is KinD — it must stay byte-identical)"
else
  ok "same-cluster DETECTED (KinD / ArgoCD-in-guest) — the in-cluster destination stays correct"
fi

# --- 2. the clonable-URL guard: the RED that matters ----------------------------------------------
# Run in a subshell: the guard calls die (exit 1). We assert on the EXIT CODE, not on a log line.
guard() { # <off> <url> ; returns the guard's exit code
  ( argocd_assert_clonable_url "$1" "$2" gitea gitea.vks.local >/dev/null 2>&1 )
}

# RED — an off-cluster ArgoCD pointed at cluster-local addresses MUST be refused. These are exactly
# the values that shipped (the .svc one) or that a reader would reach for next.
for url in \
  "http://gitea-http.gitea.svc:3000" \
  "http://gitea-http.gitea.svc.cluster.local:3000" \
  "http://localhost:3000" \
  "http://127.0.0.1:3000"
do
  if guard 1 "$url"; then
    bad "off-cluster + '${url}' was ACCEPTED — the guard is blind; every Application would fail to clone"
  else
    ok  "off-cluster + '${url}' REFUSED (the #2 CRITICAL cannot ship again)"
  fi
done

# GREEN — a real, routable address (Gitea's own LoadBalancer) must pass.
for url in "http://172.18.0.9:3000" "http://gitea.corp.example:3000"; do
  if guard 1 "$url"; then
    ok  "off-cluster + '${url}' ACCEPTED (a routable address is what the LoadBalancer publishes)"
  else
    bad "off-cluster + '${url}' was REFUSED — the guard is over-eager and blocks the correct fix"
  fi
done

# GREEN — when ArgoCD is IN the cluster, the cluster-local URL is CORRECT and must not be refused.
# This is the KinD path: it must remain byte-identical, or the guard breaks the working demo.
if guard 0 "http://gitea-http.gitea.svc:3000"; then
  ok  "in-cluster + '.svc' ACCEPTED (KinD is unaffected — the guard only fires when it must)"
else
  bad "in-cluster + '.svc' was REFUSED — the guard would break the single-cluster/KinD path"
fi

# --- 3. the destination must be matched EXACTLY, never guessed -----------------------------------
# The first version of the cross-cluster fix took `.items[0]` of the registered Cluster Secrets. On a
# SHARED ArgoCD (the real-lab TENANT case) that is an ARBITRARY cluster — and the Application carries
# prune:true + selfHeal:true, so "arbitrary" means deploying this tenant's app into ANOTHER TENANT'S
# CLUSTER and pruning what does not match. KinD cannot show it: one cluster, one Secret, items[0] is
# always right. These cases are the only thing standing between that bug and a real lab.
GUEST_API="https://guest.example:6443"
OTHER_API="https://other-tenant.example:6443"
SHARED="$(printf 'cluster-other\t%s\ncluster-guest\t%s\ncluster-third\thttps://third.example:6443\n' "$OTHER_API" "$GUEST_API")"

got="$(printf '%s' "$SHARED" | argocd_pick_dest_server "$GUEST_API" "" || true)"
if [ "$got" = "$GUEST_API" ]; then
  ok "shared ArgoCD: picked OUR cluster by API URL (not the first item)"
else
  bad "shared ArgoCD: picked '$got' instead of our own cluster ($GUEST_API) — CAN DEPLOY INTO ANOTHER TENANT'S CLUSTER"
fi

got="$(printf '%s' "$SHARED" | argocd_pick_dest_server "" "cluster-guest" || true)"
if [ "$got" = "$GUEST_API" ]; then
  ok "shared ArgoCD: picked our cluster by registered NAME"
else
  bad "shared ArgoCD: name match failed (got '$got')"
fi

# THE CRITICAL CASE: several registered clusters and NONE is ours -> we must REFUSE, not guess.
NONE_OURS="$(printf 'cluster-other\t%s\ncluster-third\thttps://third.example:6443\n' "$OTHER_API")"
if got="$(printf '%s' "$NONE_OURS" | argocd_pick_dest_server "$GUEST_API" "")" && [ -n "$got" ]; then
  bad "AMBIGUOUS destination was RESOLVED to '$got' — this is the bug: it would deploy into someone else's cluster"
else
  ok  "AMBIGUOUS destination REFUSED (no registered cluster is ours) — the tenant-safety guard holds"
fi

# Exactly one registered cluster is unambiguous even if the URL differs (a VIP vs a hostname).
ONE="$(printf 'cluster-guest\thttps://vip.example:6443\n')"
got="$(printf '%s' "$ONE" | argocd_pick_dest_server "$GUEST_API" "" || true)"
if [ "$got" = "https://vip.example:6443" ]; then
  ok  "single registered cluster: unambiguous, taken (ArgoCD may dial a VIP, not your kubeconfig's URL)"
else
  bad "single registered cluster was refused (got '$got') — this breaks the normal cross-cluster case"
fi

# --- 4. the cluster-list template must read the RIGHT FIELD --------------------------------------
# An ArgoCD cluster Secret keeps the cluster's real name in `data.name`; `metadata.name` is a
# PREFIXED object name (`cluster-<name>` — see 71-argocd-register-guest.sh). Reading metadata.name
# made the by-NAME tiebreak DEAD: ARGOCD_DEST_CLUSTER_NAME=vks-guest can never equal
# `cluster-vks-guest`. That tiebreak is the ONLY reliable selector on a shared lab, because the guest
# API URL ArgoCD dials often differs from the operator's kubeconfig — so without it everything falls
# through to "AMBIGUOUS -- refusing" and the tenant simply cannot deploy.
# kubectl cannot render a go-template without an API server, so the EXPRESSION is what we gate.
case "$ARGOCD_CLUSTER_LIST_TEMPLATE" in
  *'.data.name'*) ok "cluster-list template reads .data.name (the cluster's real name)" ;;
  *) bad "cluster-list template does NOT read .data.name — the by-name tiebreak is DEAD on a shared lab" ;;
esac
case "$ARGOCD_CLUSTER_LIST_TEMPLATE" in
  *'.metadata.name'*) bad "cluster-list template reads .metadata.name — that is 'cluster-<name>', NOT the cluster name" ;;
  *) ok "cluster-list template does not use .metadata.name" ;;
esac
# And the consumer must actually USE the constant (not re-inline a stale template).
# shellcheck disable=SC2016  # a literal grep pattern; $ARGOCD_... must NOT expand here
if grep -q 'go-template="\$ARGOCD_CLUSTER_LIST_TEMPLATE"' "${SCRIPT_DIR}/70-configure-argocd.sh"; then
  ok "70-configure-argocd.sh uses the shared template constant"
else
  bad "70-configure-argocd.sh does NOT use ARGOCD_CLUSTER_LIST_TEMPLATE — the contract can drift"
fi

# The name the register step writes is what the tiebreak must match (data.name == DEST_NAME).
got="$(printf 'vks-guest\thttps://vip.example:6443\ncluster-other\thttps://other:6443\n' \
       | argocd_pick_dest_server "https://not-matching:6443" "vks-guest" || true)"
if [ "$got" = "https://vip.example:6443" ]; then
  ok  "ARGOCD_DEST_CLUSTER_NAME tiebreak resolves the guest even when the API URL does not match"
else
  bad "ARGOCD_DEST_CLUSTER_NAME tiebreak failed (got '$got') — a shared-lab tenant could not deploy"
fi

# ---------------------------------------------------------------------------------------------
# 3. A PREFLIGHT MAY ONLY BLOCK ON WHAT THE OPERATOR CAN FIX RIGHT NOW.
#
# `make preflight` is the FIRST prerequisite of `make install-all`. GITEA_ARGOCD_URL is DISCOVERED
# later, by 40-install-gitea.sh inside `make platform`. So preflight used to BLOCK, on every real-lab
# first run, on a value that CANNOT EXIST YET — killing the one command both runbooks tell the
# operator to run, before the mirror even started. Invisible on KinD (ArgoCD is in-cluster there, so
# the off-cluster branch never runs).
PF="${SCRIPT_DIR}/23-argocd-preflight.sh"
if grep -qE 'GITEA_CLONE_URL="\$\{GITEA_ARGOCD_URL:-\$\{GITEA_INTERNAL_URL' "$PF" ; then
  bad "preflight still blocks via the GITEA_INTERNAL_URL FALLBACK — on a real lab that value is cluster-local by definition, so 'make install-all' dies at its own preflight before the mirror"
else
  ok "preflight does not block on the cluster-local fallback for a value 'make platform' has not published yet"
fi
if grep -qE 'block .*GITEA_ARGOCD_URL_OVERRIDE is a CLUSTER-LOCAL' "$PF"; then
  ok "preflight still BLOCKS a cluster-local GITEA_ARGOCD_URL_OVERRIDE (an operator-set value IS fixable now)"
else
  bad "preflight no longer blocks a cluster-local GITEA_ARGOCD_URL_OVERRIDE — the real guard was lost"
fi

# The clone URL must be RESOLVED from the live Service, never READ BACK from published state.
# 40-install-gitea.sh used to publish GITEA_ARGOCD_URL and 70 read it back as an input — so a STALE
# address was indistinguishable from a deliberate override, and a rebuilt Gitea would be cloned from
# the OLD LB IP. (Same trap INGRESS_LB_IP_OVERRIDE already exists to avoid.)
if sed 's/#.*//' "${SCRIPT_DIR}/40-install-gitea.sh" | grep -qE 'set_env_var[[:space:]]+GITEA_ARGOCD_URL'; then
  bad "40-install-gitea.sh PUBLISHES GITEA_ARGOCD_URL — 70 would read back its own previous answer (a stale address is then indistinguishable from an override)"
else
  ok "40-install-gitea.sh does not publish GITEA_ARGOCD_URL as an input"
fi
if sed 's/#.*//' "${SCRIPT_DIR}/70-configure-argocd.sh" | grep -qE 'GITEA_ARGOCD_URL="\$\{GITEA_ARGOCD_URL:-'; then
  bad "70-configure-argocd.sh READS BACK GITEA_ARGOCD_URL as an input instead of resolving it from the live Gitea Service"
else
  ok "70-configure-argocd.sh resolves the clone URL from the live Gitea Service (override: GITEA_ARGOCD_URL_OVERRIDE)"
fi

[ "$fail" = 0 ] && { echo "test-argocd-topology: OK"; exit 0; }
echo "test-argocd-topology: FAILED" >&2; exit 1
