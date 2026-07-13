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

[ "$fail" = 0 ] && { echo "test-argocd-topology: OK"; exit 0; }
echo "test-argocd-topology: FAILED" >&2; exit 1
