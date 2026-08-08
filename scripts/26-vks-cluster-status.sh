#!/usr/bin/env bash
# scripts/26-vks-cluster-status.sh — is the guest cluster ACTUALLY ready? (scenario-1 §4b)
#
# ⚠️ `.status.phase == Provisioned` IS NOT READINESS. The runbook records a real cluster sitting at
# Provisioned with ZERO available nodes, and CAPI mints the kubeconfig Secret before nodes join — so
# you can hold a working-looking kubeconfig for a cluster that cannot schedule anything.
#
# ⚠️ AND A BARE `condition == True` IS NOT READINESS EITHER. Measured on this lab: every condition
# carries observedGeneration, and during a topology change metadata.generation advances FIRST — so a
# True from generation N-1 is readable while generation N is mid-reconcile. Each gating condition is
# therefore accepted only when its observedGeneration matches metadata.generation.
#
# Read-only. Always exits 0 when the cluster is ready; non-zero only when asked to WAIT and it times
# out — so it is safe to run at any time.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

load_env
require_cmd kubectl

: "${VKS_CLUSTER_NAME:?set VKS_CLUSTER_NAME in .env}"
: "${VKS_NAMESPACE:?set VKS_NAMESPACE in .env}"
# ⚠️ VKS_SUPERVISOR_KUBECONFIG FIRST — that is the name the WRITER (30-vks-login.sh)
# honours. These readers used only SUPERVISOR_KUBECONFIG; the defaults coincide, so the
# split was invisible on the box that measured it and would have split the moment an
# operator set either one.
SUP="${VKS_SUPERVISOR_KUBECONFIG:-${SUPERVISOR_KUBECONFIG:-${REPO_ROOT}/secrets/supervisor.kubeconfig}}"
[ -f "$SUP" ] || die "no Supervisor kubeconfig at '$SUP' — run 'make vks-login' first."
k() { kubectl --kubeconfig "$SUP" "$@"; }

WAIT_SECONDS="${VKS_CLUSTER_WAIT_SECONDS:-0}"     # 0 = report once; >0 = poll until ready
# ⚠️ NOT POLL_INTERVAL_SECONDS. That one is UNCOMMENTED in .env.example, so load_env's `set -a`
# re-exports it and CLOBBERS a per-run override — measured here: `POLL_INTERVAL_SECONDS=20 make ...`
# silently polled every 5s. Its own dedicated name cannot be shadowed that way.
POLL="${VKS_CLUSTER_POLL_SECONDS:-15}"

KC="${REPO_ROOT}/secrets/${VKS_CLUSTER_NAME}.kubeconfig"

# nodes_ready — the END RESULT, not a claim about it. Requires every expected node present AND
# Ready, because a cluster can report healthy conditions with zero schedulable workers.
nodes_ready() {
  local want=$(( ${VKS_CONTROL_PLANE_COUNT:-1} + ${VKS_NODE_COUNT:-2} ))
  k -n "$VKS_NAMESPACE" get secret "${VKS_CLUSTER_NAME}-kubeconfig" >/dev/null 2>&1 || return 1
  ( umask 077
    k -n "$VKS_NAMESPACE" get secret "${VKS_CLUSTER_NAME}-kubeconfig" \
      -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > "$KC" ) || return 1
  [ -s "$KC" ] || return 1
  local ready
  ready="$(kubectl --kubeconfig "$KC" get nodes --no-headers 2>/dev/null \
             | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  [ "${ready:-0}" -ge "$want" ]
}

report() {
  local json; json="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" -o json 2>/dev/null || true)"
  [ -n "$json" ] || { echo "  cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}: NOT FOUND"; return 2; }
  # Single-quoted ON PURPOSE: this is a python program and the shell must not touch its $-signs.
  # (It is also why no apostrophe may appear inside it — one did, and it terminated the string,
  # producing a shell syntax error reported at a line number that is inside the python.)
  # shellcheck disable=SC2016
  printf '%s' "$json" | python3 -c '
import json,sys
c=json.load(sys.stdin)
gen=c["metadata"].get("generation")
st=c.get("status",{})
conds={x["type"]:x for x in st.get("conditions",[])}
# The three that actually say the topology controller finished and the CP answers. Gating on the
# first two alone is what the runbook prescribes; TopologyReconciled is what says the CLASS was
# fully applied, and it is present on this lab.
# ⚠️ `Available` IS IN THIS LIST BECAUSE THE OTHER THREE FLAP. MEASURED on this lab: during
# provisioning ControlPlaneInitialized/RemoteConnectionProbe/TopologyReconciled were all True for
# one poll — a waiter gating on just those three BROKE OUT and declared the cluster ready — and the
# very next reconcile bumped metadata.generation and reset them, with 0 of 2 workers available.
# observedGeneration catches a STALE read; it cannot catch a LATER regression. `Available` is the CAPI
# aggregate and was False throughout, so it is the one that does not lie. Nodes are still
# checked below: a condition is a claim, a Ready node is the end result.
need=["ControlPlaneInitialized","RemoteConnectionProbe","TopologyReconciled","Available"]
print("  phase        : %s   (NOT readiness — see the header)" % st.get("phase"))
print("  generation   : %s" % gen)
ready=True
for n in need:
    c2=conds.get(n)
    if not c2:
        print("  %-22s: ABSENT (a fresh cluster has no conditions for a while)" % n); ready=False; continue
    og=c2.get("observedGeneration")
    stale=" [STALE gen %s != %s]" % (og,gen) if og is not None and og!=gen else ""
    ok = c2.get("status")=="True" and not stale
    print("  %-22s: %s%s" % (n, c2.get("status"), stale))
    ready = ready and ok
for n,c2 in sorted(conds.items()):
    if n not in need:
        print("    (also) %-18s %s" % (n, c2.get("status")))
sys.exit(0 if ready else 1)
'
}

if [ "$WAIT_SECONDS" -gt 0 ]; then
  end=$((SECONDS + WAIT_SECONDS))
  while [ "$SECONDS" -lt "$end" ]; do
    # BOTH, in one predicate. Breaking on conditions alone is what produced a false ready here.
    if report && nodes_ready; then
      log_info "READY — conditions hold AND every expected node is Ready."
      break
    fi
    sleep "$POLL"
  done
  if ! { report >/dev/null 2>&1 && nodes_ready; }; then
    log_warn "still not ready after ${WAIT_SECONDS}s — reporting the state as it stands, not a pass."
    # ⚠️ EXIT NON-ZERO. The header promises this, and without it the target could NOT fail:
    # `make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=1800 && make install-all` would run
    # ON A NOT-READY CLUSTER, landing in the ~20-min install-tekton failure scenario-1 §4b
    # documents. A gate whose green is unconditional is not a gate.
    exit 1
  fi
else
  report || true
fi

# Nodes are the end result. A cluster whose conditions are green and whose nodes are absent is
# exactly the state the runbook warns about.
if k -n "$VKS_NAMESPACE" get secret "${VKS_CLUSTER_NAME}-kubeconfig" >/dev/null 2>&1; then
  ( umask 077
    k -n "$VKS_NAMESPACE" get secret "${VKS_CLUSTER_NAME}-kubeconfig" \
      -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > "$KC" )
  if [ -s "$KC" ]; then
    echo "  nodes:"
    kubectl --kubeconfig "$KC" get nodes -o wide 2>&1 | sed 's/^/    /' || true
  fi
else
  echo "  (no ${VKS_CLUSTER_NAME}-kubeconfig Secret yet — the control plane has not been minted)"
fi
