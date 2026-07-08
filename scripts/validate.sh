#!/usr/bin/env bash
# validate.sh — offline manifest validation (no cluster required).
#   - `kustomize build deploy/base` renders, then kubeconform validates it.
#   - Tekton + ArgoCD YAML are validated with kubeconform in
#     -ignore-missing-schemas mode (their CRDs aren't in the default schema set).
# A missing tool is warned-and-skipped; a present tool that finds errors fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.31.0}"
RENDERED=/tmp/vks-deploy-rendered.yaml
# Cache downloaded JSON schemas so the multiple kubeconform runs below share them
# and re-runs don't re-fetch (githubusercontent rate-limits under heavy use).
KC_CACHE="${KUBECONFORM_CACHE:-${HOME}/.cache/kubeconform}"
mkdir -p "$KC_CACHE"

# kubeconform, retried — its JSON schemas are fetched from githubusercontent, which
# rate-limits/times out under load ("giving up after N attempts"). Retry the whole
# run a few times so a transient schema-download blip doesn't fail the gate; a real
# invalid manifest still fails on every attempt.
kc() {
  local n=0
  until kubeconform -cache "$KC_CACHE" -kubernetes-version "$KUBERNETES_VERSION" "$@"; do
    n=$((n + 1)); [ "$n" -ge 4 ] && return 1
    log_warn "kubeconform attempt $n failed (likely transient schema download) — retrying in 8s"
    sleep 8
  done
}

# kustomize_build DIR OUT — prefer standalone kustomize, fall back to `kubectl kustomize`.
kustomize_build() {
  if have kustomize; then kustomize build "$1" > "$2"
  elif have kubectl; then kubectl kustomize "$1" > "$2"
  else return 127; fi
}

echo "== kustomize build (deploy/base) =="
if [ -d "$REPO_ROOT/deploy/base" ]; then
  if kustomize_build "$REPO_ROOT/deploy/base" "$RENDERED"; then
    log_info "kustomize build OK ($(grep -c '^kind:' "$RENDERED") resources)"
    if have kubeconform; then
      kc -strict -summary -ignore-missing-schemas "$RENDERED" || rc=1
    elif have kubectl; then
      log_info "kubeconform absent — falling back to 'kubectl apply --dry-run=client'"
      kubectl apply --dry-run=client -f "$RENDERED" >/dev/null || rc=1
    else
      log_warn "no kubeconform/kubectl — deploy manifests unchecked against schemas"
    fi
  else
    log_error "kustomize build failed (need kustomize or kubectl)"; rc=1
  fi
else
  log_warn "deploy/base not present yet — skipped"
fi

echo "== kubeconform (tekton/ + argocd/) =="
if have kubeconform; then
  for dir in tekton argocd k8s; do
    if [ -d "$REPO_ROOT/$dir" ] && find "$REPO_ROOT/$dir" -name '*.yaml' | read -r _; then
      log_info "validating $dir/"
      mapfile -d '' _files < <(find "$REPO_ROOT/$dir" -name '*.yaml' -print0)
      kc -summary -ignore-missing-schemas "${_files[@]}" || rc=1
    else
      log_warn "$dir/ has no manifests yet — skipped"
    fi
  done
else
  log_warn "kubeconform not installed — tekton/argocd manifests unchecked"
fi

if [ "$rc" -eq 0 ]; then log_info "validate: OK"; else log_error "validate: findings above"; fi
exit "$rc"
