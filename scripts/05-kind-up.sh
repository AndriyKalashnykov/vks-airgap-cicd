#!/usr/bin/env bash
# scripts/05-kind-up.sh — bring up a local KinD cluster with a working
# LoadBalancer (via cloud-provider-kind), so an in-cluster Harbor is reachable
# by the SAME IP from host, pods, and containerd. This simulates the
# "VKS-provided" Harbor + ArgoCD locally for `make e2e-kind`.
#
# It publishes the discovered kubeconfig + context to a gitignored .env.state
# overlay (via state_set) so `make vks-login` and every downstream script
# target the kind cluster unchanged.
#
# Idempotent: safe to re-run. Teardown is scripts/kind-down.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# --- Tunables (read from .env* after load_env; never hardcode) ---------------
CLUSTER_NAME="${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME must be set in .env.example}"
NODE_IMAGE="${KIND_NODE_IMAGE:-}"
CPK_VERSION="${CLOUD_PROVIDER_KIND_VERSION:?CLOUD_PROVIDER_KIND_VERSION must be set in .env.example}"
# The KinD flow writes its OWN kubeconfig, at its OWN path — NEVER to whatever $KUBECONFIG points at.
#
# It used to do `KUBECONFIG_PATH="${KUBECONFIG:?}"` and then `kind get kubeconfig > "$KUBECONFIG_PATH"`,
# i.e. it wrote to a CALLER-CONTROLLED path. Anyone who set KUBECONFIG in .env (which .env.example
# invites) already had that file truncated; the uncommented .env.example pin was only an ACCIDENTAL
# SHIELD redirecting it to ./secrets/vks.kubeconfig. Once load_env began honouring the caller's
# KUBECONFIG (so a two-cluster test could be driven at all), the shield came off — a developer with an
# ordinary `export KUBECONFIG=~/.kube/config` would have had it OVERWRITTEN, and then DELETED by
# `make kind-down`, which removes the kubeconfig this flow recorded.
#
# A flow writes only what it owns, and destroys only what it created.
# Not an env var: this path is OWNED by the KinD flow, not an operator knob. (Making it settable
# would just re-open the hole from the other side.)
KUBECONFIG_PATH="${REPO_ROOT}/secrets/kind.kubeconfig"
READY_TIMEOUT="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL_SECONDS:-5}"
KIND_CONFIG="${REPO_ROOT}/kind/kind-config.yaml"
CPK_CONTAINER="cloud-provider-kind"
CPK_IMAGE="registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CPK_VERSION}"

require_cmd kind
require_cmd docker
require_cmd kubectl

[ -f "$KIND_CONFIG" ] || die "kind config not found at $KIND_CONFIG"

# --- 1. Create the cluster (idempotent + health-checked) ---------------------
# A cluster with this name may be listed yet BROKEN — an interrupted `kind create`
# (Ctrl+C mid-create) leaves a partial cluster that `kind get clusters` still lists.
# A name-only guard would then skip create and proceed on a dead cluster. So when the
# name exists, health-check the control-plane and only skip create if a node is
# actually Ready; otherwise delete + recreate.
need_create=1
if kind get clusters 2>/dev/null | grep -qxF "$CLUSTER_NAME"; then
  kc="$(mktemp)"
  # Capture the node list first, THEN grep the variable: piping `kubectl … | grep -q` directly
  # lets `grep -q` close the pipe on its first match, SIGPIPE-killing `kubectl` (exit 141), which
  # under `set -o pipefail` reads as "not Ready" → we would DELETE a HEALTHY cluster. `grep` on a
  # small captured string never SIGPIPEs its source.
  nodes=""
  if kind get kubeconfig --name "$CLUSTER_NAME" >"$kc" 2>/dev/null; then
    nodes="$(kubectl --kubeconfig "$kc" get nodes 2>/dev/null || true)"
  fi
  if [ -n "$nodes" ] && printf '%s\n' "$nodes" | grep -q ' Ready'; then
    log_info "kind cluster '$CLUSTER_NAME' already exists and is healthy — skipping create"
    need_create=0
  else
    log_warn "kind cluster '$CLUSTER_NAME' exists but is NOT healthy (partial/interrupted create?) — deleting + recreating"
    run kind delete cluster --name "$CLUSTER_NAME" || true
  fi
  rm -f "$kc"
