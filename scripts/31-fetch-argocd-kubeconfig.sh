#!/usr/bin/env bash
# 31-fetch-argocd-kubeconfig.sh — obtain the SUPERVISOR kubeconfig that ArgoCD lives in, and write
# it to $ARGOCD_KUBECONFIG, so `make gitops` can register the guest cluster as an ArgoCD destination.
#
# WHY A SUPERVISOR KUBECONFIG:
#   On VCF/VKS, ArgoCD is a **Supervisor Service** — the operator + argocd-server run ON THE
#   SUPERVISOR (in a vSphere Namespace, e.g. argocd-instance-1), NOT in your guest/workload cluster.
#   Registering the guest as a destination therefore needs credentials for BOTH clusters:
#     KUBECONFIG        -> the GUEST cluster   (`make vks-login`, i.e. `vcf cluster kubeconfig get`)
#     ARGOCD_KUBECONFIG -> the SUPERVISOR      (this script)
#
# HOW (Broadcom, "Connect to the Supervisor as a vCenter Single Sign-On User" + "VCF CLI Context,
# Architecture, and Configuration"):
#   `vcf context create --endpoint <SUPERVISOR> --username <sso-user> ...` creates a Supervisor
#   context — "you can view the cluster context in the file .kube/config in the user's home
#   directory", and "the VCF CLI respects the KUBECONFIG environment variable for writing to
#   alternate locations". So we point KUBECONFIG at ARGOCD_KUBECONFIG while creating the context,
#   and the Supervisor kubeconfig lands in its own file instead of polluting ~/.kube/config.
#   Creating a Supervisor context also auto-creates the per-vSphere-Namespace contexts
#   (`<ctx>` and `<ctx>:<namespace>`), which is why we then `vcf context use <ctx>:<ns>`.
#
# PROVENANCE: the Broadcom 9.1 doc URLs 301-redirect to the 9.0 tree, so this flow is
# **documented for 9.0 and INFERRED for 9.1** — re-verify on a real 9.1 lab. It is also
# INTERACTIVE: `vcf context create` prompts for the password (no non-interactive flag is
# documented, and a password on argv is forbidden anyway).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd vcf "install the VCF Consumption CLI (make install-vcf-clis)"
require_cmd kubectl

# DEFAULTED, not `:?`. This was a hard `:?` on a variable the runbook never told the operator to set, so
# Scenario 1's Step 4 died on its only command — and then cascaded: with ARGOCD_KUBECONFIG unset,
# `make install-all`'s first prereq (preflight -> argocd-preflight) fell back to the GUEST kubeconfig and
# BLOCKED on "namespace 'argocd-...' not found on the ArgoCD cluster". The one command both runbooks tell
# you to run could not start. A path we can choose for you is not a question to ask you.
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-${REPO_ROOT}/secrets/argocd.kubeconfig}"
export ARGOCD_KUBECONFIG
log_info "SUPERVISOR kubeconfig -> ${ARGOCD_KUBECONFIG} (override with ARGOCD_KUBECONFIG in .env)"
: "${SUPERVISOR_HOST:?SUPERVISOR_HOST must be set in .env (the Supervisor IP/FQDN)}"
: "${VKS_USERNAME:?VKS_USERNAME must be set in .env (the vCenter SSO user)}"
: "${ARGOCD_NAMESPACE:?ARGOCD_NAMESPACE must be set in .env (the vSphere Namespace the ArgoCD instance runs in, e.g. argocd-instance-1)}"
SSO_DOMAIN="${VKS_SSO_DOMAIN:-vsphere.local}"
CTX="${ARGOCD_SUPERVISOR_CONTEXT:-argocd-supervisor}"

mkdir -p "$(dirname "$ARGOCD_KUBECONFIG")"

