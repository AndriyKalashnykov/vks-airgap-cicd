#!/usr/bin/env bash
# scripts/06-install-harbor.sh — install Harbor into the local KinD cluster as
# the stand-in for the "VKS-provided" Harbor.
#
# Harbor is exposed as a LoadBalancer over PLAIN HTTP (cloud-provider-kind, started
# by scripts/05-kind-up.sh, assigns an external IP on the `kind` docker network).
# We then wire every kind node's containerd to pull from that LB IP INSECURELY, so
# the SAME image ref (the LB IP, HTTP:80) works identically from:
#   - the host        (skopeo push)
#   - in-cluster pods (Kaniko push)
#   - containerd      (image pull)
#
# The discovered registry (LB IP) is published to .env.kind via set_env_var so all
# downstream scripts (mirror-push, builder-image, Tekton) target it unchanged.
#
# Idempotent: safe to re-run (helm upgrade --install; guarded docker exec).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# --- Tunables (read from .env* after load_env; never hardcode) ---------------
NS="${HARBOR_NAMESPACE:?HARBOR_NAMESPACE must be set in .env.example}"
CHART_VERSION="${HARBOR_CHART_VERSION:?HARBOR_CHART_VERSION must be set in .env.example}"
CLUSTER_NAME="${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME must be set in .env.example}"
KUBECONFIG_PATH="${KUBECONFIG:?KUBECONFIG must be set in .env.example}"
READY_TIMEOUT="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL_SECONDS:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME_SECONDS:-10}"
HARBOR_PW="${HARBOR_PASSWORD:-}"

# Fixed chart-repo / release identifiers (overridable via env, slot-1 defaults).
CHART_REPO_NAME="${HARBOR_CHART_REPO_NAME:-goharbor}"
CHART_REPO_URL="${HARBOR_CHART_REPO_URL:-https://helm.goharbor.io}"
RELEASE="${HARBOR_RELEASE:-harbor}"
# expose.loadBalancer.name (chart default "harbor") — the Service we poll for the LB IP.
HARBOR_SVC="${HARBOR_SVC:-harbor}"
# Provisional externalURL used at first install; corrected once the LB IP is known.
PROVISIONAL_URL="${HARBOR_PROVISIONAL_EXTERNAL_URL:-http://harbor.local}"

export KUBECONFIG="$KUBECONFIG_PATH"

# --- 1. Preconditions --------------------------------------------------------
require_cmd helm
require_cmd kubectl
require_cmd docker
require_cmd curl
[ -n "$HARBOR_PW" ] || die "HARBOR_PASSWORD is empty — set it in .env (never committed) before installing Harbor"

# --- 2. Helm repo (idempotent) -----------------------------------------------
log_info "adding/updating helm repo '$CHART_REPO_NAME' ($CHART_REPO_URL)"
run helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" --force-update
run helm repo update "$CHART_REPO_NAME"

# --- 3. Values file (umask 077; admin password ONLY here, never on argv) ------
umask 077
VALUES_FILE="$(mktemp -t harbor-values.XXXXXX.yaml)"
trap 'rm -f "$VALUES_FILE"' EXIT
# YAML single-quoted scalar: escape embedded single quotes by doubling them so an
# arbitrary password survives verbatim (double quotes / backslashes are literal here).
esc_pw="${HARBOR_PW//\'/\'\'}"
{
  printf 'expose:\n'
  printf '  type: loadBalancer\n'
  printf '  tls:\n'
  printf '    enabled: false\n'
  printf 'persistence:\n'
  printf '  enabled: false\n'
  printf 'externalURL: %s\n' "$PROVISIONAL_URL"
  printf "harborAdminPassword: '%s'\n" "$esc_pw"
} > "$VALUES_FILE"

# --- 4a. Install/upgrade (provisional externalURL — corrected in step 6) ------
log_info "installing Harbor release '$RELEASE' (chart $CHART_VERSION) into namespace '$NS'"
run helm upgrade --install "$RELEASE" "${CHART_REPO_NAME}/harbor" \
  --version "$CHART_VERSION" \
  --namespace "$NS" --create-namespace \
  --values "$VALUES_FILE"

