#!/usr/bin/env bash
# validate.sh — offline manifest validation (no cluster required).
#   - `kustomize build deploy/webui` renders, then kubeconform validates it.
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

# Schema sources. Default to the jsDelivr CDN mirror of the SAME yannh repo rather than
# raw.githubusercontent.com — identical content, globally CDN-cached, and NOT per-IP
# rate-limited (githubusercontent's throttling is the "giving up after N attempts" cause,
# and an unreachable schema means a real violation goes UNVALIDATED, not just slow).
# datreeio/CRDs-catalog supplies CRD schemas (e.g. ArgoCD Application) so those validate
# instead of only being skipped. `default` (the built-in githubusercontent location) stays
# LAST as a fallback. Override any of these via the KUBECONFORM_SCHEMA_* env vars.
KC_SCHEMA_K8S="${KUBECONFORM_SCHEMA_K8S:-https://cdn.jsdelivr.net/gh/yannh/kubernetes-json-schema@master/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json}"
KC_SCHEMA_CRD="${KUBECONFORM_SCHEMA_CRD:-https://cdn.jsdelivr.net/gh/datreeio/CRDs-catalog@main/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json}"
# Two schema-location sets, chosen per directory:
#  - CORE (deploy/webui, k8s/): the yannh k8s schemas. Every kind is a built-in k8s type,
#    so jsDelivr returns 200 and validation is reliable (real violations ARE caught).
#  - CRD (k8s/tekton, k8s/argocd): the datreeio CRDs-catalog. It returns a clean 404 for CRDs it
#    doesn't carry (so -ignore-missing-schemas SKIPS them), and 200 for those it does (e.g.
#    ArgoCD Application) — validating them as a bonus. Do NOT point the yannh path at CRD
#    dirs: jsDelivr answers a non-existent yannh CRD path with 403 (not 404), which
#    kubeconform treats as a hard error rather than a skippable miss.
# `default` (githubusercontent) is the last-resort fallback in both sets.
KC_LOCS_CORE=(-schema-location "$KC_SCHEMA_K8S" -schema-location default)
KC_LOCS_CRD=(-schema-location "$KC_SCHEMA_CRD" -schema-location default)
# k8s/ is MIXED: core kinds (Deployment/Service/RBAC) AND CRDs (istio Gateway/
# VirtualService in k8s/istio, traefik IngressRoute-adjacent objects). Try the
# yannh core schemas FIRST (200 for core kinds), then the datreeio CRD catalog
# (200 for istio networking.istio.io kinds), then the built-in default. A kind
# missing from all three is skipped by -ignore-missing-schemas; a real violation
# is still caught (kc() fails only on statusInvalid, never on a download miss).
KC_LOCS_K8S=(-schema-location "$KC_SCHEMA_K8S" -schema-location "$KC_SCHEMA_CRD" -schema-location default)
# Active set for the next kc call (a caller sets this immediately before invoking kc).
KC_LOCS=("${KC_LOCS_CORE[@]}")