fi
if [ "$need_create" = 1 ]; then
  log_info "creating kind cluster '$CLUSTER_NAME' from $KIND_CONFIG"
  # Assemble args in an array so the optional --image is added only when set.
  create_args=(create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG")
  if [ -n "$NODE_IMAGE" ]; then
    log_info "using pinned node image: $NODE_IMAGE"
    create_args+=(--image "$NODE_IMAGE")
  else
    log_info "KIND_NODE_IMAGE empty — using kind's built-in default node image"
  fi
  run kind "${create_args[@]}"
fi

# --- 2. Export the kubeconfig + publish context to downstream scripts --------
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
log_info "writing kubeconfig -> $KUBECONFIG_PATH"
kind get kubeconfig --name "$CLUSTER_NAME" > "$KUBECONFIG_PATH"

# CLAIM THE SINK BEFORE THE FIRST WRITE — the KinD flow must never write into a sink it did not
# create. It used to upsert its values into WHATEVER file was there and then stamp it `--kind`; on a
# box where a real lab had written that sink, this re-stamped the LAB's state as KinD state, and
# `make kind-down` — which BOTH lab runbooks tell the operator to run at Step 0 — then DELETED it,
# taking the lab's discovered state and its generated passwords with it. state_claim_kind archives a
# foreign sink (never `rm`) and unsets what it had already exported into this process, so the
# "generate the password only if unset" lines below cannot silently reuse a real lab's credential.
state_claim_kind

# Absolute path so the value works regardless of the caller's CWD.
KUBECONFIG_ABS="$(cd "$(dirname "$KUBECONFIG_PATH")" && pwd)/$(basename "$KUBECONFIG_PATH")"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
state_set KUBECONFIG "$KUBECONFIG_ABS"
# Record it separately: `make kind-down` must delete ONLY the kubeconfig THIS flow wrote. It used to
# delete any kubeconfig under ./secrets — which is where the DOCUMENTED real-lab default lives
# (secrets/vks.kubeconfig), so a lab operator following Step 0 of their own runbook lost it.
state_set KIND_KUBECONFIG "$KUBECONFIG_ABS"
state_set VKS_AUTH_METHOD kubeconfig
state_set VKS_CONTEXT "$KIND_CONTEXT"
# Zero-config KinD: generate THROWAWAY test passwords for the local Harbor + Gitea admin
# (this cluster is destroyed at teardown) so `make e2e-kind` needs NO manual .env. Written
# only when unset — a real `.env` value still wins (it is the only-when-unset guard, not
# sourcing order, that ensures this — the .env.state overlay is sourced AFTER .env). NOT
# generated HERE on the real lab (05-kind-up.sh runs only for the KinD stand-in).
# Revealed via `make creds`. gen_password is a
# random, complexity-valid, NON-hardcoded value (lib/os.sh). ArgoCD's admin password stays
# auto-generated when blank. NOTE: task #13 (env-init/env-populate) will move this into an
# explicit `.env` populate step; kept here as the validated interim that unblocks #98's smoke.
[ -n "${HARBOR_PASSWORD:-}" ]      || state_set HARBOR_PASSWORD "$(gen_password)"
[ -n "${GITEA_ADMIN_PASSWORD:-}" ] || state_set GITEA_ADMIN_PASSWORD "$(gen_password)"
# ArgoCD too — and it MUST be generated HERE, into the state overlay .env.state, not left to `.env`.
#
# `make e2e-kind` runs with SKIP_DOTENV=1 (it stands in for a fresh operator / a CI runner, neither
# of which has a .env). So an ARGOCD_ADMIN_PASSWORD sitting in `.env` is NOT seen by
# 07-install-argocd.sh and is NEVER APPLIED — ArgoCD keeps its auto-generated password. But
# `make argocd-password` does NOT skip .env, so it would happily print the .env value: a password
# that does not work. The user is told a password and cannot log in.
#
# .env.state IS sourced under SKIP_DOTENV, so generating it here means 07 applies it and
# `make creds-show` prints the password that actually works.
[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ] || state_set ARGOCD_ADMIN_PASSWORD "$(gen_password)"
log_info "published KUBECONFIG/VKS_AUTH_METHOD/VKS_CONTEXT (+ generated KinD Harbor/Gitea/ArgoCD creds; see 'make creds-show') to $(state_file)"

# Point subsequent kubectl calls at the kind cluster.
export KUBECONFIG="$KUBECONFIG_ABS"

# STAMP ONLY NOW — AFTER KUBECONFIG points at the cluster we just created.
#
# state_stamp reads the AMBIENT $KUBECONFIG. Stamping earlier recorded whatever load_env had defaulted
# to — `secrets/vks.kubeconfig`. On THIS box that happened to be a stale KinD file, so the stamp looked
# right. ON A LAB BOX secrets/vks.kubeconfig IS THE LAB: `make e2e-kind` would have stamped the KinD
# sink with the LAB's API server, and then either ARCHIVED the live KinD sink away (destroying the only
# copy of the generated passwords) or let a LAB run source KinD's LB IPs and CA — the exact
# cross-cluster contamination the stamp exists to prevent, wearing a green stamp.
state_stamp --kind

# --- 3. Start cloud-provider-kind (detached) for LoadBalancer IPs ------------
# It watches the `kind` docker network and assigns external IPs to LB Services.
if docker ps -a --format '{{.Names}}' | grep -qxF "$CPK_CONTAINER"; then
  log_info "removing existing '$CPK_CONTAINER' container before (re)start"
  run docker rm -f "$CPK_CONTAINER"
fi
log_info "starting $CPK_CONTAINER ($CPK_IMAGE) — manages LB via the docker socket"
# Per the cloud-provider-kind README: run with --network host + the docker socket;
# it creates the per-Service envoy sidecars on the kind network itself via the API.
#
# --gateway-channel=disabled IS LOAD-BEARING — it is what lets the e2e test our OWN Gateway API CRD
# install at all. CPK's default channel is `standard`, so it FORCE-INSTALLS the Gateway API CRDs at
# cluster start (cmd/app.go: default "standard"; controller.go: `if GatewayReleaseChannel != Disabled
# { InstallCRDs(...) }`). istio_ensure_gwapi_crds then found the CRDs already present, logged
# "already present" and returned — so the code path that installs them HAS NEVER RUN, on any machine.
# A green e2e printing "Gateway API CRDs: PRESENT" was measuring CPK's KinD shim, which is the very
# thing that install exists to remove. It was a FALSE PROOF.
#
# Disabling the channel is safe and source-verified: CRD installation is a SEPARATE, gated code path
# from the Service-LoadBalancer controller, so LB IPs keep working (asserted in the e2e).
#
# It is also what keeps CPK clear of an admission policy that is ALREADY IN THIS CLUSTER. The
# gateway-api STANDARD bundle we install ships the `safe-upgrades` ValidatingAdmissionPolicy (see
# bundle/manifests/gateway-api-v1.5.1.yaml — channel: standard), whose CEL DENIES any gateway-api CRD
# whose bundle-version matches v1.[0-4].\d+ or v0 (i.e. anything before v1.5.0). CPK force-reconciles
# its EMBEDDED CRDs at startup with a plain Create(), so it is subject to that policy — the CPK pinned
# by CLOUD_PROVIDER_KIND_VERSION vendors v1.5.1 today and PASSES. What keeps this safe is CPK's
# vendored version PLUS this flag; it is NOT our GATEWAY_API_VERSION pin. If the flag were dropped and
# CPK vendored an older bundle, its CRD install would be DENIED, it aborts the WHOLE controller, and
# every LoadBalancer silently stops getting an IP — surfacing as "Harbor LB did not get an external
# IP", an error that points nowhere near an admission policy. Hence the crash-line assert below.
# THE HOST SOCKET IS DERIVED, NOT HARDCODED.
#
# It used to be `-v /var/run/docker.sock:/var/run/docker.sock`. ROOTLESS DOCKER HAS NO SUCH FILE — its
# socket is $XDG_RUNTIME_DIR/docker.sock (e.g. /run/user/1000/docker.sock). So for an operator running
# rootless docker (a supported configuration: it is the ONLY docker mode that is sudo-free, and it is
# measured green in docs/decisions/container-engine-support.md), docker would create an EMPTY DIRECTORY at
# /var/run/docker.sock, cloud-provider-kind would find no daemon, and NO LoadBalancer would ever get an
# IP — surfacing as "Harbor LoadBalancer did not get an external IP", an error that points nowhere near a
# socket path.
#
# DOCKER_HOST is the authority (it is what the rootless setup exports); fall back to the rootful default.
# We still mount it AT /var/run/docker.sock inside the container, because that is where CPK looks.
CPK_HOST_SOCK="/var/run/docker.sock"
case "${DOCKER_HOST:-}" in
  unix://*) CPK_HOST_SOCK="${DOCKER_HOST#unix://}" ;;
  "")       [ -S "${XDG_RUNTIME_DIR:-/nonexistent}/docker.sock" ] && CPK_HOST_SOCK="${XDG_RUNTIME_DIR}/docker.sock" ;;
