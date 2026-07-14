#!/usr/bin/env bash
# 24-lab-preflight.sh — READ-ONLY: three cluster preconditions that each KILL the run later.
#
# WHY THIS EXISTS
# --------------
# `make preflight` covered check-tools + argocd-preflight + psa-check — and NOT these three, so
# docs/scenario-1.md made the admin hand-type them:
#
#   kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io   # Tekton needs this
#   kubectl get storageclass                                                   # Gitea's PVC needs a DEFAULT
#   kubectl get svc -A --field-selector spec.type=LoadBalancer                 # Gitea needs an LB VIP
#
# Anything typed more than once is a missing make target: the operator had to know what "good" looked
# like for each, and `install-all`'s own gate never checked them at all. Each failure surfaces LATE —
# after the ~20-minute mirror — and none of them names its real cause when it does:
#
#   * no CRD-create permission -> Tekton's install fails midway with an RBAC error about a CRD
#   * no DEFAULT StorageClass  -> Gitea's PVC sits Pending forever; the pod never schedules and the
#                                 error you see is a timeout, not "you have no default StorageClass"
#   * no LoadBalancer provider -> Gitea's Service never gets an EXTERNAL-IP, so ArgoCD (which is
#                                 OFF-CLUSTER on a real lab) can never clone from it
#
# It is READ-ONLY: it changes nothing, and it is safe to run against a cluster you do not own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl

problems=0
ok()   { printf '  ok       %s\n' "$*" >&2; }
bad()  { printf '  PROBLEM  %s\n' "$*" >&2; problems=$((problems + 1)); }
note() { printf '           %s\n' "$*" >&2; }

printf '\n===================== lab preflight =====================\n' >&2
log_info "cluster: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
kubectl version -o json >/dev/null 2>&1 \
  || die "cannot reach the cluster with the current KUBECONFIG — run 'make vks-login' first"

# 1. CRDs — Tekton installs its own. Without this permission its install dies midway.
if [ "$(kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io 2>/dev/null)" = yes ]; then
  ok "may create CustomResourceDefinitions (Tekton installs its own)"
else
  bad "may NOT create CustomResourceDefinitions — Tekton cannot be installed."
  note "You need cluster-admin on this guest cluster. Ask your platform team, or use a cluster you own."
fi

# 2. A DEFAULT StorageClass — Gitea's PVC does not name one, so it gets the default. If there is no
#    default, the PVC stays Pending forever and the failure you see is a POD TIMEOUT, which names
#    nothing. Judge by the annotation the cluster ACTUALLY carries, not by the presence of any SC.
default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null || true)"
n_sc="$(kubectl get storageclass --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ -n "$default_sc" ]; then
  ok "default StorageClass: ${default_sc}(Gitea's PVC binds to it)"
elif [ "$n_sc" -gt 0 ]; then
  bad "there are ${n_sc} StorageClass(es) but NONE is marked default — Gitea's PVC will sit Pending forever."
  note "Mark one: kubectl annotate sc <name> storageclass.kubernetes.io/is-default-class=true"
  note "(The failure you would otherwise see is a pod timeout, which does not mention StorageClasses.)"
else
  bad "no StorageClass at all — Gitea's PVC can never bind."
fi

# 3. A working LoadBalancer provider. On a real lab ArgoCD is OFF-CLUSTER (a Supervisor Service), so it
#    cannot resolve gitea-http.gitea.svc — Gitea needs its OWN LoadBalancer VIP for ArgoCD to clone from.
#    We cannot prove a provider exists without creating a Service, and this script is read-only. So we
#    report the evidence we CAN see and say plainly what it does and does not prove.
lbs="$(kubectl get svc -A --field-selector spec.type=LoadBalancer --no-headers 2>/dev/null | wc -l | tr -d ' ')"
pending="$(kubectl get svc -A --field-selector spec.type=LoadBalancer \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '$2 == "" {print $1}' | tr '\n' ' ' || true)"
if [ "$lbs" -eq 0 ]; then
  note "no LoadBalancer Services exist yet, so a provider cannot be OBSERVED here."
  note "This is NOT a pass: if the cluster has no LB provider, Gitea's Service will never get an"
  note "EXTERNAL-IP and ArgoCD (off-cluster on a real lab) can never clone from it. If you are unsure,"
  note "ask your platform team whether this cluster has a LoadBalancer provider."
elif [ -n "$pending" ]; then
  bad "LoadBalancer Service(s) with NO external IP: ${pending}"
  note "A pending EXTERNAL-IP means no LB provider is assigning addresses. Gitea will hang the same way."
else
  ok "${lbs} LoadBalancer Service(s), all with an external IP — a provider is assigning addresses"
fi

printf '\n' >&2
if [ "$problems" -eq 0 ]; then
  log_info "LAB PREFLIGHT OK — CRDs, storage and load-balancing look right for this flow."
  log_info "  (Read the LoadBalancer note above if it said a provider could not be observed.)"
else
  log_error "LAB PREFLIGHT: ${problems} problem(s) above. Each one kills the run LATER — after the"
  log_error "  ~20-minute mirror — with an error that does not name this as the cause. Fix them first."
fi
printf '=========================================================\n' >&2
exit "$problems"
