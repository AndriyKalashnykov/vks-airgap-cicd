#!/usr/bin/env bash
# 97-verify-workload-images.sh — every RUNNING container in the namespaces WE build in must have
# been pulled from OUR registry.
#
# B563. `grep -rl containerStatuses` found the only running-image assertions in this repo were
# 96-verify-gateway-image.sh (Istio ONLY) and three diagnostics. `99-verify.sh:363` compares running
# pods against `$img` -- but `$img` is read from the DEPLOYMENT SPEC, not from HARBOR_URL, so it is a
# rollout-completion check that would pass on a spec pointing at docker.io. `mirror-verify` proves
# Harbor HAS the image; `check-image-alignment` aligns TAGS IN FILES. None of them can see what the
# cluster actually pulled.
#
# ⚠️ SCOPE: the namespaces running MIRRORED THIRD-PARTY images. The APP namespaces are deliberately
# EXCLUDED because an assertion there is VACUOUS -- those pods run images our own pipeline built and
# pushed to Harbor, so their refs are Harbor by construction and the gate could not fail for the
# right reason (verified: every deploy/*/deployment.yaml is a single container with
# `sidecar.istio.io/inject: "false"`, enforced by check-pod-inject-label.sh, so no mesh sidecar or
# init container lands there either).
#
# ⚠️ AN EARLIER DRAFT COVERED ONLY ci + tekton, AND ITS ROUND REFUTED THAT: it used the app-namespace
# vacuity argument to exclude gitea, headlamp and traefik, which are NOT pipeline-built -- they are
# mirrored third-party images, the SAME class as tekton. headlamp is a second, already-documented
# instance of the exact shape this gate exists for: 49-install-headlamp.sh's own header records that
# the chart's podDebugImage/nodeShellImage default to "" and the frontend falls back to a hardcoded
# `docker.io/library/busybox:latest`, and the override is a `--set` key -- which helm accepts with
# rc=0 when unknown. gitea is the same: `image: ${GITEA_IMAGE}`, and e2e-cross-cluster.sh sets that
# to a RAW PUBLIC ref. Closing over 3 of those namespaces while printing "every running container in
# the namespaces we own" is a denominator overclaim, and that kind of green is what let the headlamp
# busybox be diagnosed twice.
#
# The three Istio namespaces are covered by 96-verify-gateway-image.sh and are NOT repeated here.
#
# B567 is the motivating incident: Tekton's controller injects a `place-scripts` init container from
# a hardcoded `-shell-image` FLAG STRING, so `cgr.dev/chainguard/busybox` was pulled from the public
# internet on every TaskRun, inside the air gap, for the life of the repo.
#
# ⚠️ WHAT IT CANNOT SEE, named rather than implied: kaniko's `.image` is the DESTINATION it pushes,
# not the base it pulled FROM. A public `FROM` in a Dockerfile is therefore INVISIBLE to any run-time
# pod-image check, including this one. That half is covered at build time by `check-selfbuilt` and by
# the manifest host scan (lib/hostscan.sh, B568). This gate closes the run-time half only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/podimages.sh
. "${SCRIPT_DIR}/lib/podimages.sh"
load_env

_verdict() { printf 'workload-image-verdict: %s\n' "$1"; }

REG="${HARBOR_URL:-}"
if [ -z "$REG" ]; then
  _verdict "SKIPPED:no-registry"
  log_warn "97-verify-workload-images: HARBOR_URL is unset, so there is no registry to compare against."
  log_warn "  NOTHING was verified here. This is a SKIP, not a pass."
  exit 0
fi

# ns|ownership. Mirrors 49-psa-check.sh's NS_SPEC shape ON PURPOSE, including the `die` on an
# unrecognised ownership: a namespace must not become un-gated by a typo.
#   ours       we deploy into it and every image should be ours   -> ASSERT
#   not-ours   a component we neither build nor mirror            -> REPORT, never judge
# Adding a row is how you extend this; changing the predicate is not.
NS_SPEC="
${CI_NAMESPACE:-ci}|ours
${TEKTON_NAMESPACE:-tekton-pipelines}|ours
tekton-pipelines-resolvers|ours
${GITEA_NAMESPACE:-gitea}|ours
${HEADLAMP_NAMESPACE:-headlamp}|ours
${TRAEFIK_NAMESPACE:-traefik}|ours
"

