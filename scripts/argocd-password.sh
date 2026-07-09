#!/usr/bin/env bash
# argocd-password.sh — print the ArgoCD 'admin' password for the CURRENT context.
#
# Fluid across BOTH contexts (VKS-provided ArgoCD and the KinD-installed stand-in):
# it self-resolves KUBECONFIG from .env/.env.kind (no kube-context juggling) and picks
# the password source by precedence, degrading gracefully:
#
#   1. ARGOCD_ADMIN_PASSWORD (.env) — the value the KinD install applied. Works even
#      with the cluster down; the natural path when the operator chose a known login.
#   2. else the auto-generated `argocd-initial-admin-secret`, read from the cluster —
#      the default KinD path, and a real VKS lab that kept the initial secret.
#   3. else ArgoCD is VKS-provided (or the secret was rotated/removed) → print guidance
#      to stderr and exit non-zero; the password is not knowable locally.
#
# stdout carries ONLY the password (so it pipes cleanly); diagnostics go to stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# 1. Operator-set password from .env (the KinD install applied it). No cluster needed.
if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
  printf '%s\n' "$ARGOCD_ADMIN_PASSWORD"
  exit 0
fi

# 2. Auto-generated initial-admin secret — needs cluster access.
require_cmd kubectl
: "${KUBECONFIG:?KUBECONFIG not set — is the cluster up? (written to .env.kind by the KinD flow)}"
export KUBECONFIG
if enc="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' 2>/dev/null)" && [ -n "$enc" ]; then
  printf '%s' "$enc" | base64 -d
  echo
  exit 0
fi

# 3. Not knowable locally — VKS-provided, or the secret was rotated/removed.
log_error "No ArgoCD 'admin' password is available locally for this context."
log_error "  • real VKS: ArgoCD is provided by the lab — get the 'admin' password from your VKS lab."
log_error "  • KinD: set ARGOCD_ADMIN_PASSWORD in .env and re-run 'make install-argocd' for a known"
log_error "    login, or ensure the cluster is up so the generated 'argocd-initial-admin-secret' is readable."
exit 3
