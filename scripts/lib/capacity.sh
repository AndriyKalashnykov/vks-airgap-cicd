#!/usr/bin/env bash
# capacity.sh — refuse a helm install whose pod CANNOT BE SCHEDULED, before `helm --wait` burns its
# timeout discovering the same thing with a message that names nothing.
#
# WHY. MEASURED 2026-08-24 on guest cluster cicd-gc0824060158: istiod requests 2048Mi (the Istio
# chart default), no worker had that free, the pod sat Pending, and helm waited its full 300s to say
#     Error: resource Deployment/istio-system/istiod not ready. status: InProgress, Available: 0/1
# which names nothing. The scheduler knew instantly: "0/3 nodes are available: 2 Insufficient
# memory". This turns that into a ~2s refusal that names the shortfall.
#
# SCOPE — read this before trusting a green. It models the SCHEDULER, which charges REQUESTS ONLY.
# It is therefore silent about real memory pressure: MEASURED on the same cluster, the control plane
# REQUESTED 300Mi while USING 2607Mi (92%). A green means "it will schedule", never "it will not
# OOM". It is MEMORY-ONLY, and CPU is nearly as tight — MEASURED on the same nodes (allocatable
# 1930m): the roomiest candidate has 2.14x headroom for CPU against 2.28x for memory, so they bind
# at essentially the same growth step. The runtime line therefore says "memory margin", not
# "margin". It also checks ONE replica: the gateway chart renders an HPA with maxReplicas 5, so a
# scaled-out gateway can need 5x what this verified (the earlier claim here that this cluster has
# "no autoscaler" was FALSE — two HPAs are live, one of them from the chart this guards).
# It covers only the releases installed by the caller, and it is a fail-fast diagnostic, NOT a
# security control: anything invoking helm directly bypasses it.
#
# WHAT IT MUST NEVER DO IS BLOCK. Two adversary rounds converged on the same defect in the first
# version: with ZERO candidate nodes the probe printed "0 0 0 0" — rc 0, non-empty output — which
# walked past every fail-open guard and hard-died with "roomiest has 0Mi", advising the operator to
# free memory that was not the problem. Reachable two ways, both MEASURED: a kubeconfig that cannot
# list nodes (kubectl emits a valid empty List on stdout WITH rc=1 — the tenant shape, and this
# repo's DEFAULT posture), and — with no RBAC assumption at all — a cluster whose only node carries
# a NoSchedule taint, even with 8000Mi free. KinD cannot exercise either (its control plane is
# untainted), so it would have first appeared on the real lab. Hence: ONLY `usable > 0` may die.
#
# HELM IS NOT THE ONLY INSTALL METHOD, AND WILL NOT BE THE DEFAULT ONE. Istio is a VKS Standard
# Package (`istio.kubernetes.vmware.com`); B466 tracks a switch to installing it that way. So the
# two halves here are deliberately separate:
#   capacity_assert_fits  — METHOD-AGNOSTIC. Takes a QUANTITY and asks the cluster whether it fits.
#                           Works unchanged for helm, for the addon, or for a raw manifest.
#   capacity_chart_request — the HELM ADAPTER. It exists only to answer "what will helm request?"
#                           and it is the ONLY helm-coupled function in this file.
# The addon path needs its own sibling adapter, NOT a change to assert_fits: the request lives in
# the Package's values (`istio.pilot.resources.requests.memory`, which VMware leaves NULL so it
# inherits the upstream 2048Mi -- measured, see docs/vks-services/istio.md). That adapter would
# read the PKG_VALUES file with the package's schema default as the fallback.
# For the same reason assert_fits does NOT hardcode the remedy: the caller passes it, because the
# knob differs by method (ISTIOD_MEMORY_REQUEST for helm, a PKG_VALUES key for the addon).
#
# The arithmetic lives in capacity-probe.py, a SEPARATE FILE. It was embedded here as
# `python3 -c '...'` and broke three times on nested quoting -- each break made this FAIL OPEN
# ("could not read the cluster - skipping", rc=0), caught only because the RED arm was run.

