#!/usr/bin/env bash
# 23-argocd-preflight.sh — reconcile ArgoCD VERSION + TOPOLOGY against the cluster the current
# KUBECONFIG targets, BEFORE `make gitops`. Answers the two lab questions the README real-lab
# flow flags (Part A2):
#   1. VERSION  — the VKS operator's supported server versions vs the running server vs the
#                 argocd CLI vs this repo's KinD pin (so you catch a server-generation delta).
#   2. TOPOLOGY — can this ArgoCD actually deploy into the workload namespace? The repo's
#                 Application uses the in-cluster destination (kubernetes.default.svc), so ArgoCD
#                 must run in THIS cluster (or the workload cluster must be REGISTERED with it).
#
# kubectl-only (the argocd CLI is optional — installed by `make deps`). This REPORTS; it does not
# gate the pipeline. Run it against a real lab OR the KinD stand-in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
: "${KUBECONFIG:?KUBECONFIG must be set (path to the workload-cluster kubeconfig)}"; export KUBECONFIG

NS="${ARGOCD_NAMESPACE:-argocd}"
DEST_NS="${ARGOCD_DEST_NAMESPACE:-webui}"
VKS_ARGOCD_CRD="argocds.argocd-service.vsphere.vmware.com"

log_info "cluster context: $(kubectl config current-context 2>/dev/null || echo '?')  (ARGOCD_NAMESPACE=$NS, ARGOCD_DEST_NAMESPACE=$DEST_NS)"

echo "── ArgoCD version ──"
if have argocd; then
  cli="$(argocd version --client --short 2>/dev/null || argocd version --client 2>/dev/null | head -1)"
  log_info "argocd CLI (client): ${cli:-unknown}"
else
  log_warn "argocd CLI not on PATH (install via 'make deps') — skipping client version"
fi

if kubectl get crd "$VKS_ARGOCD_CRD" >/dev/null 2>&1; then
  log_info "VKS ArgoCD operator CRD present — supported server versions (kubectl explain argocd.spec.version):"
  kubectl explain argocd.spec.version 2>/dev/null | sed 's/^/    /'
  echo "  ArgoCD instances on this cluster:"
  kubectl get argocd -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,VERSION:.spec.version' 2>/dev/null | sed 's/^/    /'
else
  log_warn "VKS ArgoCD operator CRD ($VKS_ARGOCD_CRD) NOT found — this is upstream ArgoCD (the KinD stand-in) or the operator isn't installed. 'kubectl explain argocd.spec.version' is a lab-only check."
fi

img="$(kubectl -n "$NS" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [ -n "$img" ]; then log_info "running argocd-server image (ns/$NS): $img"; else log_warn "no argocd-server deploy in namespace '$NS' on this cluster"; fi
log_info "repo KinD-stand-in pins: ARGOCD_VERSION=${ARGOCD_VERSION:-?}  ARGOCD_CLI_VERSION=${ARGOCD_CLI_VERSION:-?}"

echo "── ArgoCD topology ──"
same_cluster=0
# Capture (not `grep -q`): under `set -o pipefail`, `kubectl … | grep -q` makes grep exit early
# on a match → kubectl gets SIGPIPE → the pipeline reports non-zero → the `if` would read false
# even when the controller IS present. Read all input into a var and test it.
ac="$(kubectl -n "$NS" get statefulset,deploy -o name 2>/dev/null | grep application-controller || true)"
if [ -n "$ac" ]; then
  log_info "argocd-application-controller runs in THIS cluster (ns/$NS) → the Application's in-cluster destination (kubernetes.default.svc) deploys HERE."
  same_cluster=1
else
  log_warn "no argocd-application-controller in ns/$NS of THIS cluster."
fi

n_ext="$(kubectl -n "$NS" get secret -l argocd.argoproj.io/secret-type=cluster -o name 2>/dev/null | wc -l | tr -d ' ')"
log_info "external clusters registered with ArgoCD: $n_ext"
[ "${n_ext:-0}" -gt 0 ] && kubectl -n "$NS" get secret -l argocd.argoproj.io/secret-type=cluster \
  -o custom-columns='NAME:.metadata.name' --no-headers 2>/dev/null | sed 's/^/    - /'

if kubectl get ns "$DEST_NS" >/dev/null 2>&1; then
  log_info "target namespace '$DEST_NS' exists in THIS cluster."
else
  log_warn "target namespace '$DEST_NS' absent in THIS cluster (make platform/gitops creates it)."
fi

echo "── verdict ──"
if [ "$same_cluster" = 1 ]; then
  log_info "TOPOLOGY OK for the repo default — ArgoCD is in this cluster; the in-cluster destination deploys the app here. Confirm ARGOCD_DEST_NAMESPACE ($DEST_NS) is this cluster's intended app namespace."
else
  log_warn "TOPOLOGY MISMATCH — ArgoCD is NOT in this cluster. If your VKS ArgoCD instance runs on a SEPARATE cluster (e.g. the Supervisor), either: (a) REGISTER this workload cluster with ArgoCD and point the Application destination at it (not kubernetes.default.svc), or (b) run ArgoCD in this workload cluster. The repo's 'make gitops' assumes the in-cluster destination."
fi
