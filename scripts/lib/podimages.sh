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

# registry_hostport() lives in os.sh. Source it here rather than relying on every caller to have
# done so first -- lib/argocd.sh sets the precedent, and a lib that silently needs a sibling already
# loaded is a lib that fails in whichever caller forgets.
# shellcheck source=scripts/lib/os.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os.sh"

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
# ⚠️ IT COMPARES HOSTS VIA registry_hostport(), NOT SUBSTRINGS, and an implementation round MEASURED
# why. A substring test on imageID FALSE-PASSES any registry whose ref merely CONTAINS ours:
#     oldharbor.env1.lab.test/infra/gitea   vs HARBOR_URL=harbor.env1.lab.test  -> reported ok
#     evil.example.com/h.local/x            vs HARBOR_URL=h.local               -> reported ok
# A sibling/stale/lookalike registry in the same domain is exactly what an enterprise lab has, and
# the gate would close with "OK — every running container came from harbor.env1.lab.test".
#
# A raw-string compare ALSO false-REDs in the other direction, on spellings lib/harbor.sh:24-26 and
# registry_hostport's own header document as real .env inputs -- MEASURED, all containers
# legitimately ours: `https://h.local`, `h.local/` and `h.local:443` each reported 3/3 FOREIGN and
# died accusing the operator of an air-gap breach. One parser closes both directions.
#
# registry_hostport() is "THE ONE HOST PARSER" (lib/os.sh), itself promoted from lib/tls.sh after a
# measured incident, with a header saying two implementations of one predicate is the hazard it
# exists to avoid. This is its third caller, not a third copy.
# On success it sets PODIMAGES_MATCHED_VIA to `image` or `imageID`. That is not decoration: 96's
# operator line says "(matched via imageID)", and a committed case asserts it -- knowing WHICH tier
# matched is what tells a reader the CRI normalised the ref rather than the registry being named
# outright. A plain global is safe because no caller invokes this inside a command substitution.
podimages_is_ours() { # <image> <imageID> <registry>
  local img="${1:-}" imgid="${2:-}" reg="${3:?podimages_is_ours: registry required}" ours
  ours="$(registry_hostport "$reg")"
  export PODIMAGES_MATCHED_VIA=""
  if _podimages_host_matches "$img" "$ours";   then export PODIMAGES_MATCHED_VIA=image;   return 0; fi
  if _podimages_host_matches "$imgid" "$ours"; then export PODIMAGES_MATCHED_VIA=imageID; return 0; fi
  return 1
}

# A ref's host is everything before the first `/`, and ONLY if it looks like one. `busybox:1` and a
# CRI-normalised bare `sha256:cafe` carry no host (the first is an implied docker.io, the second is
# a digest) -- neither is ours, and neither must be mistaken for a host named `busybox` or `sha256`.
_podimages_host_matches() { # <ref> <ours-hostport>
  local ref="${1:-}" ours="${2:-}" first
  [ -n "$ref" ] || return 1
  first="${ref%%/*}"
  [ "$first" != "$ref" ] || return 1            # no `/` at all -> no host
  case "$first" in
    *.*|*:*|localhost) ;;                        # a host has a dot, a port, or is localhost
    *) return 1 ;;
  esac
  [ "$(registry_hostport "$first")" = "$ours" ]
}
