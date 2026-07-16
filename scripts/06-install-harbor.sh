#!/usr/bin/env bash
# scripts/06-install-harbor.sh — install Harbor into the local KinD cluster as the
# stand-in for the "VKS-provided" Harbor. Two modes (see docs/decisions/kind-tls-fidelity.md):
#
#   secure   (default, HARBOR_INSECURE=0) — self-signed HTTPS on the LoadBalancer IP,
#            mimicking VCF/VKS 9.1's self-signed Harbor. The self-signed CA is trusted at
#            every consumer WITHOUT touching the (root-owned) system store — no sudo:
#              - jump box tools (crane/curl push) -> SSL_CERT_FILE bundle (lib/mirror.sh)
#              - each kind node containerd         -> here (certs.d/<ip>/ca.crt, ca = ...)
#              - in-cluster Kaniko build           -> make platform (harbor-ca ConfigMap)
#            The endpoint is the LB IP (routable from host AND in-cluster on the kind
#            network), so no /etc/hosts / CoreDNS DNS wiring is needed; the cert SAN is
#            that IP. Two-phase: install (TLS off) -> discover LB IP -> mint cert (SAN=IP)
#            -> upgrade to TLS with that cert.
#
#   insecure (HARBOR_INSECURE=1) — plain HTTP LoadBalancer at the LB IP, containerd
#            skip_verify. The original fast-iteration posture; kept + still tested.
#
# The discovered registry (LB IP) is published to .env.state so all downstream scripts
# (mirror-push, builder-image, Tekton) target it unchanged.
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
TLS_SECRET="${HARBOR_TLS_SECRET:-harbor-tls}"
CERT_DIR="${REPO_ROOT}/secrets/harbor-tls"

# Fixed chart-repo / release identifiers (overridable via env, slot-1 defaults).
CHART_REPO_NAME="${HARBOR_CHART_REPO_NAME:-goharbor}"
CHART_REPO_URL="${HARBOR_CHART_REPO_URL:-https://helm.goharbor.io}"
RELEASE="${HARBOR_RELEASE:-harbor}"
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
  log_info "Harbor mode: SECURE (self-signed HTTPS on the LoadBalancer IP) — mimics VCF/VKS self-signed Harbor"
fi

# --- 2. Helm repo (idempotent) -----------------------------------------------
log_info "adding/updating helm repo '$CHART_REPO_NAME' ($CHART_REPO_URL)"
run helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" --force-update
run helm repo update "$CHART_REPO_NAME"

# --- 3. Values -----------------------------------------------------------------
#
# PERSISTENCE IS LOAD-BEARING. It used to be `enabled: false`, which puts the registry's blob
# store on an **emptyDir** — so EVERY replacement of the registry pod DESTROYS THE ENTIRE MIRROR.
# That alone would be loud. What made it silent is the second half:
#
#   Harbor's registry caches blob DESCRIPTORS in Redis (cm/harbor-registry: `cache.layerinfo:
#   redis`, `redis.db: 2`) — and harbor-redis is a DIFFERENT pod that does NOT roll with the
#   registry. So after the wipe, the cache still answers `HEAD /v2/<repo>/blobs/<digest>` with
#   **200**. crane (spec-correctly) reads that as "the registry already holds this blob", SKIPS
#   THE UPLOAD, prints `existing blob:` and exits 0. `make mirror` reports 36/36 pushed. On disk
#   there were 153 manifest link files and **zero blobs**; a blob GET returned `200 OK` +
#   Content-Length + **zero bytes of body**. Only `make mirror-verify` (crane validate) saw it.
#
# This is very likely the true cause of what this repo has long recorded as "concurrent load
# corrupts Harbor's blob store": the failing run had NO concurrent load, and a wipe hits 36/36,
# whereas a write race would damage *some* images. "Recover with kind-down && e2e-kind" worked
# because it destroys Redis too — not because it avoids concurrency.
#
# A PVC (KinD's default `standard` StorageClass; `ci` and `gitea` already use it) makes the
# store outlive the pod, so the cache can no longer describe a store that isn't there.
umask 077
VALUES_FILE="$(mktemp -t harbor-values.XXXXXX.yaml)"
trap 'rm -f "$VALUES_FILE"' EXIT
esc_pw="${HARBOR_PW//\'/\'\'}"
harbor_render_values() {  # $1 = tls enabled (true|false), $2 = externalURL
  {
    printf 'expose:\n'
    printf '  type: loadBalancer\n'
    printf '  tls:\n'
    printf '    enabled: %s\n' "$1"
    if [ "$1" = "true" ]; then
      printf '    certSource: secret\n'
      printf '    secret:\n'
      printf '      secretName: %s\n' "$TLS_SECRET"
    fi
    printf 'persistence:\n'
    printf '  enabled: true\n'
    printf 'externalURL: %s\n' "$2"
    printf "harborAdminPassword: '%s'\n" "$esc_pw"
  } > "$VALUES_FILE"
}