# capacity_mi <k8s-quantity> -> integer Mi on stdout, rounded UP so the check stays conservative.
# Returns a STATUS on a shape it cannot parse: it is called from $( ), where `die` would kill only
# the SUBSHELL and leave the caller with an empty string -- a FAIL-OPEN.
capacity_mi() {
  local q="$1" out
  # Delegated to the probe so ONE parser serves both sides. The shell version refused `1.5Gi` and
  # `512Ki` -- both legal k8s quantities and legal `--set` values -- which made the render return
  # empty and the whole check SKIP while proceeding to helm. MEASURED: 2560Mi blocked correctly,
  # the same size written 2.5Gi sailed through.
  local rc=0
  out="$(printf '%s' "$q" | python3 "$(dirname "${BASH_SOURCE[0]:-$0}")/capacity-probe.py" --to-mi 2>/dev/null)" || rc=$?
  # rc 1 is the parser's verdict on the QUANTITY. Anything else (127 no interpreter, 2 no probe
  # file, a crash) means the PARSER is unusable, which says nothing about the quantity -- a
  # present-but-broken python3 is presence-without-capability, and `command -v` only tests presence.
  # Return 2 so the caller can SKIP instead of dying on a value that may be perfectly fine.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    log_warn "capacity: the quantity parser is unusable (rc=$rc) — cannot evaluate '${q}'"
    return 2
  fi
  [ "$rc" -eq 0 ] || {
    log_error "capacity: '${q}' is not a memory quantity that parses (want e.g. 768Mi, 1Gi, 2.5Gi)."
    # Only say this when it IS a bare number. Saying it for `512Ki` names a cause the operator did
    # not have, and quotes a value they never typed -- an error that misdirects is worse than none.
    case "$q" in ''|*[!0-9]*) ;; *) log_error "capacity: a BARE number is k8s BYTES — '${q}' reserves ${q} bytes, not ${q}Mi." ;; esac
    return 1
  }
  printf '%s' "$out"
}

