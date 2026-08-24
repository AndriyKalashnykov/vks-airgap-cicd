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
# REQUESTED 300Mi while USING 2607Mi (92%), and 23 of 48 pods (every DaemonSet, 7 of 9 Tekton pods)
# request 0Mi. A green means "it will schedule", never "it will not OOM". It is memory-only (a CPU
# shortfall once cost 10 millicores), assumes no autoscaler (measured: none), and covers only the
# releases installed by the caller. It is a fail-fast diagnostic, NOT a security control: anything
# invoking helm directly bypasses it.
#
# The arithmetic lives in capacity-probe.py, a SEPARATE FILE. It was embedded here as
# `python3 -c '...'` and broke three times on nested quoting -- each break made this FAIL OPEN
# ("could not read the cluster - skipping", rc=0), caught only because the RED arm was run.


# capacity_mi <k8s-quantity> -> integer Mi on stdout. Dies on a shape our knobs do not document.
capacity_mi() {
  local q="$1" n unit
  case "$q" in
    *Mi) n="${q%Mi}"; unit=1 ;;
    *Gi) n="${q%Gi}"; unit=1024 ;;
    *M)  n="${q%M}";  unit=1 ;;   # 1M = 0.95Mi; treating it as Mi over-states by <5%
    *G)  n="${q%G}";  unit=1024 ;;
    # A BARE integer is a valid k8s quantity meaning BYTES, i.e. `768` reserves 768 bytes -- a
    # ~10^6x silent under-reservation and the most likely typo. Refused, not guessed at.
    # NOTE: this function is called from $( ), where `die` would kill only the SUBSHELL and leave
    # the caller with an empty string -- a FAIL-OPEN. It returns a STATUS; the caller must check it.
    *)   log_error "capacity: '${q}' is not a memory quantity this knob accepts (want e.g. 768Mi or 1Gi)."
         log_error "capacity: a BARE number is k8s BYTES — '768' would reserve 768 bytes, not 768Mi."
         return 1 ;;
  esac
  case "$n" in ''|*[!0-9]*) log_error "capacity: '${q}' has a non-numeric amount"; return 1 ;; esac
  printf '%s' "$(( n * unit ))"
}

# capacity_chart_request <chart> <version> [the install's EXACT --set args...] -> a k8s quantity.
# Renders the chart with the SAME args the install will use, so the number checked describes the
# Deployment that will actually be created -- a hardcoded default would be a second source of truth
# that drifts silently on the next chart bump. Per-Deployment SUM (the scheduler charges the pod),
# then the MAX across Deployments (they schedule independently). Empty on any failure: the caller
# must treat that as "unknown", never as zero.
capacity_chart_request() {
  local chart="$1" version="$2"; shift 2
  command -v helm >/dev/null 2>&1 || return 0
  command -v yq   >/dev/null 2>&1 || return 0
  helm template capreq "$chart" --version "$version" "$@" 2>/dev/null | yq -r '
    select(.kind == "Deployment")
    | [.spec.template.spec.containers[].resources.requests.memory // "0"]
    | join(" ")' 2>/dev/null | while read -r -a mems; do
      local tot=0 m
      local one
      for m in "${mems[@]:-}"; do
        [ -n "$m" ] && [ "$m" != 0 ] || continue
        one="$(capacity_mi "$m")" || return 0   # unknown, not zero
        tot=$(( tot + one ))
      done
      # yq emits a blank line on empty input, so a FAILED render reaches here with tot=0 and would
      # print "0Mi" -- which always "fits", i.e. a GREEN certifying nothing. Emit nothing instead.
      if [ "$tot" -gt 0 ]; then printf '%sMi\n' "$tot"; fi
    done | sort -n | tail -1
}

# capacity_assert_fits <k8s-quantity> <what>
capacity_assert_fits() {
  local what="$2" need_mi
  # The escape hatch must escape EVERYTHING, including the quantity validation below.
  [ "${CAPACITY_PREFLIGHT:-1}" = 0 ] && { log_warn "capacity: preflight disabled (CAPACITY_PREFLIGHT=0)"; return 0; }
  # An EMPTY quantity means capacity_chart_request could not render (no helm/yq, bad chart).
  # Unknown is not zero: skip loudly rather than certify a fit we did not compute.
  [ -n "$1" ] || { log_warn "capacity: request for ${what} is UNKNOWN — fit check SKIPPED (not a pass)"; return 0; }
  need_mi="$(capacity_mi "$1")" || die "capacity: ${what}'s memory request '$1' is not usable (see above)"
  command -v kubectl >/dev/null 2>&1 || { log_warn "capacity: no kubectl — fit check SKIPPED (not a pass)"; return 0; }
  # A bare Photon jump box has NO python3. Without this the `report=$(...)` below is rc=127 and,
  # under the caller's `set -euo pipefail`, kills the install with NO output — the repo's own
  # "non-zero exit with no output" signature, on a box that had nothing wrong with it.
  command -v python3 >/dev/null 2>&1 || { log_warn "capacity: no python3 — fit check SKIPPED (not a pass)"; return 0; }

  local probe report rc
  probe="$(dirname "${BASH_SOURCE[0]}")/capacity-probe.py"
  [ -f "$probe" ] || { log_warn "capacity: $probe missing — fit check SKIPPED (not a pass)"; return 0; }

  # `|| true`: the assignment IS the failing command under `set -e`, so without it a probe
  # failure kills the caller before the fail-open branch below can run. RED-proven.
  report="$(kubectl get nodes,pods -A -o json 2>/dev/null | python3 "$probe" "$need_mi" 2>/dev/null || true)"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$report" ]; then
    log_warn "capacity: could not read the cluster (rc=$rc) — fit check SKIPPED (not a pass)"
    return 0
  fi

  local head fits best usable excluded margin
  head="$(printf '%s' "$report" | head -1)"
  fits="${head%% *}"; head="${head#* }"
  best="${head%% *}"; head="${head#* }"
  usable="${head%% *}"; excluded="${head#* }"
  log_info "capacity: ${what} needs ${need_mi}Mi; roomiest schedulable node has ${best}Mi free (${usable} candidate node(s), ${excluded} excluded)"

  if [ "$fits" = 1 ]; then
    # A bare PASS certifies an edge silently. Print the MARGIN so a shrinking one is visible, and
    # WARN on a thin one -- the 08-21 config cleared by ~77Mi and nobody could have known.
    margin=$((best - need_mi))
    if [ "$margin" -lt "${CAPACITY_WARN_MARGIN_MI:-256}" ]; then
      log_warn "capacity: margin is only ${margin}Mi — the next app or replica bump breaks this."
      printf '%s\n' "$report" | tail -n +2 >&2
    else
      log_info "capacity: margin ${margin}Mi"
    fi
    return 0
  fi

  printf '%s\n' "$report" | tail -n +2 >&2
  die "${what} requests ${need_mi}Mi but NO schedulable node has that free — roomiest has ${best}Mi (short $((need_mi - best))Mi).
  helm would leave it Pending and time out after its full --wait with 'Available: 0/1', naming nothing.
  Fix: lower the request (ISTIOD_MEMORY_REQUEST in .env.example), free memory, or enlarge/add a worker.
  Override: CAPACITY_PREFLIGHT=0"
}
