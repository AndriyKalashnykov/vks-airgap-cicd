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
# ⚠️ THE SCOPE IS THE BUILD-SIDE NAMESPACES, AND THAT IS DELIBERATE. Its idea round measured that an
# assertion over the APP namespaces is VACUOUS: those pods run images our own pipeline built and
# pushed to Harbor, so their refs are Harbor by construction and the assertion could not fail for the
# right reason. The pods that can silently carry a public image are the BUILD-side ones -- and B567
# is the proof: Tekton's controller injects a `place-scripts` init container from a hardcoded
# `-shell-image` FLAG STRING, so `cgr.dev/chainguard/busybox` was pulled from the public internet on
# every TaskRun, inside the air gap, for the life of the repo.
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
"

checked=0; bad=0; foreign_ns=0
declare -A SEEN=()

while IFS='|' read -r ns own; do
  [ -n "${ns:-}" ] || continue
  case "${own:-}" in
    ours|not-ours) ;;
    *) die "97-verify-workload-images: NS_SPEC row '${ns}' has ownership '${own:-<empty>}' — expected ours|not-ours. A namespace must not be un-gated by a typo." ;;
  esac
  if [ -z "${PODIMAGES_FIXTURE:-}" ]; then
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
