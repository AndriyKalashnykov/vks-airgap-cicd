#!/usr/bin/env bash
# scripts/06-install-harbor.sh — install Harbor into the local KinD cluster as the
# stand-in for the "VKS-provided" Harbor. Two modes (see docs/decisions/kind-tls-fidelity.md):
#
#   secure   (default, HARBOR_INSECURE=0) — self-signed HTTPS on 443 at the FQDN
#            HARBOR_TLS_HOST (harbor.vks.local), mimicking VCF/VKS 9.1's cert-manager
#            self-signed Harbor. The self-signed CA is trusted at every consumer:
#              - jump box system store (crane push)            -> trust_ca (make mirror/vks-login)
#              - each kind node containerd certs.d (image pull) -> here (ca = ...)
#              - in-cluster ConfigMap (Kaniko build)            -> make platform (harbor-ca)
#            Clients reach Harbor by the FQDN (cert SAN); the LB IP is only used for DNS
#            (host /etc/hosts + node /etc/hosts + CoreDNS), so the cert needs no IP SAN.
#
#   insecure (HARBOR_INSECURE=1) — plain HTTP LoadBalancer at the LB IP, containerd
#            skip_verify. The original fast-iteration posture; kept + still tested.
#
# The discovered registry (FQDN or LB IP) is published to .env.kind so all downstream
# scripts (mirror-push, builder-image, Tekton) target it unchanged.
#
# Idempotent: safe to re-run (helm upgrade --install; guarded docker exec; stable CA).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
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

# Mode: secure (default) unless HARBOR_INSECURE=1.
HARBOR_INSECURE="${HARBOR_INSECURE:-0}"
# Secure-mode endpoint FQDN (cert SAN) + the k8s TLS secret + local cert dir.
TLS_HOST="${HARBOR_TLS_HOST:-harbor.vks.local}"
TLS_SECRET="${HARBOR_TLS_SECRET:-harbor-tls}"
CERT_DIR="${REPO_ROOT}/secrets/harbor-tls"

# Fixed chart-repo / release identifiers (overridable via env, slot-1 defaults).
CHART_REPO_NAME="${HARBOR_CHART_REPO_NAME:-goharbor}"
CHART_REPO_URL="${HARBOR_CHART_REPO_URL:-https://helm.goharbor.io}"
RELEASE="${HARBOR_RELEASE:-harbor}"
# expose.loadBalancer.name (chart default "harbor") — the Service we poll for the LB IP.
HARBOR_SVC="${HARBOR_SVC:-harbor}"
PROVISIONAL_URL="${HARBOR_PROVISIONAL_EXTERNAL_URL:-http://harbor.local}"

export KUBECONFIG="$KUBECONFIG_PATH"

# --- 1. Preconditions --------------------------------------------------------
require_cmd helm
require_cmd kubectl
require_cmd docker
require_cmd curl
[ -n "$HARBOR_PW" ] || die "HARBOR_PASSWORD is empty — set it in .env (never committed) before installing Harbor"
if [ "$HARBOR_INSECURE" = "1" ]; then
  log_info "Harbor mode: INSECURE (plain HTTP LoadBalancer) — set HARBOR_INSECURE=0 for the lab-faithful TLS mode"
else
  require_cmd openssl
  log_info "Harbor mode: SECURE (self-signed HTTPS at https://${TLS_HOST}) — mimics VCF/VKS self-signed Harbor"
fi

# --- 2. Helm repo (idempotent) -----------------------------------------------
log_info "adding/updating helm repo '$CHART_REPO_NAME' ($CHART_REPO_URL)"
run helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" --force-update
run helm repo update "$CHART_REPO_NAME"