# --- 4a. Phase 1 — ONLY on a first install ------------------------------------
#
# It used to run UNCONDITIONALLY, which meant every re-run against a warm cluster helm-upgraded
# a TLS-ENABLED Harbor back to `expose.tls.enabled: false` (a DOWNGRADE), rolling core/registry/
# jobservice — and then phase 2 rolled them AGAIN 3 seconds later. Two registry replacements per
# run, each of which (before the persistence fix above) wiped the mirror. `make e2e-kind` on a
# warm cluster therefore wiped Harbor and then mirrored into the void, deterministically.
#
# Phase 1 exists only to create the Service so cloud-provider-kind can assign the LB IP that
# becomes the cert's SAN. If the release is already there, the Service is too — skip straight to
# phase 2, which applies the FULL desired state.
if helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  log_info "Harbor release '$RELEASE' already exists — skipping the phase-1 install (it would DOWNGRADE TLS and roll the registry)"
else
  harbor_render_values false "$PROVISIONAL_URL"
  log_info "installing Harbor release '$RELEASE' (chart $CHART_VERSION) into namespace '$NS'"
  run helm upgrade --install "$RELEASE" "${CHART_REPO_NAME}/harbor" \
    --version "$CHART_VERSION" \
    --namespace "$NS" --create-namespace \
    --values "$VALUES_FILE"
fi

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

# --- 5. SECURE phase 2: mint the CA + leaf cert (SAN=LB IP), create the TLS secret, and
#        upgrade Harbor to serve HTTPS on the LB IP with that cert. -----------
# Phase 2 applies the FULL desired state from a rendered values file — NOT `--reuse-values`.
# `--reuse-values` inherits whatever the last release happened to carry, so the mode was
# STICKY: an insecure re-install of a previously-secure Harbor set externalURL=http:// while
# LEAVING TLS ON. Declaring the whole state makes the mode flip (make e2e-kind-both) honest,
# and it is idempotent: identical rendered values produce identical manifests, so helm does
# NOT roll the pods on a no-op re-run.
if [ "$HARBOR_INSECURE" != "1" ]; then
  log_info "minting self-signed CA + leaf cert (SAN=IP:${LB_IP}) -> ${CERT_DIR}"
  gen_selfsigned_ca_cert "$LB_IP" "$CERT_DIR" "vks-lab-harbor-ca"
  run kubectl -n "$NS" create secret tls "$TLS_SECRET" \
    --cert="${CERT_DIR}/tls.crt" --key="${CERT_DIR}/tls.key" \
    --dry-run=client -o yaml | run kubectl apply -f -
  log_info "upgrading Harbor to HTTPS (externalURL=https://${LB_IP}, cert secret=${TLS_SECRET})"
  harbor_render_values true "https://${LB_IP}"
else
  log_info "setting Harbor externalURL to http://${LB_IP}"
  harbor_render_values false "http://${LB_IP}"
fi
run helm upgrade --install "$RELEASE" "${CHART_REPO_NAME}/harbor" \
  --version "$CHART_VERSION" --namespace "$NS" --values "$VALUES_FILE"

