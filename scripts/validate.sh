#!/usr/bin/env bash
# validate.sh — offline manifest validation (no cluster required).
#   - `kustomize build deploy/javawebapp` renders, then kubeconform validates it.
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
# ⚠️ DO NOT WRITE THESE AS ${VAR:-<default containing }}>}. MEASURED 2026-08-10: bash ends a
# ${...:-...} expansion at the FIRST `}` of the first `}}`, so a Go-template URL is silently
# MANGLED — `{{ .NormalizedKubernetesVersion }}` became `{{ .NormalizedKubernetesVersion }` with a
# stray `}` appended to the end of the URL:
#   .../{{ .NormalizedKubernetesVersion }-standalone{{ .StrictSuffix }}/...{{ .KindSuffix }}.json}
# Every schema fetch then 404s, kubeconform emits no JSON and exits non-zero, and the lenient
# handler below — correctly designed so a schema-AVAILABILITY problem never reds CI — warns and
# PASSES. Net effect: `make validate` validated ZERO resources and printed OK, on every run, while
# spending its time on failing network round-trips. A gate that passes by not looking.
# Single-quoted assignment, then an explicit override check: no expansion, nothing to mangle.
KC_SCHEMA_K8S='https://cdn.jsdelivr.net/gh/yannh/kubernetes-json-schema@master/{{ .NormalizedKubernetesVersion }}-standalone{{ .StrictSuffix }}/{{ .ResourceKind }}{{ .KindSuffix }}.json'
KC_SCHEMA_CRD='https://cdn.jsdelivr.net/gh/datreeio/CRDs-catalog@main/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json'
[ -n "${KUBECONFORM_SCHEMA_K8S:-}" ] && KC_SCHEMA_K8S="$KUBECONFORM_SCHEMA_K8S"
[ -n "${KUBECONFORM_SCHEMA_CRD:-}" ] && KC_SCHEMA_CRD="$KUBECONFORM_SCHEMA_CRD"
# Two schema-location sets, chosen per directory:
#  - CORE (deploy/javawebapp, k8s/): the yannh k8s schemas. Every kind is a built-in k8s type,
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
# NOTE: `-output json` emits `.resources[]` for NON-VALID resources only — a VALID one appears
# there just with `-verbose`. MEASURED 2026-08-10 on a 3-document manifest: `-output json` gives
# `{"resources": []}`, while adding `-summary` gives `summary.valid = 3`. So `.resources[]` is the
# right place to read FAILURES from, and is USELESS as a denominator — which is why `-summary` is
# passed and the total is read from `.summary`. An earlier comment here claimed the opposite.
# Falls back to exit-code gating when jq is unavailable, so it never false-passes on an
# environment that cannot parse the JSON.
kc() {
  if ! have jq; then
    kubeconform "${KC_LOCS[@]}" -cache "$KC_CACHE" -kubernetes-version "$KUBERNETES_VERSION" "$@"
    return $?
  fi
  local out ec invalid errors valid skipped
  out="$(kubeconform "${KC_LOCS[@]}" -output json -summary -cache "$KC_CACHE" -kubernetes-version "$KUBERNETES_VERSION" "$@" 2>/dev/null)"; ec=$?
  invalid="$(printf '%s' "$out" | jq -r '[.resources[]? | select(.status=="statusInvalid")] | length' 2>/dev/null)"
  errors="$(printf '%s'  "$out" | jq -r '[.resources[]? | select(.status=="statusError")]   | length' 2>/dev/null)"
  # valid and skipped are read SEPARATELY because `total` folds skipped in (below) and the
  # "all schemas resolvable" claim used to be printed over them. MEASURED 2026-08-17 with real
  # kubeconform v0.8.0: a CRD kind against an empty local location yields
  # {valid:0, invalid:0, errors:0, skipped:1}, and this function printed
  #   "1 resource(s) validated, all schemas resolvable (Invalid=0)"
  # -- i.e. it claimed to have validated the one resource it had SKIPPED. `-ignore-missing-schemas`
  # turns a miss into `skipped` with errors:0, so KUBECONFORM_REQUIRE_SCHEMAS=1 never fired on it.
  valid="$(printf '%s'   "$out" | jq -r '(.summary.valid   // 0)' 2>/dev/null)"
  skipped="$(printf '%s' "$out" | jq -r '(.summary.skipped // 0)' 2>/dev/null)"
  case "$valid"   in ''|*[!0-9]*) valid=0   ;; esac
  case "$skipped" in ''|*[!0-9]*) skipped=0 ;; esac
  # THE DENOMINATOR. Without it this gate can validate ZERO resources and print OK — measured by
  # an adversary round 2026-08-10: with no network, 8 of 8 kubeconform invocations validated
  # nothing and `validate: OK` was printed, rc=0. Counting only the FAILURES (invalid/errors) is
  # the classic gate-that-passes-by-not-looking: 0 invalid is indistinguishable from 0 examined.
  total="$(printf '%s'  "$out" | jq -r '(.summary.valid // 0) + (.summary.invalid // 0) + (.summary.errors // 0) + (.summary.skipped // 0)' 2>/dev/null)"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  # Empty/unparseable output — e.g. every schema location unreachable (CDN + fallback all
  # down/throttled), so kubeconform emitted no JSON. Cannot validate, but per this gate's
  # design a schema-AVAILABILITY problem must never red CI (malformed YAML is separately
  # caught by `make lint`'s yamllint). WARN and pass — the gate only fails on a real,
  # confirmed manifest violation (statusInvalid), never on an infra/network condition.
  case "$invalid" in ''|*[!0-9]*)
    if [ "$ec" -eq 0 ]; then log_info "kubeconform: nothing to validate"; return 0; fi
    if [ "${KUBECONFORM_REQUIRE_SCHEMAS:-0}" = 1 ]; then
      log_error "kubeconform: no parseable output (exit $ec) — every schema source was unreachable, so"
      log_error "  ZERO resources were validated, and KUBECONFORM_REQUIRE_SCHEMAS=1 (CI sets this)."
      log_error "  CI has network by definition: here a failed fetch is a FAILURE, not a skip."
      return 1
    fi
    log_warn "kubeconform: no parseable output (exit $ec) — schema sources unreachable; those resources were NOT validated; not failing the gate"
    return 0 ;;
  esac
  case "$errors" in ''|*[!0-9]*) errors=0 ;; esac
  if [ "$invalid" -gt 0 ]; then
    printf '%s' "$out" | jq -r '.resources[]? | select(.status=="statusInvalid") | "  INVALID: \(.filename): \(.kind)/\(.name): \(.msg)"' 2>/dev/null
    return 1
  fi
  # A schema-AVAILABILITY problem must never red CI (the design decision above), so `errors`
  # stays a WARN. But "kubeconform parsed output and yet examined NOTHING, with nothing even
  # erroring" is not a network condition — it means the input list matched no resources (a glob
  # that stopped matching, a renamed dir, an empty kustomize render). That is a real defect and
  # the one case where silence is worse than a red.
  if [ "$total" -eq 0 ] && [ "$errors" -eq 0 ]; then
    log_error "kubeconform: examined ZERO resources and reported no errors — the inputs matched"
    log_error "  nothing. This gate cannot pass by not looking. Check the paths it was given:"
    log_error "    $*"
    return 1
  fi
  if [ "$errors" -gt 0 ]; then
    # KUBECONFORM_REQUIRE_SCHEMAS=1 turns the skip into a FAILURE, exactly as GWAPI_REQUIRE_FETCH=1
    # does for check-gwapi-istio-alignment. The lenient default above is a deliberate LOCAL-DEV
    # decision (a laptop on a train must not red on a CDN), and it was silently the CI behaviour
    # too. MEASURED 2026-08-16 with both overridable schema sources pointed at a black hole:
    #   VALIDATE_RC=0, "validate: OK", and EIGHT directories reporting N-of-N could not download
    #   (16/16, 9/9, 8/8, 3/3, 2/2, 2/2, 1/1, 1/1) — a green gate over ZERO validated resources.
    # (My first repro of this was VACUOUS: it set KC_SCHEMA_*, which this script overwrites, so it
    # validated normally against the live CDN and passed for the RIGHT reason. The override names
    # are KUBECONFORM_SCHEMA_K8S / _CRD.)
    if [ "${KUBECONFORM_REQUIRE_SCHEMAS:-0}" = 1 ]; then
      log_error "kubeconform: $errors of $total resource(s) could not have their schema downloaded, and"
      log_error "  KUBECONFORM_REQUIRE_SCHEMAS=1 (CI sets this). Those resources were NOT validated;"
      log_error "  passing here would report OK over work the gate did not do. Inputs: $*"
      return 1
    fi
    log_warn "kubeconform: $errors of $total resource(s) could not have their schema downloaded (CDN/registry unreachable) — those were NOT validated; not failing the gate (Invalid=0)"
    log_warn "  (CI sets KUBECONFORM_REQUIRE_SCHEMAS=1 so this path is a FAILURE there, not a skip.)"
  elif [ "$skipped" -gt 0 ]; then
    # NOT "validated". A skipped resource had no schema to check it against, so saying otherwise
    # is the passes-by-not-looking failure this function's own denominator comment exists to close,
    # one level down: the denominator was right and `skipped` was counted as work done.
    log_warn "kubeconform: $valid validated, $skipped skipped (NO SCHEMA - not checked), 0 unfetchable, of $total resource(s)"
    log_warn "  a skipped resource is UNVERIFIED, not clean. Declare genuinely unvalidatable kinds"
    log_warn "  with -skip <GVK> so a MISSING schema stays distinguishable from an EXEMPT one."
  else
    log_info "kubeconform: $total resource(s) validated, all schemas resolvable (Invalid=0, Skipped=0)"
  fi
  return 0
}

