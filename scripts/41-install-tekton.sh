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
kubeconfig_ready
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

# Create tekton-pipelines WITH its labels BEFORE the upstream manifests, which ship their own
# `kind: Namespace` and would otherwise create it bare.
#
# Why here and not in the ingress step (F2): the only ensure_namespace calls for tekton lived in
# lib/istio.sh's route functions (:279, :567), reachable ONLY from `make install-ingress` — which
# `make install-all` (Makefile:459) does NOT run. So on a real lab the label landed never. Worse,
# with INGRESS_CONTROLLER=traefik nothing calls istio_apply_routes* at all, yet traefik still routes
# the Tekton dashboard — so tekton was unlabelled on that path in every mode.
#
# ORDER IS DELIBERATE AND SPLIT — read this before touching it.
#
# This comment USED to say "our labels are in OUR last-applied, theirs carry no conflicting keys, so
# applying after us does not strip them." That was FALSE, twice over: this script applies with
# `--server-side --force-conflicts` (:38), so client-side last-applied semantics do not apply at all;
# and the upstream Namespace document DOES declare a conflicting key —
# `pod-security.kubernetes.io/enforce: restricted`. Per the SSA reference, force "changes the value
# of the field, and removes the field from all other managers' entries in managedFields". So:
#
#   istio-injection=disabled   SURVIVES  (upstream never declares it)  <- the B26 control is safe
#   pod-security…/audit,/warn  SURVIVE   (upstream declares only enforce)
#   pod-security…/enforce      OVERWRITTEN to restricted, ownership stolen
#
# It is masked today only because PSA_LEVEL_TEKTON defaults to `restricted` — value-identical. Set
# PSA_LEVEL_TEKTON=baseline (a knob psa.sh advertises) and you get enforce=restricted with
# audit/warn=baseline: an incoherent namespace where the ONLY label that rejects pods is silently
# reverted to something the operator did not ask for.
#
# Hence the split: ensure_namespace runs BEFORE (the injection label must precede the pods —
# webhooks fire on CREATE), and psa_label_namespace is re-asserted AFTER the manifests, to take the
# enforce field back. Mirrors 70-configure-argocd.sh:362 (apps) and 40-install-gitea.sh (gitea).
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
ensure_namespace "${TEKTON_NAMESPACE:-tekton-pipelines}" "${PSA_LEVEL_TEKTON:-restricted}"
# The upstream manifest declares TWO namespaces, and this is the second one. It needs the
# no-inject label specifically — upstream already sets `pod-security.kubernetes.io/enforce:
# restricted` on it, so PSA is covered and PSA is NOT the hazard: in attach mode a platform mesh
# injects the resolver pod, istio-init requests NET_ADMIN, and upstream's OWN `restricted` label
# rejects it — the remote resolvers silently never run.
#
# We already knew this namespace existed: :72 waits on it by name. It was simply never labelled,
# by anything. It is hardcoded rather than a var because upstream hardcodes it (it is not
# configurable), and it is passed `restricted` to match the label upstream sets rather than to
# fight it.
ensure_namespace "tekton-pipelines-resolvers" "${PSA_LEVEL_TEKTON:-restricted}"

apply_manifest "$pipe"
apply_manifest "$trig"
apply_manifest "$intc"
apply_manifest "$dash"

# Take `enforce` back. The upstream Namespace doc declares it, and `--server-side --force-conflicts`
# above just overwrote ours and stole the field's ownership (see the SSA note further up). Without
# this, PSA_LEVEL_TEKTON is a knob that silently does nothing for the one label that rejects pods.
# Only the PSA labels need re-asserting — istio-injection survives, since upstream never declares it.
psa_label_namespace "${TEKTON_NAMESPACE:-tekton-pipelines}" "${PSA_LEVEL_TEKTON:-restricted}"
psa_label_namespace "tekton-pipelines-resolvers"            "${PSA_LEVEL_TEKTON:-restricted}"

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