# --- 2b. SECURE: mint the self-signed CA + leaf cert, create the Harbor TLS secret
if [ "$HARBOR_INSECURE" != "1" ]; then
  log_info "minting self-signed CA + leaf cert for ${TLS_HOST} -> ${CERT_DIR}"
  gen_selfsigned_ca_cert "$TLS_HOST" "$CERT_DIR" "vks-lab-harbor-ca"
  run kubectl create namespace "$NS" --dry-run=client -o yaml | run kubectl apply -f -
  # TLS secret consumed by the chart (expose.tls.certSource=secret). Recreate idempotently.
  run kubectl -n "$NS" create secret tls "$TLS_SECRET" \
    --cert="${CERT_DIR}/tls.crt" --key="${CERT_DIR}/tls.key" \
    --dry-run=client -o yaml | run kubectl apply -f -
fi

# --- 3. Values file (umask 077; admin password ONLY here, never on argv) ------
umask 077
VALUES_FILE="$(mktemp -t harbor-values.XXXXXX.yaml)"
trap 'rm -f "$VALUES_FILE"' EXIT
esc_pw="${HARBOR_PW//\'/\'\'}"
{
  printf 'expose:\n'
  printf '  type: loadBalancer\n'
  if [ "$HARBOR_INSECURE" = "1" ]; then
    printf '  tls:\n'
    printf '    enabled: false\n'
    printf 'externalURL: %s\n' "$PROVISIONAL_URL"
  else
    printf '  tls:\n'
    printf '    enabled: true\n'
    printf '    certSource: secret\n'
    printf '    secret:\n'
    printf '      secretName: %s\n' "$TLS_SECRET"
    printf 'externalURL: https://%s\n' "$TLS_HOST"
  fi
  printf 'persistence:\n'
  printf '  enabled: false\n'
  printf "harborAdminPassword: '%s'\n" "$esc_pw"
} > "$VALUES_FILE"

# --- 4a. Install/upgrade -----------------------------------------------------
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

# --- 5. Wire containerd on EVERY kind node (config_path=/etc/containerd/certs.d,
#        read per-pull, no restart needed).
if [ "$HARBOR_INSECURE" = "1" ]; then
  REG_KEY="$LB_IP"
  hosts_toml="$(printf '[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n  skip_verify = true\n' "$LB_IP")"
else
  REG_KEY="$TLS_HOST"
  # server=https://FQDN + explicit ca= (copying the CA into the node system store alone is
  # not reliable for containerd's registry client — a known kind gotcha).
  hosts_toml="$(printf 'server = "https://%s"\n\n[host."https://%s"]\n  capabilities = ["pull", "resolve"]\n  ca = "/etc/containerd/certs.d/%s/ca.crt"\n' "$TLS_HOST" "$TLS_HOST" "$TLS_HOST")"
fi
while IFS= read -r node; do
  [ -n "$node" ] || continue
  log_info "wiring containerd pull for ${REG_KEY} on node '$node'"
  run docker exec "$node" mkdir -p "/etc/containerd/certs.d/${REG_KEY}"
  printf '%s\n' "$hosts_toml" \
    | run docker exec -i "$node" sh -c "cat > /etc/containerd/certs.d/${REG_KEY}/hosts.toml"
  if [ "$HARBOR_INSECURE" != "1" ]; then
    # node trusts the CA; node resolves the FQDN -> LB IP via /etc/hosts
    run docker cp "${CERT_DIR}/ca.crt" "${node}:/etc/containerd/certs.d/${TLS_HOST}/ca.crt"
    run docker exec "$node" sh -c "sed -i '/[[:space:]]${TLS_HOST}\$/d' /etc/hosts; echo '${LB_IP} ${TLS_HOST}' >> /etc/hosts"
  fi
done < <(kind get nodes --name "$CLUSTER_NAME")

