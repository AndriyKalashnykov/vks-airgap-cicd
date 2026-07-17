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
# Mode: secure (default) = upstream self-signed TLS on 443 (mimics VCF/VKS); insecure
# (ARGOCD_INSECURE=1) = server.insecure plain HTTP. Exposed via its OWN LoadBalancer in both.
ARGOCD_INSECURE="${ARGOCD_INSECURE:-0}"
ARGOCD_SVC="${ARGOCD_SVC:-argocd-server}"

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

# 1. Namespace (idempotent), through the one chokepoint rather than a hand-rolled copy of its
#    create line. This script is KinD-ONLY (Makefile: "Install ArgoCD into KinD"; it is not in
#    install-all, and on a real lab ArgoCD is a Supervisor Service we discover, never install) — so
#    routing it fixes no lab hazard and no claim is made that it does. It is here because a second
#    copy of `kubectl create namespace | kubectl apply` is how the chokepoint erodes: the next person
#    to need a namespace copies the nearest example, and the nearest example should be the right one.
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
#    Deliberately NO PSA level. `PSA_LEVEL_ARGOCD` does not exist — inventing it here would have
#    given it exactly one occurrence repo-wide (its own use site), always empty, silently meaning
#    "no label" while LOOKING like a configured knob, and check-env-coverage would not have caught
#    it (PSA_LEVEL_* is wildcard-exempt). Passing no level is the same behaviour, honestly.
#    It is correct here for the reason above: KinD-only, and upstream's ArgoCD manifest is not ours
#    to make restricted-clean. On a real lab ArgoCD is a Supervisor Service we never install.
log_info "ensuring namespace ${ARGOCD_NAMESPACE}"
ensure_namespace "$ARGOCD_NAMESPACE"

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

# 4. Exposure + TLS mode. Mimic VCF/VKS 9.1: expose argocd-server as its OWN LoadBalancer
# (the KinD analog of the Supervisor L4 LB), reached BY IP — NOT behind the *.vks.local
# ingress (VKS does not front ArgoCD there). Mode:
#   secure   (default)          — leave upstream self-signed TLS on 443 (what real VKS serves).
#   insecure (ARGOCD_INSECURE=1) — patch server.insecure so the UI/API is plain HTTP.
if [ "$ARGOCD_INSECURE" = "1" ]; then
  log_info "ArgoCD mode: INSECURE (server.insecure, plain HTTP) — set ARGOCD_INSECURE=0 for lab-faithful TLS"
  run kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
    --type merge -p '{"data":{"server.insecure":"true"}}'
  run kubectl -n "$ARGOCD_NAMESPACE" rollout restart deploy/argocd-server
  wait_ready deploy/argocd-server
else
  log_info "ArgoCD mode: SECURE (upstream self-signed TLS on 443) — mimics VCF/VKS self-signed ArgoCD"
fi

# Expose argocd-server as a LoadBalancer (both modes) and discover its IP (cloud-provider-kind).
run kubectl -n "$ARGOCD_NAMESPACE" patch svc "$ARGOCD_SVC" -p '{"spec":{"type":"LoadBalancer"}}'
log_info "waiting for ${ARGOCD_SVC} LoadBalancer IP (timeout ${READY_TIMEOUT_SECONDS}s, poll ${POLL_INTERVAL_SECONDS}s)"
ARGOCD_LB_IP=""; deadline=$(( SECONDS + READY_TIMEOUT_SECONDS ))
while :; do
  ARGOCD_LB_IP="$(kubectl -n "$ARGOCD_NAMESPACE" get svc "$ARGOCD_SVC" \
                    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$ARGOCD_LB_IP" ] && break
  [ "$SECONDS" -ge "$deadline" ] && { kubectl -n "$ARGOCD_NAMESPACE" get svc "$ARGOCD_SVC" >&2 || true; die "argocd-server LoadBalancer did not get an IP (is cloud-provider-kind running?)"; }
  sleep "$POLL_INTERVAL_SECONDS"
done
log_info "argocd-server LoadBalancer IP: $ARGOCD_LB_IP  ($([ "$ARGOCD_INSECURE" = "1" ] && echo "http://${ARGOCD_LB_IP}" || echo "https://${ARGOCD_LB_IP} (self-signed; --insecure)"))"
# Publish to .env.kind (KinD-only; in a real lab ArgoCD is lab-provided and this script never runs).
state_set ARGOCD_LB_IP "$ARGOCD_LB_IP"
state_set ARGOCD_INSECURE "$ARGOCD_INSECURE"
# 5. Optional: set a deterministic 'admin' password from .env (KinD convenience so the
# UI login is known + stable, like Gitea/Harbor). Skipped when ARGOCD_ADMIN_PASSWORD is
# blank — the case on real VKS, where ArgoCD is lab-provided. The bcrypt hash is generated
# by the argocd binary INSIDE the server pod, fed the plaintext on STDIN (never on argv,
# per the secrets rule); the resulting one-way hash is then safe to patch into the secret.
if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
  log_info "setting ArgoCD 'admin' password from ARGOCD_ADMIN_PASSWORD (.env)"
  # The single-quoted grep pattern's '$' are literal bcrypt-hash anchors, not shell
  # expansions — single quotes are correct here.
  # shellcheck disable=SC2016
  # `|| true`: standalone `set -e` assignment — `head -1` closing the pipe SIGPIPEs the upstream
  # `grep` (exit 141) under pipefail, which would abort the script HERE even on a successfully
  # extracted hash, skipping the `[ -n "$bhash" ]` guard. The captured hash is already correct.
  bhash="$(kubectl -n "$ARGOCD_NAMESPACE" exec -i deploy/argocd-server -- \
             argocd account bcrypt <<<"$ARGOCD_ADMIN_PASSWORD" 2>/dev/null \
           | grep -oE '\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}' | head -1 || true)"
  [ -n "$bhash" ] || die "failed to generate the bcrypt hash for ARGOCD_ADMIN_PASSWORD"
  # ${bhash} is expanded ONCE here; run() uses "$@" (no eval), so the '$' chars in the
  # hash are literal to kubectl — not re-expanded as shell positionals.
  run kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret --type merge \
    -p "{\"stringData\":{\"admin.password\":\"${bhash}\",\"admin.passwordMtime\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  # Drop the generated secret so `make argocd-password` unambiguously returns OUR value.
  run kubectl -n "$ARGOCD_NAMESPACE" delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null 2>&1 || true
fi

# 6. Summary. The admin password is revealed by `make argocd-password` (it self-resolves
# the kubeconfig and picks the source: the .env value if set, else the generated secret)
# — never printed or placed on argv here.
log_info "ArgoCD ${ARGOCD_VERSION} installed in namespace ${ARGOCD_NAMESPACE}."
if [ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]; then
  log_info "admin password set from .env (user 'admin'); reveal it with: make argocd-password"
else
  log_info "admin password is auto-generated (user 'admin'); reveal it with: make argocd-password"
fi
log_info "Next step: run 'make gitops' to create the ArgoCD Application."