# kustomize_build DIR OUT — prefer standalone kustomize, fall back to `kubectl kustomize`.
kustomize_build() {
  if have kustomize; then kustomize build "$1" > "$2"
  elif have kubectl; then kubectl kustomize "$1" > "$2"
  else return 127; fi
}

echo "== kustomize build (every app's deploy dir) =="
# shellcheck source=scripts/lib/apps.sh
. "${REPO_ROOT}/scripts/lib/apps.sh"
_validated=0
while read -r _app; do
  [ -n "$_app" ] || continue
  _dir="${REPO_ROOT}/$(app_deploy "$_app")"
  if [ ! -d "$_dir" ]; then
    log_error "app '${_app}': deploy dir $(app_deploy "$_app") does not exist"; rc=1; continue
  fi
  if kustomize_build "$_dir" "$RENDERED"; then
    log_info "kustomize build OK for '${_app}' ($(grep -c '^kind:' "$RENDERED") resources)"
    _validated=$((_validated + 1))
    if have kubeconform; then
      KC_LOCS=("${KC_LOCS_CORE[@]}")   # an app's deploy manifests are all core k8s kinds
      kc -strict -ignore-missing-schemas "$RENDERED" || rc=1
    elif have kubectl; then
      log_info "kubeconform absent — falling back to 'kubectl apply --dry-run=client'"
      kubectl apply --dry-run=client -f "$RENDERED" >/dev/null || rc=1
    else
      log_warn "no kubeconform/kubectl — '${_app}' deploy manifests unchecked against schemas"
    fi
  else
    log_error "kustomize build failed for '${_app}' (need kustomize or kubectl)"; rc=1
  fi
