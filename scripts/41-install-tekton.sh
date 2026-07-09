#!/usr/bin/env bash
# 41-install-tekton.sh — install Tekton Pipelines + Triggers on VKS from the
# mirrored release manifests, rewriting every upstream image reference to Harbor.
#
# The release manifests were fetched by 10-mirror-pull.sh into $BUNDLE_DIR/manifests
# and their images mirrored to Harbor. Here we apply them with the image hosts
# rewritten (gcr.io/… , ghcr.io/… -> $HARBOR_URL/$HARBOR_INFRA_PROJECT/…), matching
# lib/mirror.sh's host-strip mapping exactly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd kubectl
: "${KUBECONFIG:?}"; export KUBECONFIG
: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${BUNDLE_DIR:?}"
: "${TEKTON_PIPELINES_VERSION:?}"; : "${TEKTON_TRIGGERS_VERSION:?}"; : "${TEKTON_DASHBOARD_VERSION:?}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"

MANIFEST_DIR="${BUNDLE_DIR}/manifests"
[ -d "$MANIFEST_DIR" ] || die "no manifests at $MANIFEST_DIR — run 'make mirror-pull' (or transfer the bundle) first"

prefix="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}"
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

apply_manifest() {
  # apply_manifest <file>  — rewrite image hosts to Harbor, then server-side apply.
  local src="$1" out
  out="${render_dir}/$(basename "$1")"
  [ -f "$src" ] || die "expected manifest missing: $src"
  # Strip the upstream registry host and prepend Harbor/<infra project>, mirroring
  # lib/mirror.sh (which pulls gcr.io/foo -> $HARBOR/$PROJECT/foo).
  sed -E "s#(gcr\.io|ghcr\.io|registry\.k8s\.io|docker\.io)/#${prefix}/#g" "$src" > "$out"
  log_info "applying $(basename "$src") (images -> $prefix)"
  run kubectl apply --server-side --force-conflicts -f "$out"
}

pipe="${MANIFEST_DIR}/tekton-pipelines-${TEKTON_PIPELINES_VERSION}.yaml"
trig="${MANIFEST_DIR}/tekton-triggers-${TEKTON_TRIGGERS_VERSION}.yaml"
intc="${MANIFEST_DIR}/tekton-triggers-interceptors-${TEKTON_TRIGGERS_VERSION}.yaml"
# Dashboard (web UI) — read-only release, into the same tekton-pipelines namespace.
dash="${MANIFEST_DIR}/tekton-dashboard-${TEKTON_DASHBOARD_VERSION}.yaml"

apply_manifest "$pipe"
apply_manifest "$trig"
apply_manifest "$intc"
apply_manifest "$dash"

log_info "waiting for Tekton controllers to become ready (timeout ${READY_TIMEOUT_SECONDS}s)"
run kubectl -n "${TEKTON_NAMESPACE:-tekton-pipelines}" wait --for=condition=Available \
  --timeout="${READY_TIMEOUT_SECONDS}s" deploy --all
# Triggers may live in tekton-pipelines (default) — wait there too if separate.
if kubectl get ns tekton-pipelines-resolvers >/dev/null 2>&1; then
  run kubectl -n tekton-pipelines-resolvers wait --for=condition=Available \
    --timeout="${READY_TIMEOUT_SECONDS}s" deploy --all || true
fi

log_info "Tekton installed. Controllers:"
kubectl -n "${TEKTON_NAMESPACE:-tekton-pipelines}" get deploy >&2
