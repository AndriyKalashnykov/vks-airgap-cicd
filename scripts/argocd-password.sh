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

# THE CLUSTER IS THE TRUTH, NOT `.env`.
#
# This used to print ARGOCD_ADMIN_PASSWORD from .env first, "because the KinD install applied it".
# It often did not: `make e2e-kind` runs with SKIP_DOTENV=1, so 07-install-argocd.sh never saw the
# .env value and never applied it — ArgoCD kept its AUTO-GENERATED password. But THIS script does
# not skip .env, so it printed the .env value anyway: a confidently-wrong password that does not
# log in. Telling someone a wrong password is worse than telling them nothing.
#
# The signal is exact: 07-install-argocd.sh DELETES `argocd-initial-admin-secret` when (and only
# when) it applies our password. So:
#   secret PRESENT -> the auto-generated password is in force; ours was NOT applied -> print theirs.
#   secret ABSENT  -> ours was applied (or ArgoCD is lab-provided) -> fall back to ARGOCD_ADMIN_PASSWORD.
# Ask the cluster first, and only believe .env when the cluster is unreachable or has no such secret.

# 1. The auto-generated initial-admin secret — if it EXISTS, it is the password in force.
if command -v kubectl >/dev/null 2>&1 && [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG:-}" ]; then
  export KUBECONFIG
  if enc="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
              -o jsonpath='{.data.password}' 2>/dev/null)" && [ -n "$enc" ]; then
    if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
      log_warn "ARGOCD_ADMIN_PASSWORD is set, but the cluster still has argocd-initial-admin-secret"
      log_warn "  -> your value was NEVER APPLIED (an install with SKIP_DOTENV=1 does not read .env)."
      log_warn "  -> printing the password that ACTUALLY works. To pin your own:"
      log_warn "     make install-argocd   (or: make e2e-kind E2E_SKIP_DOTENV=0)"
    fi
    printf '%s' "$enc" | base64 -d
    echo
    exit 0
  fi
fi

# 2. No initial-admin secret -> our password was applied (07 deletes it when it applies ours),
#    or ArgoCD is lab-provided and the operator set the value themselves.
if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
  printf '%s\n' "$ARGOCD_ADMIN_PASSWORD"
  exit 0
fi

# 3. Not knowable locally — VKS-provided, or the secret was rotated/removed.
log_error "No ArgoCD 'admin' password is available locally for this context."
log_error "  • real VKS: ArgoCD is provided by the lab — get the 'admin' password from your VKS lab."
log_error "  • KinD: set ARGOCD_ADMIN_PASSWORD in .env and re-run 'make install-argocd' for a known"
log_error "    login, or ensure the cluster is up so the generated 'argocd-initial-admin-secret' is readable."
exit 3