done <<EOF
$(app_names)
EOF
# Print the DENOMINATOR: a gate that cannot say how many apps it checked cannot be trusted.
log_info "kustomize: validated ${_validated} app deploy dir(s)"

echo "== every app's Tekton TEST TASK must exist =="
# A pipeline referencing a Task that is not applied fails at PIPELINE time with `CouldntGetTask` —
# i.e. only when someone pushes, long after every gate went green. (It happened: the `go-test` task
# was written but never added to k8s/tekton/tasks/, so gowebapp's first PipelineRun died while
# javawebapp's succeeded.) Assert it statically instead.
_missing=""
while read -r _app; do
  [ -n "$_app" ] || continue
  _t="$(app_test_task "$_app")"
  if grep -qs "^  name: ${_t}$" "${REPO_ROOT}"/k8s/tekton/tasks/*.yaml; then
    log_info "test task OK: ${_app} -> ${_t}"
  else
    log_error "app '${_app}' needs Tekton task '${_t}', but no k8s/tekton/tasks/*.yaml defines it"
    _missing=1; rc=1
  fi
done <<EOF
$(app_names)
EOF
[ -z "$_missing" ] || log_error "  a pipeline referencing a missing Task fails at RUN time (CouldntGetTask), never at build time."

# ---------------------------------------------------------------------------------------------
# RENDER BEFORE VALIDATING. k8s/ manifests are TEMPLATES — 20 of them carry ${VAR} tokens that
# envsubst fills in at install time. Handing kubeconform the raw template validates something that
# is never applied, and it fails for reasons that are not defects:
#   Application/${APP_NAME} ... '${GITEA_HOST}' does not match pattern '^[a-z0-9]...'
#   /spec/topology/controlPlane/replicas: got string, want integer
# This was INVISIBLE until 2026-08-10 because a ${VAR:-<default with }}>} quoting bug mangled the
# schema URLs, so every fetch 404'd and the lenient handler passed the gate having validated ZERO.
#
# The placeholder VALUES are derived from the variable's SUFFIX, not from a hand-typed map — a map
# of 47 names would rot on the first new token. Anything unmatched gets a DNS-1123-safe name, which
# is what the overwhelming majority of these are.
# shellcheck disable=SC2016  # the single quotes are literal: grep needs the ERE, and `tr -d` is
# being given the CHARACTERS $ { } to delete — nothing here is meant to expand.
render_for_validation() {   # render_for_validation <src.yaml> <dst.yaml>
  local src="$1" dst="$2" v names=() env_assigns=()
  mapfile -t names < <(grep -ohE '\$\{[A-Z_][A-Z0-9_]*\}' "$src" | tr -d '${}' | sort -u)
  for v in "${names[@]}"; do
    case "$v" in
      *_COUNT|*_REPLICAS)  env_assigns+=("$v=1") ;;
      *_CIDR)              env_assigns+=("$v=10.0.0.0/16") ;;
      *_SIZE)              env_assigns+=("$v=1Gi") ;;
      *_BOOL)              env_assigns+=("$v=false") ;;
      *_SERVICE_TYPE)      env_assigns+=("$v=ClusterIP") ;;
      *_DEST_KEY)          env_assigns+=("$v=server") ;;   # a KEY in spec.destination, not a value
      *_IMAGE)             env_assigns+=("$v=example.test/placeholder:v1") ;;
      *_HOST)              env_assigns+=("$v=placeholder.example.test") ;;
      *_URL)               env_assigns+=("$v=https://placeholder.example.test") ;;  # covers *_CLONE_URL
      *)                   env_assigns+=("$v=placeholder") ;;
    esac
  done
  # `env -i`-free on purpose: envsubst only replaces the names we list, so the ambient environment
  # cannot leak a real value (or an empty one) into the rendered copy.
  local subst_list=""
  for v in "${names[@]}"; do subst_list="${subst_list}\${${v}}"; done
  if [ -n "$subst_list" ]; then
    env "${env_assigns[@]}" envsubst "$subst_list" < "$src" > "$dst"
  else
    cp "$src" "$dst"
  fi
}

echo "== kubeconform (k8s/) =="
if require_gate_tool kubeconform; then
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
      # Render each template into a temp dir and validate THAT — see render_for_validation above.
      _rdir="$(mktemp -d)"; _rendered=()
      for _f in "${_files[@]}"; do
        _out="${_rdir}/$(printf '%s' "${_f#"$REPO_ROOT"/}" | tr '/' '_')"
        render_for_validation "$_f" "$_out"
        _rendered+=("$_out")
      done
      log_info "validating k8s/$name/ (${#_files[@]} manifests, rendered)"
      kc -ignore-missing-schemas "${_rendered[@]}" || rc=1
      rm -rf "$_rdir"
    else
      log_warn "k8s/$name/ has no manifests yet — skipped"
    fi
  done
else
  log_warn "kubeconform not installed — k8s/ manifests unchecked"
fi

if [ "$rc" -eq 0 ]; then log_info "validate: OK"; else log_error "validate: findings above"; fi
exit "$rc"
