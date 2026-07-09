#!/usr/bin/env bash
# 07-install-argocd.sh — install ArgoCD into the KinD cluster as the LOCAL
# stand-in for the "VKS-provided" ArgoCD.
#
# VKS provides ArgoCD in the real environment; for a self-contained local
# demo we install the same pinned upstream release into KinD so that the
# downstream `make gitops` (creates an ArgoCD Application) and `make verify`
# (end-to-end smoke) run unchanged against the kind cluster.
#
# Idempotent: safe to re-run. Uses SERVER-SIDE apply for the install manifest
# (its CRDs exceed the client-side last-applied-configuration 256KB annotation
# limit — a plain `kubectl apply -f` fails with "metadata.annotations: Too long").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl

: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG
: "${ARGOCD_VERSION:?ARGOCD_VERSION must be set in .env.example}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

# The one allowed literal: the argoproj GitHub raw install manifest path,
# parameterized by the pinned ${ARGOCD_VERSION}.
INSTALL_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# ---------------------------------------------------------------------------
# wait_ready <kind/name> — poll `kubectl rollout status` until the workload is
# ready or the overall READY_TIMEOUT_SECONDS deadline elapses. The inter-poll
# `sleep` is a delay between attempts, NOT the readiness gate itself (the gate
# is the rollout-status success). On timeout, dump pods and die.
# ---------------------------------------------------------------------------
wait_ready() {
  local target="$1" deadline elapsed=0
  deadline="$READY_TIMEOUT_SECONDS"
  log_info "waiting for ${target} to become ready (timeout ${deadline}s, poll ${POLL_INTERVAL_SECONDS}s)"
  while :; do
    if kubectl -n "$ARGOCD_NAMESPACE" rollout status "$target" \
         --timeout="${POLL_INTERVAL_SECONDS}s" >/dev/null 2>&1; then
      log_info "${target} is ready"
      return 0
    fi
    elapsed=$(( elapsed + POLL_INTERVAL_SECONDS ))
    if [ "$elapsed" -ge "$deadline" ]; then
      log_error "timed out after ${deadline}s waiting for ${target}"
      kubectl -n "$ARGOCD_NAMESPACE" get pods >&2 || true
      die "ArgoCD workload ${target} did not become ready within ${deadline}s"
    fi
    log_info "${target} not ready yet (${elapsed}/${deadline}s); retrying"
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

# 1. Namespace (idempotent).
log_info "ensuring namespace ${ARGOCD_NAMESPACE}"
run bash -c "kubectl create namespace \"$ARGOCD_NAMESPACE\" --dry-run=client -o yaml | kubectl apply -f -"

# 2. Install ArgoCD from the pinned upstream manifest via server-side apply.
#    Download to a per-version cache with retry/backoff first: raw.githubusercontent.com
#    rate-limits (HTTP 429), and `kubectl apply -f <url>` fetches with no retry, so a
#    transient 429 would otherwise fail the whole install. The cache also makes re-runs
#    offline-friendly once the manifest has been fetched at least once.
ARGOCD_MANIFEST_CACHE="${ARGOCD_MANIFEST_CACHE:-${TMPDIR:-/tmp}/vks-airgap-cicd-manifests}"
MANIFEST_FILE="${ARGOCD_MANIFEST_CACHE}/argocd-install-${ARGOCD_VERSION}.yaml"
mkdir -p "$ARGOCD_MANIFEST_CACHE"
if [ ! -s "$MANIFEST_FILE" ]; then
  log_info "fetching ArgoCD ${ARGOCD_VERSION} install manifest (retry/backoff) -> ${MANIFEST_FILE}"
  http_get_retry "$INSTALL_MANIFEST" "$MANIFEST_FILE"
else
  log_info "using cached ArgoCD ${ARGOCD_VERSION} install manifest: ${MANIFEST_FILE}"
fi
log_info "installing ArgoCD ${ARGOCD_VERSION} into ${ARGOCD_NAMESPACE} (server-side apply)"
run kubectl apply -n "$ARGOCD_NAMESPACE" --server-side --force-conflicts -f "$MANIFEST_FILE"

# 3. Readiness — gate on the core workloads (poll loop, not a bare sleep).
wait_ready deploy/argocd-server
wait_ready deploy/argocd-repo-server
wait_ready deploy/argocd-redis
wait_ready statefulset/argocd-application-controller

# 4. Local-demo convenience: run the API/UI server in insecure (HTTP) mode so
# it is reachable without TLS wrangling / cert trust in the local KinD demo.
# This is NOT for production — the real VKS-provided ArgoCD terminates TLS.
log_info "patching argocd-cmd-params-cm to enable server.insecure (local demo convenience)"
run kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
  --type merge -p '{"data":{"server.insecure":"true"}}'
# Restart the server so it picks up the config change, then re-gate readiness.
run kubectl -n "$ARGOCD_NAMESPACE" rollout restart deploy/argocd-server
wait_ready deploy/argocd-server

# 5. Summary — show HOW to read the admin password; never print it or place it
# on argv (the command is emitted for the operator to run, not executed here).
log_info "ArgoCD ${ARGOCD_VERSION} installed in namespace ${ARGOCD_NAMESPACE}."
log_info "Read the initial admin password (user 'admin') with:"
log_info "  kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log_info "Next step: run 'make gitops' to create the ArgoCD Application."
