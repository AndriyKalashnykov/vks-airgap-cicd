#!/usr/bin/env bash
# podimages.sh — read the images a cluster ACTUALLY PULLED, and decide whether they came from us.
#
# ⚠️ THIS EXISTS TO BE SINGLE-SOURCED, and the reason is this repo's own worst incident. B567 was a
# PUBLIC image pulled on every build inside the air gap, and its root cause was TWO DRIFTED COPIES of
# a registry-host list. Anything that answers "did this come from our registry?" therefore lives in
# ONE place. 96-verify-gateway-image.sh (Istio) and 97-verify-workload-images.sh (our build-side
# workloads) both consume this; neither re-derives it.
#
# shellcheck shell=bash
[ -n "${__VKS_PODIMAGES_SH_LOADED:-}" ] && return 0
__VKS_PODIMAGES_SH_LOADED=1

# jq, not jsonpath: a nested `{range .status.containerStatuses[*]}` cannot carry the POD NAME out of
# the outer range, so the naive jsonpath silently mislabels every row. Init and ephemeral containers
# are included -- an init container is exactly where a build-side image hides (Tekton's own
# `place-scripts` init container is what pulled a public busybox on every TaskRun in B567).
# shellcheck disable=SC2016  # `$p` and `\(…)` are JQ syntax and MUST NOT be shell-expanded here.
PODIMAGES_JQ='.items[] | .metadata.name as $p
  | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []) + (.status.ephemeralContainerStatuses // []))[]
  | "\($p)\t\(.image)\t\(.imageID // "")"'

# podimages_in <ns> -> "<pod>\t<image>\t<imageID>" per container, one line each.
#
# SELF-TEST HOOK: PODIMAGES_FIXTURE=<dir> reads <dir>/<ns>.json instead of the cluster, so every
# consumer is RED/GREEN-provable OFFLINE. Without it these gates could only ever be proven by a
# ~30-minute e2e, which is how gates end up shipped unproven.
podimages_in() { # <ns>
  local ns="${1:?podimages_in: namespace required}"
  if [ -n "${PODIMAGES_FIXTURE:-}" ]; then
    [ -f "${PODIMAGES_FIXTURE}/${ns}.json" ] || return 0
    jq -r "$PODIMAGES_JQ" "${PODIMAGES_FIXTURE}/${ns}.json" 2>/dev/null || true
    return 0
  fi
  kubectl -n "$ns" get pods -o json 2>/dev/null | jq -r "$PODIMAGES_JQ" 2>/dev/null || true
}

# podimages_is_ours <image> <imageID> <registry> -> rc 0 if it came from <registry>.
#
# ⚠️ TWO-TIER, AND THE SECOND TIER IS NOT OPTIONAL. `containerStatuses[].image` is what the CRI
# REPORTS, and runtimes NORMALISE it: containerd resolves a digest-pinned ref and reports a bare
# `sha256:…` with no registry host at all, so a `.image`-only prefix test FALSE-REDs the great
# majority of legitimately-mirrored containers. `.imageID` carries the resolved reference and is the
# rescue arm. A gate that checks only `.image` is not stricter -- it is broken.
podimages_is_ours() { # <image> <imageID> <registry>
  local img="${1:-}" imgid="${2:-}" reg="${3:?podimages_is_ours: registry required}"
  case "$img"   in "${reg}"/*)  return 0 ;; esac
  case "$imgid" in *"${reg}"/*) return 0 ;; esac
  return 1
}