esac
[ -S "$CPK_HOST_SOCK" ] || die "no docker socket at '$CPK_HOST_SOCK' (DOCKER_HOST='${DOCKER_HOST:-<unset>}').
  cloud-provider-kind talks to the docker daemon through this socket; without it NO LoadBalancer gets an IP.
  Rootless docker: it lives at \$XDG_RUNTIME_DIR/docker.sock — make sure DOCKER_HOST is exported."
log_info "cloud-provider-kind will use the docker socket at ${CPK_HOST_SOCK}"

run docker run -d \
  --name "$CPK_CONTAINER" \
  --network host \
  --restart unless-stopped \
  -v "${CPK_HOST_SOCK}:/var/run/docker.sock" \
  "$CPK_IMAGE" --gateway-channel=disabled

# --- 4. Readiness: poll until all nodes are Ready (bounded, with delay) -------
log_info "waiting for all nodes to become Ready (timeout ${READY_TIMEOUT}s, poll ${POLL_INTERVAL}s)"
deadline=$(( SECONDS + READY_TIMEOUT ))
until kubectl wait --for=condition=Ready nodes --all \
        --timeout="${POLL_INTERVAL}s" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    log_error "nodes did not become Ready within ${READY_TIMEOUT}s; current state:"
    kubectl get nodes >&2 || true
    die "kind cluster '$CLUSTER_NAME' failed readiness"
  fi
  log_info "nodes not Ready yet — retrying in ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