# --- 5b. SECURE: in-cluster DNS (CoreDNS) + jump-box /etc/hosts + host CA trust
if [ "$HARBOR_INSECURE" != "1" ]; then
  log_info "patching CoreDNS to resolve ${TLS_HOST} -> ${LB_IP} (so in-cluster pods reach Harbor by FQDN)"
  # Add a hosts{} block to the Corefile via kubectl patch of the coredns ConfigMap, then
  # restart CoreDNS. Idempotent: strip any prior vks-hosts block first.
  cm="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
  cm_clean="$(printf '%s' "$cm" | sed '/# vks-hosts BEGIN/,/# vks-hosts END/d')"
  hosts_block="$(printf '    hosts {  # vks-hosts BEGIN\n        %s %s\n        fallthrough\n    }  # vks-hosts END' "$LB_IP" "$TLS_HOST")"
  # insert the hosts block just after the opening ".:53 {" line
  new_cf="$(printf '%s' "$cm_clean" | awk -v blk="$hosts_block" 'NR==1{print; print blk; next} {print}')"
  run kubectl -n kube-system create configmap coredns --from-literal=Corefile="$new_cf" \
    --dry-run=client -o yaml | run kubectl apply -f -
  run kubectl -n kube-system rollout restart deploy/coredns
  run kubectl -n kube-system rollout status deploy/coredns --timeout="${READY_TIMEOUT}s"

  log_info "mapping ${TLS_HOST} -> ${LB_IP} in the jump box /etc/hosts (for crane push over HTTPS)"
  add_host_entry "$LB_IP" "$TLS_HOST"

  log_info "trusting the Harbor CA in the jump box system store"
  trust_ca "${CERT_DIR}/ca.crt" "vks-lab-harbor-ca"
fi

# --- 6. Correct externalURL (insecure only — secure set https://FQDN at install) --
if [ "$HARBOR_INSECURE" = "1" ]; then
  log_info "setting Harbor externalURL to http://${LB_IP}"
  run helm upgrade --install "$RELEASE" "${CHART_REPO_NAME}/harbor" \
    --version "$CHART_VERSION" --namespace "$NS" --reuse-values \
    --set "externalURL=http://${LB_IP}"
fi

# --- 7a. Readiness: Harbor deployments Available -----------------------------
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

# --- 7b. LB-routability poll (assigned IP != routable through envoy immediately) --
if [ "$HARBOR_INSECURE" = "1" ]; then
  health_url="http://${LB_IP}/api/v2.0/health"; curl_ca=()
else
  health_url="https://${TLS_HOST}/api/v2.0/health"; curl_ca=(--cacert "${CERT_DIR}/ca.crt")
fi
log_info "waiting for Harbor to be routable at $health_url (timeout ${READY_TIMEOUT}s, poll ${POLL_INTERVAL}s)"
deadline=$(( SECONDS + READY_TIMEOUT ))
until curl -fsS "${curl_ca[@]}" --max-time "$CURL_MAX_TIME" "$health_url" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    log_error "Harbor did not become routable at $health_url within ${READY_TIMEOUT}s; current state:"
    kubectl -n "$NS" get svc,pods >&2 || true
    die "Harbor LoadBalancer IP assigned but not routable"
  fi
  log_info "Harbor not routable yet — retrying in ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
log_info "Harbor is routable at $health_url"

# --- 8. Publish the discovered registry to downstream scripts (.env.kind) -----
if [ "$HARBOR_INSECURE" = "1" ]; then
  set_env_var HARBOR_URL "$LB_IP"
  set_env_var HARBOR_INSECURE 1
  set_env_var HARBOR_CA_FILE ""
  log_info "published HARBOR_URL=$LB_IP, HARBOR_INSECURE=1, HARBOR_CA_FILE='' to ${REPO_ROOT}/.env.kind"
else
  set_env_var HARBOR_URL "$TLS_HOST"
  set_env_var HARBOR_INSECURE 0
  set_env_var HARBOR_CA_FILE "${CERT_DIR}/ca.crt"
  log_info "published HARBOR_URL=$TLS_HOST, HARBOR_INSECURE=0, HARBOR_CA_FILE=${CERT_DIR}/ca.crt to ${REPO_ROOT}/.env.kind"
fi

# --- 9. Summary --------------------------------------------------------------
log_info "Harbor installed: ${health_url%/api/*} (admin user: ${HARBOR_USERNAME:-admin})"
log_info "projects (${HARBOR_INFRA_PROJECT:-cicd}/${HARBOR_APP_PROJECT:-apps}) are created by the mirror-push step"
log_info "next step: make mirror  (or make mirror-push)"