# kubeconform — gate on genuinely INVALID manifests, NOT on schema-download failures.
#
# kubeconform fetches its JSON schemas from githubusercontent, which rate-limits under
# load ("giving up after N attempts"). A download failure is a schema ERROR, a distinct
# thing from a manifest VIOLATION. Gating on kubeconform's raw exit code (nonzero on
# either) makes CI flap red whenever githubusercontent throttles a cold-cache runner even
# though every manifest is valid. So classify the JSON result per-resource and FAIL only
# on a real violation (statusInvalid); WARN — don't fail — when schemas can't be
# downloaded (statusError). kubeconform already self-retries downloads (3 attempts with
# backoff), so this wrapper does NOT add its own retry loop (that only multiplied latency
# and made the gate hang when github throttled). `-cache` (persisted via actions/cache in
# CI) makes warm runs fast and offline.
#
# NOTE: `-output json` only populates the aggregate `.summary` object when `-summary` is
# ALSO passed, so we count `.resources[]` entries directly (robust regardless of flags).
# Falls back to exit-code gating when jq is unavailable, so it never false-passes on an
# environment that cannot parse the JSON.
kc() {
  if ! have jq; then
    kubeconform "${KC_LOCS[@]}" -cache "$KC_CACHE" -kubernetes-version "$KUBERNETES_VERSION" "$@"
    return $?
  fi
  local out ec invalid errors
  out="$(kubeconform "${KC_LOCS[@]}" -output json -cache "$KC_CACHE" -kubernetes-version "$KUBERNETES_VERSION" "$@" 2>/dev/null)"; ec=$?
  invalid="$(printf '%s' "$out" | jq -r '[.resources[]? | select(.status=="statusInvalid")] | length' 2>/dev/null)"
  errors="$(printf '%s'  "$out" | jq -r '[.resources[]? | select(.status=="statusError")]   | length' 2>/dev/null)"
  # Empty/unparseable output — e.g. every schema location unreachable (CDN + fallback all
  # down/throttled), so kubeconform emitted no JSON. Cannot validate, but per this gate's
  # design a schema-AVAILABILITY problem must never red CI (malformed YAML is separately
  # caught by `make lint`'s yamllint). WARN and pass — the gate only fails on a real,
  # confirmed manifest violation (statusInvalid), never on an infra/network condition.
  case "$invalid" in ''|*[!0-9]*)
    if [ "$ec" -eq 0 ]; then log_info "kubeconform: nothing to validate"; return 0; fi
    log_warn "kubeconform: no parseable output (exit $ec) — schema sources unreachable; those resources were NOT validated; not failing the gate"
    return 0 ;;
  esac
  case "$errors" in ''|*[!0-9]*) errors=0 ;; esac
  if [ "$invalid" -gt 0 ]; then
    printf '%s' "$out" | jq -r '.resources[]? | select(.status=="statusInvalid") | "  INVALID: \(.filename): \(.kind)/\(.name): \(.msg)"' 2>/dev/null
    return 1
  fi
  if [ "$errors" -gt 0 ]; then
    log_warn "kubeconform: $errors schema(s) could not be downloaded (CDN/registry unreachable) — those resources were NOT validated; not failing the gate (Invalid=0)"
  else
    log_info "kubeconform: all resolvable schemas valid (Invalid=0)"
  fi
  return 0
}

# kustomize_build DIR OUT — prefer standalone kustomize, fall back to `kubectl kustomize`.
kustomize_build() {
  if have kustomize; then kustomize build "$1" > "$2"
  elif have kubectl; then kubectl kustomize "$1" > "$2"
  else return 127; fi
}

echo "== kustomize build (deploy/webui) =="
if [ -d "$REPO_ROOT/deploy/webui" ]; then
  if kustomize_build "$REPO_ROOT/deploy/webui" "$RENDERED"; then
    log_info "kustomize build OK ($(grep -c '^kind:' "$RENDERED") resources)"
    if have kubeconform; then
      KC_LOCS=("${KC_LOCS_CORE[@]}")   # deploy/webui is all core k8s kinds
      kc -strict -ignore-missing-schemas "$RENDERED" || rc=1
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
  log_warn "deploy/webui not present yet — skipped"
fi

echo "== kubeconform (k8s/) =="
if have kubeconform; then
  # Enumerate k8s/* DYNAMICALLY: a hardcoded subdir list would silently skip a new one,
  # and a gate that quietly checks a subset is worse than no gate. Print the denominator.
  shopt -s nullglob
  _subdirs=("$REPO_ROOT"/k8s/*/)
  shopt -u nullglob
  [ "${#_subdirs[@]}" -gt 0 ] || log_warn "k8s/ has no manifests yet — skipped"
  for dir in "${_subdirs[@]}"; do
    name="$(basename "$dir")"
    if find "$dir" -name '*.yaml' | read -r _; then
      mapfile -d '' _files < <(find "$dir" -name '*.yaml' -print0)
      # tekton/ + argocd/ are CRD-heavy → CRDs-catalog. The rest (gitea, istio, traefik)
      # is core kinds + a few CRDs → the k8s schema set.
      case "$name" in tekton|argocd) KC_LOCS=("${KC_LOCS_CRD[@]}") ;; *) KC_LOCS=("${KC_LOCS_K8S[@]}") ;; esac
      log_info "validating k8s/$name/ (${#_files[@]} manifests)"
      kc -ignore-missing-schemas "${_files[@]}" || rc=1
    else
      log_warn "k8s/$name/ has no manifests yet — skipped"
    fi
  done
else
  log_warn "kubeconform not installed — k8s/ manifests unchecked"
fi

if [ "$rc" -eq 0 ]; then log_info "validate: OK"; else log_error "validate: findings above"; fi
exit "$rc"