log_info "all nodes Ready"

# --- 4b. ASSERT the CPK flag actually took effect -----------------------------
#
# Positive proof, from CPK's own log (controller.go logs this on the disabled branch). Without it we
# would only know the flag was PASSED, not that it was parsed and honoured.
#
# And count CRASH lines rather than trusting `docker ps`: the container runs with
# `--restart unless-stopped`, so a crash-looping CPK shows `Up` BETWEEN cycles — status false-greens.
sleep 2
cpk_log="$(docker logs "$CPK_CONTAINER" 2>&1 || true)"
if ! printf '%s' "$cpk_log" | grep -q 'Gateway API CRDs installation skipped'; then
  log_error "cloud-provider-kind did NOT log that it skipped the Gateway API CRD install."
  log_error "  Either --gateway-channel=disabled was not honoured by this CPK version, or CPK is"
  log_error "  installing the CRDs anyway — which makes our own CRD install untestable (a FALSE PROOF)."
  printf '%s\n' "$cpk_log" | tail -20 >&2
  die "cloud-provider-kind is still managing the Gateway API CRDs"
fi
crashes="$(printf '%s' "$cpk_log" | grep -c 'Failed to start\|Failed to install Gateway API CRDs' || true)"
[ "${crashes:-0}" -eq 0 ] || die "cloud-provider-kind is crash-looping (${crashes} failure lines) — LoadBalancers will never get an IP"
log_info "cloud-provider-kind: Gateway API CRD management is DISABLED (we install them ourselves), 0 crash lines"

# --- 5. Summary --------------------------------------------------------------
kubectl get nodes >&2 || true
log_info "kind cluster '$CLUSTER_NAME' is up (context: $KIND_CONTEXT)"
log_info "next step: make install-harbor"
