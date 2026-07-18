#!/usr/bin/env bash
# 45-install-traefik.sh — install ONE Traefik ingress controller (a single
# LoadBalancer) that fronts the browser UIs at *.vks.local, so operators reach
# Gitea / ArgoCD / the app by hostname instead of `kubectl port-forward`.
#
# Scope (decided with the owner): UIs only. Harbor keeps its OWN direct
# LoadBalancer — its LB IP is load-bearing for the containerd insecure-registry
# pull path (see 06-install-harbor.sh), so it is NOT routed through Traefik.
#
# Air-gap honest: hostnames resolve via /etc/hosts on the jump box/clients ->
# Traefik's single LB IP. No internet DNS, no sslip.io. The Traefik image is
# pulled from Harbor (mirrored), like every other workload. Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
require_cmd envsubst "install gettext (provides envsubst)"
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example; produced by make vks-login or make kind-up)}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
: "${TRAEFIK_NAMESPACE:?}"
: "${GITEA_NAMESPACE:?}"; : "${GITEA_HOST:?}"
# B33a: no ARGOCD_NAMESPACE guard here. Nothing in this script uses it — the ArgoCD namespace
# creation it once guarded was removed as VESTIGIAL (see the comment further down), and the guard
# outlived it. It was also vacuous: lib/os.sh's load_env unconditionally exports
# ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}", so the `:?` could never have fired.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
: "${TEKTON_NAMESPACE:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

K8S_DIR="${REPO_ROOT}/k8s/traefik"

# envsubst allowlists — single-quoted so envsubst gets the literal ${VAR} NAMES
# (only these are substituted; anything else, e.g. a shell $ in a manifest, is
# left untouched).
# shellcheck disable=SC2016
CTRL_ALLOWLIST='${HARBOR_URL} ${HARBOR_INFRA_PROJECT} ${TRAEFIK_NAMESPACE}'
# shellcheck disable=SC2016
ING_ALLOWLIST='${GITEA_NAMESPACE} ${GITEA_HOST} ${TEKTON_NAMESPACE} ${TEKTON_DASHBOARD_HOST}'
# shellcheck disable=SC2016
APP_ING_ALLOWLIST='${APP_NAME} ${APP_NAMESPACE} ${APP_HOST}'

# --- 1. Install the controller (namespace, RBAC, IngressClass, Deployment, LB) ---
log_info "installing Traefik controller into namespace '${TRAEFIK_NAMESPACE}'"

# The namespace, WITH its labels, BEFORE the manifest that carries traefik's pods — controller.yaml
# no longer declares it. `restricted` is the level its own securityContext already satisfies
# (controller.yaml: runAsNonRoot, runAsUser 65532, seccompProfile RuntimeDefault, caps drop ALL,
# read-only rootfs, and it binds :8000 rather than :80 so it needs no NET_BIND_SERVICE). That is
# REASONING, not measurement — the NS_SPEC row added to 49-psa-check.sh is what measures it, via a
# server-side dry-run, on every `make psa-check`.
#
# NOT PSA_LEVEL_INGRESS: that var's `baseline` exists for the ISTIO gwapi namespace, whose
# auto-provisioned proxy sets no seccompProfile. Reusing it here would silently loosen traefik to
# baseline for a reason that has nothing to do with traefik.
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
ensure_namespace "$TRAEFIK_NAMESPACE" "${PSA_LEVEL_TRAEFIK:-restricted}"

# shellcheck disable=SC2016
envsubst "$CTRL_ALLOWLIST" < "${K8S_DIR}/controller.yaml" | run kubectl apply -f -

log_info "waiting for Traefik to become ready (timeout ${READY_TIMEOUT_SECONDS}s)"
run kubectl -n "$TRAEFIK_NAMESPACE" rollout status deploy/traefik \
  --timeout="${READY_TIMEOUT_SECONDS}s"