# --- 4b. Poll for the LoadBalancer IP (assigned by cloud-provider-kind) --------
log_info "waiting for LoadBalancer IP on svc '$HARBOR_SVC' (timeout ${READY_TIMEOUT}s, poll ${POLL_INTERVAL}s)"
LB_IP=""
deadline=$(( SECONDS + READY_TIMEOUT ))
while :; do
  LB_IP="$(kubectl -n "$NS" get svc "$HARBOR_SVC" \
             -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$LB_IP" ] && break
  if [ "$SECONDS" -ge "$deadline" ]; then
    log_error "no LoadBalancer IP assigned within ${READY_TIMEOUT}s; current state:"
    kubectl -n "$NS" get svc,pods >&2 || true
    die "Harbor LoadBalancer did not get an external IP (is cloud-provider-kind running?)"
  fi
  log_info "LB IP not assigned yet — retrying in ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
log_info "Harbor LoadBalancer IP: $LB_IP"

# --- 5. Wire containerd insecure pull on EVERY kind node for the LB IP --------
# config_path=/etc/containerd/certs.d is enabled in the cluster and read PER-PULL,
# so no containerd restart is needed. hosts.toml points containerd at HTTP + skip TLS.
hosts_toml="$(printf '[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n  skip_verify = true\n' "$LB_IP")"
while IFS= read -r node; do
  [ -n "$node" ] || continue
  log_info "wiring containerd insecure pull for $LB_IP on node '$node'"
  run docker exec "$node" mkdir -p "/etc/containerd/certs.d/${LB_IP}"
  printf '%s\n' "$hosts_toml" \
    | run docker exec -i "$node" \
        sh -c "cat > /etc/containerd/certs.d/${LB_IP}/hosts.toml"
done < <(kind get nodes --name "$CLUSTER_NAME")

# --- 6. Correct externalURL to the real LB IP (token service needs it right) --
# --reuse-values keeps the admin password (never re-sent on argv); only the
# non-secret externalURL is overridden here.
log_info "setting Harbor externalURL to http://${LB_IP}"
run helm upgrade --install "$RELEASE" "${CHART_REPO_NAME}/harbor" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --reuse-values \
  --set "externalURL=http://${LB_IP}"

# --- 7a. Readiness: Harbor deployments Available (bounded poll loop) -----------
log_info "waiting for Harbor deployments to become Available (timeout ${READY_TIMEOUT}s, poll ${POLL_INTERVAL}s)"
deadline=$(( SECONDS + READY_TIMEOUT ))
until kubectl -n "$NS" wait --for=condition=Available deploy --all \
        --timeout="${POLL_INTERVAL}s" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    log_error "Harbor deployments did not become Available within ${READY_TIMEOUT}s; current state:"
    kubectl -n "$NS" get deploy,pods >&2 || true
    die "Harbor failed readiness"
  fi
  log_info "Harbor deployments not Available yet — retrying in ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
log_info "all Harbor deployments Available"

# --- 7b. LB-routability poll (assigned IP != routable through envoy sidecar) ---
# cloud-provider-kind wires the data path a few seconds AFTER the IP is assigned;
# poll the real HTTP health endpoint until it actually answers.
health_url="http://${LB_IP}/api/v2.0/health"
log_info "waiting for Harbor to be routable at $health_url (timeout ${READY_TIMEOUT}s, poll ${POLL_INTERVAL}s)"
deadline=$(( SECONDS + READY_TIMEOUT ))
until curl -fsS --max-time "$CURL_MAX_TIME" "$health_url" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    log_error "Harbor did not become routable at $health_url within ${READY_TIMEOUT}s; current state:"
    kubectl -n "$NS" get svc,pods >&2 || true
    die "Harbor LoadBalancer IP assigned but not routable"
  fi
  log_info "Harbor not routable yet — retrying in ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
log_info "Harbor is routable at http://${LB_IP}"

# --- 8. Publish the discovered registry to downstream scripts (.env.kind) -----
# HTTP:80, no port suffix; plain HTTP so no CA file. These override .env for the
# rest of the toolchain (skopeo/kaniko/Tekton all consume HARBOR_URL).
set_env_var HARBOR_URL "$LB_IP"
set_env_var HARBOR_INSECURE 1
set_env_var HARBOR_CA_FILE ""
log_info "published HARBOR_URL=$LB_IP, HARBOR_INSECURE=1, HARBOR_CA_FILE='' to ${REPO_ROOT}/.env.kind"

# --- 9. Summary --------------------------------------------------------------
log_info "Harbor installed: http://${LB_IP} (admin user: ${HARBOR_USERNAME:-admin})"
log_info "projects (${HARBOR_INFRA_PROJECT:-cicd}/${HARBOR_APP_PROJECT:-apps}) are created by the mirror-push step"
log_info "next step: make mirror  (or make mirror-push)"