# TLS: prefer a CA cert; fall back to skip-verify only when the operator explicitly opts in.
TLS_ARGS=()
if [ -n "${VKS_CA_CERT_FILE:-}" ] && [ -f "${VKS_CA_CERT_FILE}" ]; then
  TLS_ARGS+=(--ca-certificate "$VKS_CA_CERT_FILE")
elif is_true "${VKS_INSECURE_SKIP_TLS_VERIFY:-}"; then
  # is_true, not `= "1"`. This tested `= "1"` while .env.example and docs/vks-authentication.md both
  # document `VKS_INSECURE_SKIP_TLS_VERIFY=true` (and 30-vks-login.sh tested `= "true"`), so an operator
  # who set the value THE REPO DOCUMENTS hit the die below demanding the value they had just set.
  log_warn "VKS_INSECURE_SKIP_TLS_VERIFY is set — skipping TLS verification of the Supervisor endpoint"
  TLS_ARGS+=(--insecure-skip-tls-verify)
else
  die "set VKS_CA_CERT_FILE=<path to the Supervisor CA cert> (how: ask the platform team, or
  'openssl s_client -connect \${SUPERVISOR_HOST}:443 -showcerts' and take the issuer), or set
  VKS_INSECURE_SKIP_TLS_VERIFY=true to skip verification."
fi

log_info "creating a SUPERVISOR context '${CTX}' at ${SUPERVISOR_HOST} as ${VKS_USERNAME}@${SSO_DOMAIN}"
log_info "  -> the kubeconfig is written to ARGOCD_KUBECONFIG=${ARGOCD_KUBECONFIG}"
log_info "  (interactive: the VCF CLI will prompt for the password — a password on argv is forbidden)"

# KUBECONFIG scopes WHERE the VCF CLI writes the context (Broadcom: it "respects the KUBECONFIG
# environment variable for writing to alternate locations"). Without this it would land in
# ~/.kube/config and silently mix the Supervisor in with the guest-cluster context.
KUBECONFIG="$ARGOCD_KUBECONFIG" run vcf context create "$CTX" \
  --endpoint "https://${SUPERVISOR_HOST}" \
  --username "${VKS_USERNAME}@${SSO_DOMAIN}" \
  --type k8s \
  "${TLS_ARGS[@]}"

# A Supervisor context auto-creates per-vSphere-Namespace contexts as `<ctx>:<namespace>`.
# ArgoCD lives in ARGOCD_NAMESPACE, so select that one.
log_info "selecting the vSphere-Namespace context '${CTX}:${ARGOCD_NAMESPACE}'"
KUBECONFIG="$ARGOCD_KUBECONFIG" run vcf context use "${CTX}:${ARGOCD_NAMESPACE}" \
  || log_warn "could not select '${CTX}:${ARGOCD_NAMESPACE}' — list them with: KUBECONFIG=${ARGOCD_KUBECONFIG} vcf context list"

# Prove the kubeconfig actually reaches the ArgoCD instance — a file that exists is not a file that works.
log_info "verifying the Supervisor kubeconfig can see the ArgoCD instance..."
if kubectl --kubeconfig "$ARGOCD_KUBECONFIG" -n "$ARGOCD_NAMESPACE" get deploy argocd-server >/dev/null 2>&1; then
  log_info "OK — argocd-server is visible in ns/${ARGOCD_NAMESPACE} via ${ARGOCD_KUBECONFIG}"
  log_info "next: make gitops   (it auto-invokes 'make argocd-register-guest' now that ARGOCD_KUBECONFIG is set)"
else
  log_error "the kubeconfig was written, but 'argocd-server' is NOT visible in ns/${ARGOCD_NAMESPACE}."
  log_error "  Check: kubectl --kubeconfig ${ARGOCD_KUBECONFIG} get ns"
  log_error "         kubectl --kubeconfig ${ARGOCD_KUBECONFIG} -n ${ARGOCD_NAMESPACE} get all"
  log_error "  Is ARGOCD_NAMESPACE the vSphere Namespace the ArgoCD instance really runs in?"
  exit 1
fi
