#!/usr/bin/env bash
# 96-verify-gateway-image.sh — every RUNNING Istio container must have been pulled from OUR Harbor.
#
# THE GAP (measured 2026-07-19: `grep -rn containerStatuses scripts/ Makefile k8s/` = ZERO hits).
# Nothing in this repo has ever asserted a RUNNING pod's image. The only pod-image reads anywhere are
# `.spec…image` diagnostics. `mirror-verify` proves Harbor HAS the image; `check-image-alignment`
# aligns TAGS IN FILES. Neither can see what the cluster actually pulled.
#
# WHAT IT CATCHES, concretely. `46-install-istio.sh` points the mesh at Harbor with
# `--set global.hub=…`. Helm SILENTLY ACCEPTS AN UNKNOWN --set KEY (rc=0, empty stderr, zero effect —
# measured in this repo's own B26 notes), so a chart major that renames `global.hub` fails without a
# word, images fall back to docker.io, and on a DUAL-HOMED KinD box the nodes CAN reach docker.io —
# so `helm --wait` succeeds and `98-verify-ingress` returns 200 over a mesh that never touched Harbor.
# That is the same class the builder closes one component over — `14-builder-build.sh` pins its base
# image public by DIGEST from `images.lock`, so a broken mirror can't be papered over by a public pull.
# Delete `--set global.hub` and this gate reddens: it discriminates (it is not testing the vendor).
#
# 🔴 DO NOT "OPTIMISE" THIS INTO AN OFFLINE `helm template` GATE. The charts live in `bundle/charts/`,
# which is GITIGNORED (`.gitignore:7:/bundle/`; `git ls-files bundle/` = 0). In CI such a gate would
# scan an EMPTY directory and pass vacuously — the B26 refutation verbatim. The live check is the only
# non-vacuous form, which is why it is wired into e2e-kind and nowhere else.
#
# NO DISCOVERY, DELIBERATELY. `46-install-istio.sh:47-53` says it outright — "We own this mesh, so we
# PIN the gateway's identity rather than discovering it." Calling `istio_discover` here would add a jq
# dependency and a whole failure path for zero benefit, and `istio_discover || true` would be actively
# harmful: on failure the namespace list collapses to istio-system, istiod alone yields images, and an
# image-count denominator PASSES having never looked at a gateway. The denominator below is therefore
# PER-EXPECTED-WORKLOAD, not a total.
#
# ⚠️ ISTIO_GWAPI_NAMESPACE IS NOT DISCOVERABLE AND IS NOT EXPORTED. It is commented in .env.example
# (:520, the clobber rule), it is NOT in istio_discover's export list (lib/istio.sh:107-108), and it is
# set only inside istio_apply_routes_gwapi() (lib/istio.sh:270) — a different process. Discovery could
# never find it anyway: the auto-provisioned Service's selector is
# `gateway.networking.k8s.io/gateway-name: <name>` with NO `istio:` key, and istio_discover filters on
# exactly that key. So the default is mirrored from lib/istio.sh:270 by hand, on purpose.
#
# 🔴 HOW TO RED-PROVE THE MODE GUARD — the obvious way DOES NOT WORK. `INGRESS_CONTROLLER` is
# published via `state_set` and is NOT in load_env's SELECTORS snapshot (lib/os.sh:322), so .env.state
# WINS over the environment: `INGRESS_CONTROLLER=traefik make verify-gateway-image` does NOT exercise
# the SKIP branch. (Correct for a verifier — it must check what was INSTALLED, not what the caller
# claims — and it is the identical trap that silently passed B50's controller-guard proof.) The
# working proof rewrites the PUBLISHED value:
#     sed -i 's/^INGRESS_CONTROLLER=.*/INGRESS_CONTROLLER=traefik/' "$(bash -c '. scripts/lib/os.sh; state_file')"
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

load_env
# The fixture path needs neither a cluster nor a kubeconfig.
[ -n "${GATEWAY_IMAGE_FIXTURE:-}" ] || kubeconfig_ready

CONTROLLER="${INGRESS_CONTROLLER:-istio}"
case "$CONTROLLER" in
  istio) ;;
  istio-existing)
    log_warn "SKIP: INGRESS_CONTROLLER=istio-existing — the mesh is the PLATFORM's, so its image hub is"
    log_warn "  theirs, not our Harbor; asserting our registry would RED a correctly-configured foreign"
    log_warn "  mesh. Also redundant: verify-ingress routes THROUGH the auto-provisioned proxy, so an"
    log_warn "  ImagePullBackOff already reddens it. NOTHING was verified about provenance in this mode."
    exit 0 ;;
  traefik)
    log_warn "SKIP: INGRESS_CONTROLLER=traefik — no Istio proxy exists. NOTHING was verified here."
    exit 0 ;;
  *) die "unknown INGRESS_CONTROLLER='${CONTROLLER}' (expected istio, istio-existing or traefik)" ;;
esac

: "${HARBOR_URL:?HARBOR_URL is unset — cannot say what 'our registry' means. This gate belongs in e2e-kind AFTER install-harbor has published it; it must NOT be wired into an offline composite gate (HARBOR_URL is commented in .env.example).}"

