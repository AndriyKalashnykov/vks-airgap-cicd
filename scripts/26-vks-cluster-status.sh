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

# endpoint_report — PRINTS ONLY. Never gates, never dies, never changes this script's exit code.
#
# WHY IT EXISTS. MEASURED on this lab across FOUR incarnations of the same cluster name: the address
# the Cluster ADVERTISES (spec.controlPlaneEndpoint.host) is the PREVIOUS incarnation's load-balancer
# IP, lagging by exactly one allocation, and such a cluster NEVER converges — CAPI dials an address
# nothing serves.
#     #1 (fresh lab) adv .134 / lb .134  -> AGREE, Ready in 3m45s
#     #2            adv .134 / lb .136  -> never converged in 25 min
#     #3            adv .136 / lb .137  -> never converged
#     #4            adv .137 / lb .138  -> PREDICTED from the pattern, then confirmed
# On #3 the advertised address answered nothing on 6443 while the LB address was OPEN, every
# VirtualMachine condition was True, and the Service endpoints correctly listed the control-plane VM.
# So the VM and the LB are healthy and only the ADVERTISED value is wrong. It did not self-heal.
# nodes_ready() already FAILS in this state — this adds the WHY, so nobody spends 25 minutes
# watching conditions that cannot go True.
#
# WHY IT IS NOT A GATE. This script promises above to exit 0 when not asked to wait, and the cases
# below (a name-vs-IP endpoint, an LB that reports a hostname, a namespace we cannot fully read) are
# legitimate elsewhere. A diagnostic that can false-RED gets ignored; nodes_ready stays the verdict.
#
# HOW THE CONTROL-PLANE LB IS IDENTIFIED — measured, and NOT by name. In this shared vSphere
# Namespace the object carrying the label `run.tanzu.vmware.com/cluster.name: <cluster>` is ANOTHER
# tenant workload port-80 LB projected up from inside the guest; the actual control-plane LB does not
# carry that label at all. Selecting on it would compare our endpoint against a foreign VIP and print
# a confident lie. The discriminator that held on BOTH a healthy and a divergent cluster is:
# type=LoadBalancer AND port 6443 AND ownerReferences -> kind VirtualMachineService named <cluster>.
# If that does not resolve to exactly ONE Service we print the candidates and DECLINE to judge.
endpoint_report() {
  local adv advport adv_rc svc_json svc_rc err
  err="$(mktemp)"; trap 'rm -f "$err"' RETURN

  # Read the host AND the port from the SAME object. The port is not hardcoded: the Cluster that
  # names the address also names the port, so there is nothing to keep in sync and nothing that
  # breaks on a control plane published somewhere other than the usual 6443. (Proven by the fixture
  # suite: with the fixture port overridden, a literal-6443 matcher found ZERO candidate Services
  # and the whole diagnostic went silent.)
  adv="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
           -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>"$err")" && adv_rc=0 || adv_rc=$?
  if [ "$adv_rc" -ne 0 ]; then
    echo "  endpoint     : CANNOT READ the Cluster (rc=$adv_rc: $(head -1 "$err"))"
    return 0
  fi
  advport="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
               -o jsonpath='{.spec.controlPlaneEndpoint.port}' 2>/dev/null || true)"

  svc_json="$(k -n "$VKS_NAMESPACE" get svc -o json 2>"$err")" && svc_rc=0 || svc_rc=$?
  if [ "$svc_rc" -ne 0 ]; then
    echo "  endpoint     : advertised ${adv:-<not set yet>}; CANNOT READ Services (rc=$svc_rc: $(head -1 "$err"))"
    echo "                 (a read-only tenant may lack get/services here — this is not a failure)"
    return 0
  fi

  # shellcheck disable=SC2016
  printf '%s' "$svc_json" | ADV="$adv" ADVPORT="$advport" CL="$VKS_CLUSTER_NAME" NS="$VKS_NAMESPACE" python3 -c '
import json,os,sys
adv=os.environ.get("ADV",""); cl=os.environ.get("CL","")
# The port comes from the Cluster. If it has not been published yet we do not invent one -- we
# accept any port and let the ownerRef do the identifying, rather than silently matching nothing.
try: advport=int(os.environ.get("ADVPORT","") or 0)
except ValueError: advport=0
svcs=json.load(sys.stdin).get("items",[])
cands=[]
for s in svcs:
    if s.get("spec",{}).get("type")!="LoadBalancer": continue
    ports=[p.get("port") for p in s.get("spec",{}).get("ports",[])]
    if advport and advport not in ports: continue
    owners=s.get("metadata",{}).get("ownerReferences",[]) or []
    if not any(o.get("kind")=="VirtualMachineService" and o.get("name")==cl for o in owners): continue
    cands.append(s)