checked=0; bad=0; foreign_ns=0
declare -A SEEN=()

while IFS='|' read -r ns own; do
  [ -n "${ns:-}" ] || continue
  case "${own:-}" in
    ours|not-ours) ;;
    *) die "97-verify-workload-images: NS_SPEC row '${ns}' has ownership '${own:-<empty>}' — expected ours|not-ours. A namespace must not be un-gated by a typo." ;;
  esac
  # ABSENT vs PRESENT-BUT-EMPTY is the distinction the vacuity guard below rests on, so the fixture
  # path must model it the same way the live path does: a MISSING fixture file means the namespace
  # does not exist (skip), and a file containing `{"items":[]}` means it exists with no pods (which
  # is INCOMPLETE, not a pass). Conflating them made every namespace without a fixture look empty.
  if [ -n "${PODIMAGES_FIXTURE:-}" ]; then
    [ -f "${PODIMAGES_FIXTURE}/${ns}.json" ] || { log_info "  (namespace ${ns} absent — skipping)"; continue; }
  else
    kubectl get ns "$ns" >/dev/null 2>&1 || { log_info "  (namespace ${ns} absent — skipping)"; continue; }
  fi
  while IFS=$'\t' read -r pod img imgid; do
    [ -n "${img:-}" ] || continue
    checked=$((checked + 1))
    SEEN["$ns"]=1
    if [ "$own" = not-ours ]; then
      printf 'note  %s/%s <- %s (not ours — reporting, not judging)\n' "$ns" "$pod" "$img"
      foreign_ns=$((foreign_ns + 1)); continue
    fi
    if podimages_is_ours "$img" "$imgid" "$REG"; then
      printf 'ok    %s/%s <- %s\n' "$ns" "$pod" "$img"
    else
      printf 'FAIL  %s/%s pulled %s\n        imageID: %s\n        NOT from %s — this container reached a registry we do not mirror, so the air gap is UNPROVEN.\n' \
        "$ns" "$pod" "$img" "${imgid:-<none>}" "$REG"
      bad=$((bad + 1))
    fi
  done <<< "$(podimages_in "$ns")"
done <<< "$NS_SPEC"

# THE DENOMINATOR, per namespace and not a total. A raw count cannot tell "I checked everything" from
# "I checked one thing": with the Tekton namespaces empty, `ci` alone would satisfy `checked > 0`
# while the controller that injects the build-side init container was never examined. Name the
# missing one rather than passing on a subset.
missing=""
while IFS='|' read -r ns own; do
  [ -n "${ns:-}" ] || continue
  [ "${own:-}" = ours ] || continue
  # only a namespace that EXISTS can be "empty" -- an absent one was skipped above and is not a gap.
  if [ -n "${PODIMAGES_FIXTURE:-}" ]; then
    [ -f "${PODIMAGES_FIXTURE}/${ns}.json" ] || continue
  else
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
  fi
  if [ -z "${SEEN[$ns]:-}" ]; then missing="${missing} ${ns}"; fi
done <<< "$NS_SPEC"

if [ "$checked" -eq 0 ]; then
  _verdict "SKIPPED:no-pods"
  log_warn "97-verify-workload-images: not one running container was found in any namespace we own."
  log_warn "  NOTHING was verified. Run this AFTER \`make verify\`, when the pipeline has actually run —"
  log_warn "  before that the pods do not exist and this gate passes VACUOUSLY."
  exit 0
fi

printf '\nworkload image provenance: %s container(s) checked across the namespaces we own, %s not-ours (reported), %s foreign\n' \
  "$checked" "$foreign_ns" "$bad"

if [ -n "$missing" ]; then
  _verdict "INCOMPLETE:${missing# }"
  die "no running container was found in:${missing} — these are namespaces we OWN, so their absence is a BLIND gate, not a pass. Run this after \`make verify\`."
fi

if [ "$bad" -gt 0 ]; then
  _verdict "FAILED"
  die "workload image provenance: FAILED — ${bad} container(s) did not come from ${REG}"
fi
_verdict "ASSERTED"
log_info "workload image provenance: OK — every running container in the namespaces we own came from ${REG}"