CP_NS="${ISTIO_NAMESPACE:-istio-system}"                  # istiod
GW_NS="${ISTIO_GATEWAY_NAMESPACE:-istio-ingress}"         # the helm gateway (classic route API)
GWAPI_NS="${ISTIO_GWAPI_NAMESPACE:-vks-ingress}"          # the AUTO-PROVISIONED proxy (Gateway API)

# EVERY image in these namespaces — no name filter. An enumerated `*istio*|*proxyv2*` list fails
# SILENTLY (an unmatched image is skipped, not flagged), and nothing else runs in these namespaces,
# so filtering buys nothing and adds a rot surface.
# init/ephemeral are read too: `kube-gateway.yaml` has no initContainers today and autoInject is
# disabled, but the chart exposes an annotation-driven image override, so the surface is not closed
# by construction.
# jq, not jsonpath: a nested `{range .status.containerStatuses[*]}` cannot carry the POD NAME out of
# the outer range, so the naive jsonpath silently mislabels every row. Verified offline against
# synthetic pod JSON (including a pod with an empty .status, which must yield nothing and not error).
# shellcheck disable=SC2016  # `$p` and `\(…)` are JQ syntax and MUST NOT be shell-expanded here.
JQ_IMAGES='.items[] | .metadata.name as $p
  | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []) + (.status.ephemeralContainerStatuses // []))[]
  | "\($p)\t\(.image)\t\(.imageID // "")"'

# SELF-TEST HOOK: GATEWAY_IMAGE_FIXTURE=<dir> makes each namespace read <dir>/<ns>.json instead of
# the cluster, so the classifier is RED/GREEN-provable OFFLINE — without it, this gate could only ever
# be proven by a ~30-minute e2e, which is how gates end up shipped unproven.
images_in() { # <ns> -> "<pod>\t<image>\t<imageID>" per container
  if [ -n "${GATEWAY_IMAGE_FIXTURE:-}" ]; then
    [ -f "${GATEWAY_IMAGE_FIXTURE}/$1.json" ] || return 0
    jq -r "$JQ_IMAGES" "${GATEWAY_IMAGE_FIXTURE}/$1.json" 2>/dev/null || true
    return 0
  fi
  kubectl -n "$1" get pods -o json 2>/dev/null | jq -r "$JQ_IMAGES" 2>/dev/null || true
}

checked=0; bad=0; cp_seen=0; dp_seen=0
for ns in "$CP_NS" "$GW_NS" "$GWAPI_NS"; do
  if [ -z "${GATEWAY_IMAGE_FIXTURE:-}" ]; then
    kubectl get ns "$ns" >/dev/null 2>&1 || { log_info "  (namespace ${ns} absent — skipping)"; continue; }
  fi
  while IFS=$'\t' read -r pod img imgid; do
    [ -n "${img:-}" ] || continue
    checked=$((checked + 1))
    # if/else, not `A && B || C`: the repo bans that shape even where an assignment makes it safe.
    if [ "$ns" = "$CP_NS" ]; then cp_seen=$((cp_seen + 1)); else dp_seen=$((dp_seen + 1)); fi
    case "$img" in
      "${HARBOR_URL}"/*) printf 'ok    %s/%s <- %s\n' "$ns" "$pod" "$img" ;;
      *)
        # imageID too: containerStatuses[].image is what the CRI REPORTS and runtimes normalise
        # (a docker.io/ prefix, a digest form), so a prefix test is only as good as that round-trip.
        case "${imgid:-}" in
          *"${HARBOR_URL}"/*) printf 'ok    %s/%s <- %s (matched via imageID)\n' "$ns" "$pod" "$img" ;;
          *) printf 'FAIL  %s/%s pulled %s\n        imageID: %s\n        NOT from %s — on a dual-homed box this mesh reached the PUBLIC registry, so the air gap is UNPROVEN.\n' \
               "$ns" "$pod" "$img" "${imgid:-<none>}" "$HARBOR_URL"; bad=$((bad + 1)) ;;
        esac ;;
    esac
  done <<< "$(images_in "$ns")"
done

# PER-WORKLOAD denominator. A raw image count cannot tell "I checked everything" from "I checked one
# thing": with discovery broken, istiod alone would satisfy `checked > 0` while no gateway was ever
# examined. Require BOTH halves and name the missing one.
[ "$cp_seen" -gt 0 ] || die "no running container found in the CONTROL-PLANE namespace '${CP_NS}' — with INGRESS_CONTROLLER=istio istiod should be up. This gate verified NOTHING about it."
[ "$dp_seen" -gt 0 ] || die "no running container found in EITHER data-plane namespace ('${GW_NS}', '${GWAPI_NS}') — the gateway proxy is the pod whose image appears in NO manifest in this tree, i.e. the one this gate exists for. Its absence is a BLIND gate, not a pass."

[ "$bad" -eq 0 ] || { log_error "gateway image provenance: FAILED — ${bad} of ${checked} container image(s) did not come from ${HARBOR_URL}"; exit 1; }
log_info "gateway image provenance: OK — all ${checked} running container image(s) came from ${HARBOR_URL} (control-plane ${cp_seen}, data-plane ${dp_seen})"