def ing(s):
    i=(s.get("status",{}).get("loadBalancer",{}).get("ingress") or [{}])[0]
    return i.get("ip") or i.get("hostname") or ""
if not adv and not cands:
    print("  endpoint     : NOT YET KNOWABLE (no advertised endpoint, no control-plane LB yet)"); sys.exit(0)
if len(cands)!=1:
    names=", ".join(s["metadata"]["name"] for s in cands) or "none"
    print("  endpoint     : advertised %s; CANNOT IDENTIFY the control-plane LB" % (adv or "<not set yet>"))
    print("                 %d candidate Service(s) matched [%s] -- declining to judge" % (len(cands),names))
    sys.exit(0)
lb=ing(cands[0]); name=cands[0]["metadata"]["name"]
if not adv or not lb:
    print("  endpoint     : NOT YET KNOWABLE (advertised=%s  svc/%s=%s)" % (adv or "-", name, lb or "-"))
    sys.exit(0)
if any(ch.isalpha() for ch in adv):
    print("  endpoint     : advertised %s is a NAME; svc/%s holds %s -- not comparable, reporting both" % (adv,name,lb))
    sys.exit(0)
if adv==lb:
    print("  endpoint     : AGREE (%s == svc/%s)" % (adv,name)); sys.exit(0)
print("  endpoint     : *** DIVERGENT *** advertises %s but svc/%s holds %s" % (adv,name,lb))
print("                 MEASURED on this lab (4 incarnations): a cluster in this state did not")
print("                 converge in 25 min and did not self-heal.  The advertised value has each")
print("                 time been the PREVIOUS incarnation of this cluster NAME.")
print("                 spec.controlPlaneEndpoint is set by the platform, so this is very likely")
print("                 unrecoverable -- but do NOT just delete and recreate under the SAME name,")
print("                 which reproduced it three times running.")
print("                 1. CAPTURE THE EVIDENCE FIRST (deleting destroys the only copy):")
print("                      kubectl -n %s get cluster %s -o yaml > /tmp/diverged-cluster.yaml" % (os.environ.get("NS","<ns>"),cl))
print("                      kubectl -n %s get svc,endpoints -o yaml > /tmp/diverged-svc.yaml" % os.environ.get("NS","<ns>"))
print("                 2. THEN recreate under a DIFFERENT name, which is also the experiment:")
print("                      make vks-cluster-create VKS_CLUSTER_NAME=%s2" % cl)
print("                    converges  -> stale state tied to the reused name")
print("                    lags again -> the platform VIP allocator; send your platform team")
print("                                  the two files above and this table")
' 2>/dev/null || true
  return 0
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
    # The single most useful line when a cluster is not converging, and the reason this ran long.
    endpoint_report
    # ⚠️ EXIT NON-ZERO. The header promises this, and without it the target could NOT fail:
    # `make vks-cluster-status VKS_CLUSTER_WAIT_SECONDS=1800 && make install-all` would run
    # ON A NOT-READY CLUSTER, landing in the ~20-min install-tekton failure scenario-1 §4b
    # documents. A gate whose green is unconditional is not a gate.
    exit 1
  fi
else
  report || true
  endpoint_report
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
    # This script MINTS a kubeconfig and used to tell nobody, so after creating a replacement
    # cluster the operator's .env still named the previous one — and `make vks-login` then died on
    # a file that had been removed with it. PRINT the line rather than writing it: this command
    # advertises itself read-only, .env.state is sourced LAST (so writing KUBECONFIG here would
    # repoint the selector for every later command), and someone running this merely to LOOK at
    # another cluster must not have their environment silently retargeted.
    if [ "$(printf '%s' "${KUBECONFIG:-}")" != "$KC" ]; then
      echo
      echo "  This cluster's kubeconfig is at:  $KC"
      echo "  Your KUBECONFIG currently points at: ${KUBECONFIG:-<unset>}"
      echo "  To make the rest of the walk use THIS cluster, set it in .env:"
      echo "      KUBECONFIG=./secrets/${VKS_CLUSTER_NAME}.kubeconfig"
      echo "  (then: make env-check   -- it now runs inside 'make preflight', so a stale value is"
      echo "   caught before the 20-minute mirror rather than after it)"
    fi
  fi
else
  echo "  (no ${VKS_CLUSTER_NAME}-kubeconfig Secret yet — the control plane has not been minted)"
fi