# --- 2. Ingress objects live in each backend's namespace; ensure they exist ---
# The app namespace is created by ArgoCD with CreateNamespace, but the app Ingress may be applied
# before the first sync, so pre-create it (ArgoCD adopts an existing namespace).
#
# NOT $ARGOCD_NAMESPACE. That was VESTIGIAL: nothing here routes ArgoCD — `ingress.yaml` exposes
# only gitea + the Tekton dashboard, and ArgoCD keeps its OWN LoadBalancer (see CLAUDE.md). So the
# creation bought nothing and cost three things: on a REAL lab this script runs against the GUEST
# kubeconfig, and ArgoCD is a Supervisor Service — so it conjured a phantom empty `argocd` namespace
# on the wrong cluster; in Scenario 2 that is a namespace the tenant does not own; and `create` is a
# wider RBAC verb than the `patch` this flow otherwise needs.
#
# Through ensure_namespace, not a hand-rolled copy of its create line: this is the ONLY place a
# namespace we own gets its PSA level and its istio-injection=disabled label, and the bare create
# here gave neither. Idempotent and conflict-free — the levels are byte-identical to the ones
# 70-configure-argocd.sh:362 and lib/istio.sh:278,284 use for the same namespaces, and
# `kubectl label --overwrite` does not care who ran first. ArgoCD adopts an existing namespace by
# design, so pre-creating it does not disturb CreateNamespace=true.
for ns in "$GITEA_NAMESPACE" $(app_names | tr '\n' ' '); do
  if [ "$ns" = "$GITEA_NAMESPACE" ]; then
    ensure_namespace "$ns" "${PSA_LEVEL_GITEA:-restricted}"
  else
    ensure_namespace "$ns" "${PSA_LEVEL_APP:-restricted}"
  fi
done

log_info "applying Ingress objects for the shared UIs (gitea/tekton -> *.vks.local)"
# shellcheck disable=SC2016
envsubst "$ING_ALLOWLIST" < "${K8S_DIR}/ingress.yaml" | run kubectl apply -f -

# ONE Ingress per app, from the registry — adding an app routes it with no YAML edit.
# shellcheck disable=SC2329  # invoked indirectly (for_each_app / wait_for)
_traefik_apply_app_ingress() {
  log_info "applying Ingress for app '${APP_NAME}' (${APP_HOST} -> ${APP_NAME}.${APP_NAMESPACE})"
  envsubst "$APP_ING_ALLOWLIST" < "${K8S_DIR}/ingress-app.yaml" | run kubectl apply -f -
}
for_each_app _traefik_apply_app_ingress

# --- 3. Discover the Traefik LoadBalancer IP -----------------------------------
log_info "waiting for Traefik LoadBalancer IP (timeout ${READY_TIMEOUT_SECONDS}s, poll ${POLL_INTERVAL_SECONDS}s)"
LB_IP=""
elapsed=0
while :; do
  LB_IP="$(kubectl -n "$TRAEFIK_NAMESPACE" get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$LB_IP" ] && break
  elapsed=$(( elapsed + POLL_INTERVAL_SECONDS ))
  [ "$elapsed" -ge "$READY_TIMEOUT_SECONDS" ] && die "Traefik LoadBalancer IP not assigned within ${READY_TIMEOUT_SECONDS}s"
  log_info "LB IP not assigned yet — retrying in ${POLL_INTERVAL_SECONDS}s"
  sleep "$POLL_INTERVAL_SECONDS"
done
log_info "Traefik LoadBalancer IP: ${LB_IP}"

# --- 4. Publish the IP + emit the /etc/hosts guidance --------------------------
state_set INGRESS_LB_IP "$LB_IP"
log_info "published INGRESS_LB_IP=${LB_IP} to $(state_file)"

log_info "Traefik installed. Add ONE line to /etc/hosts on the jump box / your client:"
log_info ""
log_info "    ${LB_IP}  ${GITEA_HOST} ${TEKTON_DASHBOARD_HOST} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
log_info ""
log_info "then browse: http://${GITEA_HOST}  http://${TEKTON_DASHBOARD_HOST}  $(app_names | while read -r a; do if [ -n "$a" ]; then printf 'http://%s  ' "$(app_host "$a")"; fi; done)"
log_info "(ArgoCD is on its own LoadBalancer IP, not the ingress — see 'make creds')"
log_info "(no more 'kubectl port-forward' for the UIs; Harbor keeps its own LB IP)"