# capacity_chart_request <chart> <version> [the install's EXACT --set args...] -> a k8s quantity.
# Renders the chart with the SAME args the install will use, so the number checked describes the
# Deployment that will actually be created -- a hardcoded default would be a second source of truth
# that drifts silently on the next chart bump. Per-Deployment SUM (the scheduler charges the pod),
# then the MAX across Deployments (they schedule independently).
#
# CONTRACT: prints a quantity, or NOTHING. It must never print a PARTIAL maximum -- an earlier
# Deployment's total with a later one dropped is a FALSE GREEN produced by the check itself
# (MEASURED: a 100Mi / bogus / 5000Mi render returned "100Mi", which passes comfortably while helm
# creates the 5000Mi pod). The loop therefore reads from a PROCESS SUBSTITUTION, not a pipeline, so
# `return` leaves the FUNCTION rather than one subshell stage.
# It also ends with an explicit `return 0`: the fail-open must not depend on the accident of being
# called inside a command substitution. MEASURED: as a bare call or a plain assignment under
# `set -e`, a helm failure killed the caller with no output.
capacity_chart_request() {
  local chart="$1" version="$2"; shift 2
  command -v helm >/dev/null 2>&1 || return 0
  command -v yq   >/dev/null 2>&1 || return 0
  local best=0 tot one m rendered
  rendered="$(helm template capreq "$chart" --version "$version" "$@" 2>/dev/null | yq -r '
    select(.kind == "Deployment")
    | [.spec.template.spec.containers[].resources.requests.memory // "0"]
    | join(" ")' 2>/dev/null || true)"
  while read -r -a mems; do
    tot=0
    for m in "${mems[@]:-}"; do
      [ -n "$m" ] && [ "$m" != 0 ] || continue
      one="$(capacity_mi "$m")" || return 0   # UNKNOWN, not a partial maximum
      tot=$(( tot + one ))
    done
    [ "$tot" -gt "$best" ] && best="$tot"
  done <<< "$rendered"
  # yq emits a blank line per non-Deployment document, so a FAILED render reaches here with best=0
  # and would print "0Mi" -- which always "fits", i.e. a GREEN certifying nothing. Print nothing.
  [ "$best" -gt 0 ] && printf '%sMi\n' "$best"
  return 0
}

# capacity_assert_fits <k8s-quantity> <what> [how-to-lower-it]
# METHOD-AGNOSTIC: it never mentions helm. The third argument is the remedy line, supplied by the
# caller because the knob depends on the install method (see the header).
capacity_assert_fits() {
  local what="$2" lower="${3:-lower the request}" need_mi
  # The escape hatch must escape EVERYTHING, including the quantity validation below.
  [ "${CAPACITY_PREFLIGHT:-1}" = 0 ] && { log_warn "capacity: preflight disabled (CAPACITY_PREFLIGHT=0)"; return 0; }
  # An EMPTY quantity means capacity_chart_request could not render (no helm/yq, bad chart).
  # Unknown is not zero: skip loudly rather than certify a fit we did not compute.
  [ -n "$1" ] || { log_warn "capacity: request for ${what} is UNKNOWN — fit check SKIPPED (not a pass)"; return 0; }
  local mrc=0
  need_mi="$(capacity_mi "$1")" || mrc=$?
  [ "$mrc" -eq 2 ] && { log_warn "capacity: fit check SKIPPED (not a pass) — the parser is unusable"; return 0; }
  [ "$mrc" -eq 0 ] || die "capacity: ${what}'s memory request '$1' is not usable (see above)"

  command -v kubectl >/dev/null 2>&1 || { log_warn "capacity: no kubectl — fit check SKIPPED (not a pass)"; return 0; }
  # A bare Photon jump box has NO python3 (MEASURED on the real photon:5.0 image). Without this the
  # `report=$(...)` below is rc=127 and, under the caller's `set -euo pipefail`, kills the install
  # with NO output — the repo's own "non-zero exit with no output" signature, on a healthy box.
  command -v python3 >/dev/null 2>&1 || { log_warn "capacity: no python3 — fit check SKIPPED (not a pass)"; return 0; }

  local probe report
  probe="$(dirname "${BASH_SOURCE[0]:-$0}")/capacity-probe.py"
  [ -f "$probe" ] || { log_warn "capacity: $probe missing — fit check SKIPPED (not a pass)"; return 0; }

  # `|| true` so a probe failure cannot trip the caller's `set -e`. NOTE the previous version also
  # read `rc=$?` here: because the `|| true` is INSIDE the substitution the status is always `true`'s,
  # so that guard was dead code and its warning printed a meaningless "(rc=0)". Emptiness is the
  # real signal, and it is tested below.
  report="$(kubectl get nodes,pods -A -o json 2>/dev/null | python3 "$probe" "$need_mi" 2>/dev/null || true)"
  [ -n "$report" ] || { log_warn "capacity: could not read the cluster — fit check SKIPPED (not a pass)"; return 0; }

  # No pipeline: `printf | head -1` is an early-exit consumer in an assignment under set -e +
  # pipefail, so it can SIGPIPE-kill the caller. MEASURED: 0/200 at this repo's cluster sizes but
  # 200/200 at 2000 nodes, and the producer here is the only one in the repo that scales with node
  # count. Parameter expansion cannot SIGPIPE.
  local head fits best usable excluded margin
  head="${report%%$'\n'*}"
  fits="${head%% *}"; head="${head#* }"
  best="${head%% *}"; head="${head#* }"
  usable="${head%% *}"; excluded="${head#* }"
  # SAY WHICH CLUSTER. This reads $KUBECONFIG, which no target takes as an argument, so a verdict
  # that does not name its subject is confidently about a cluster the operator may not have meant.
  log_info "capacity: measured $(kube_target_id)"
  log_info "capacity: ${what} needs ${need_mi}Mi; roomiest schedulable node has ${best}Mi free (${usable} candidate node(s), ${excluded} excluded)"

  # ZERO CANDIDATES IS NOT "THE CLUSTER IS FULL" — see the header. Nodes unlistable (a tenant
  # kubeconfig) and nodes all-excluded (a tainted single-node cluster) both land here, and neither
  # is a capacity problem. Skip, and say which it looks like.
  if [ "${usable:-0}" -eq 0 ]; then
    log_warn "capacity: NO candidate nodes are visible — fit check SKIPPED (not a pass)."
    if [ "${excluded:-0}" -eq 0 ]; then
      log_warn "  zero nodes were readable at all: this kubeconfig probably cannot list nodes (RBAC),"
      log_warn "  which is normal for a tenant. It is NOT a memory problem."
    else
      log_warn "  ${excluded} node(s) were readable but ALL excluded (taints / cordoned / NotReady):"
      printf '%s\n' "$report" | tail -n +2 >&2
    fi
    return 0
  fi

  if [ "$fits" = 1 ]; then
    # A bare PASS certifies an edge silently. Print the MARGIN so a shrinking one is visible, and
    # WARN on a thin one -- the 2026-08-21 config cleared by ~77Mi and nobody could have known.
    margin=$((best - need_mi))
    if [ "$margin" -lt "${CAPACITY_WARN_MARGIN_MI:-256}" ]; then
      log_warn "capacity: memory margin is only ${margin}Mi — the next app or replica bump breaks this."
      printf '%s\n' "$report" | tail -n +2 >&2
    else
      log_info "capacity: memory margin ${margin}Mi"
    fi
    return 0
  fi

  printf '%s\n' "$report" | tail -n +2 >&2
  die "${what} requests ${need_mi}Mi but NO schedulable node has that free — roomiest has ${best}Mi (short $((need_mi - best))Mi).
  helm would leave it Pending and time out after its full --wait with 'Available: 0/1', naming nothing.
  Fix: ${lower}, free memory, or enlarge/add a worker.
  Override: CAPACITY_PREFLIGHT=0"
}