# --- 5b. The registry's Redis descriptor cache must NEVER outlive its blob store -------------
#
# Belt-and-braces behind the PVC. A cache that describes blobs the store does not have turns the
# registry into a LIAR: HEAD 200 on a blob that isn't there => every pusher skips the upload and
# reports success (see the note at section 3). If the registry pod was replaced by the upgrade
# above, drop the cache so it re-stats from the real store.
#
# The DB index is READ FROM THE CLUSTER (cm/harbor-registry -> `redis: db:`), not guessed — the
# chart can move it, and a flush of the wrong DB would silently clear someone else's keys.
harbor_flush_registry_cache() {
  local db
  db="$(kubectl -n "$NS" get cm harbor-registry -o jsonpath='{.data.config\.yml}' 2>/dev/null \
        | awk '/^redis:/{r=1} r && /^[[:space:]]+db:/{print $2; exit}')"
  case "$db" in ''|*[!0-9]*) log_warn "cannot read the registry's redis DB index from cm/harbor-registry — skipping cache flush"; return 0 ;; esac
  local pod
  pod="$(kubectl -n "$NS" get pod -l component=redis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$pod" ] || { log_warn "no harbor redis pod found — skipping cache flush"; return 0; }
  log_info "flushing the registry's redis blob-descriptor cache (db ${db}) so it cannot describe blobs the store lacks"
  kubectl -n "$NS" exec "$pod" -- redis-cli -n "$db" FLUSHDB >/dev/null 2>&1 \
    || log_warn "redis FLUSHDB failed — if a push reports 'existing blob' for everything, this is why"
}
harbor_flush_registry_cache

# --- 6. Wire containerd on EVERY kind node for the LB IP (config_path=/etc/containerd/
#        certs.d, read per-pull, no restart needed). ---------------------------
if [ "$HARBOR_INSECURE" = "1" ]; then
  hosts_toml="$(printf '[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n  skip_verify = true\n' "$LB_IP")"
else
  # server=https://IP + explicit ca= (copying the CA into the node system store alone is
  # NOT reliable for containerd's registry client — a known kind gotcha).
  hosts_toml="$(printf 'server = "https://%s"\n\n[host."https://%s"]\n  capabilities = ["pull", "resolve"]\n  ca = "/etc/containerd/certs.d/%s/ca.crt"\n' "$LB_IP" "$LB_IP" "$LB_IP")"
fi
while IFS= read -r node; do
  [ -n "$node" ] || continue
  log_info "wiring containerd pull for ${LB_IP} on node '$node'"
  run docker exec "$node" mkdir -p "/etc/containerd/certs.d/${LB_IP}"
  printf '%s\n' "$hosts_toml" \
    | run docker exec -i "$node" sh -c "cat > /etc/containerd/certs.d/${LB_IP}/hosts.toml"
  if [ "$HARBOR_INSECURE" != "1" ]; then
    run docker cp "${CERT_DIR}/ca.crt" "${node}:/etc/containerd/certs.d/${LB_IP}/ca.crt"
  fi
done < <(kind get nodes --name "$CLUSTER_NAME")

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
  health_url="https://${LB_IP}/api/v2.0/health"; curl_ca=(--cacert "${CERT_DIR}/ca.crt")
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

# --- 8. Publish the discovered registry to downstream scripts (.env.state) -----
state_set HARBOR_URL "$LB_IP"
if [ "$HARBOR_INSECURE" = "1" ]; then
  state_set HARBOR_INSECURE 1
  state_set HARBOR_CA_FILE ""
  log_info "published HARBOR_URL=$LB_IP, HARBOR_INSECURE=1, HARBOR_CA_FILE='' to $(state_file)"
else
  state_set HARBOR_INSECURE 0
  state_set HARBOR_CA_FILE "${CERT_DIR}/ca.crt"
  log_info "published HARBOR_URL=$LB_IP, HARBOR_INSECURE=0, HARBOR_CA_FILE=${CERT_DIR}/ca.crt to $(state_file)"
fi

# --- 9. Summary --------------------------------------------------------------
log_info "Harbor installed: ${health_url%/api/*} (admin user: ${HARBOR_USERNAME:-admin})"
log_info "projects (${HARBOR_INFRA_PROJECT:-cicd}/${HARBOR_APP_PROJECT:-apps}) are created by the mirror-push step"
log_info "next step: make mirror  (or make mirror-push)"
