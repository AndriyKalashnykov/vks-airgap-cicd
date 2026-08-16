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
SUP="$(supervisor_kubeconfig || printf '%s' "${REPO_ROOT}/secrets/supervisor.kubeconfig")"   # lib/os.sh: ONE resolver, first that EXISTS
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
  # "I COULD NOT ASK" IS NOT "IT DOES NOT EXIST" (B110, 4 of 4). This used to be
  # `2>/dev/null || true`, so a stale CA, a rejected token, a missing grant or an unreachable
  # endpoint all printed "NOT FOUND" — a factual claim about the cluster derived from a connection
  # that never succeeded. Terse on purpose: report() runs on every poll iteration, so each class
  # sets a short reason and there is ONE line of output.
  #
  # rc is UNCHANGED (2). Both callers use it as a boolean only (`if report && nodes_ready` at the
  # wait loop, `report || true` on the report-once path), so a new code would be invented precision
  # nothing reads.
  local json _rep_err _rep_rc=0 _why=""
  _rep_err="$(mktemp)"
  json="$(k -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" -o json 2>"$_rep_err")" || _rep_rc=$?
  # A DEFINITIVE NotFound IS AN ANSWER — we asked, and a reachable, authenticated API server told
  # us. It must NOT go through classify_kube_failure: that taxonomy is about TRANSPORT and AUTH
  # ("we could not ask"), and every arm of it ends in the line "this is NOT 'the cluster does not
  # exist'". For a NotFound that line is simply FALSE.
  #
  # MEASURED 2026-08-16, matrix row 3: the create was REJECTED outright by the admission webhook, so
  # the Cluster was never written. This function then printed
  #     cluster cicd/<name>: COULD NOT ASK — ... (this is NOT 'the cluster does not exist')
  # on EVERY poll for 1806 SECONDS. Half an hour spent waiting for an object whose creation had
  # already hard-failed, while telling the reader the opposite of the truth.
  #
  # It is handled HERE, not by adding a class to the shared classifier: NotFound is a per-RESOURCE
  # fact, the classifier is per-CONNECTION, and adding a class would force all seven of its
  # consumers to grow an arm for a concept most of them cannot encounter.
  if [ "$_rep_rc" -ne 0 ] && grep -qE 'NotFound|not found' "$_rep_err" 2>/dev/null \
     && ! grep -qiE 'no such host|connection refused|certificate|Unauthorized|Forbidden|no such file' "$_rep_err" 2>/dev/null; then
    rm -f "$_rep_err"
    echo "  cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}: DOES NOT EXIST — the Supervisor answered, and has no such Cluster."
    return 3
  fi
  if [ "$_rep_rc" -ne 0 ]; then
    case "$(classify_kube_failure "$_rep_err")" in
      STALE_CA)            _why="the kubeconfig does not work against this cluster (rebuilt CA?) — make vks-login" ;;
      UNAUTHORIZED)        _why="the Supervisor rejected these credentials — make vks-login" ;;
      FORBIDDEN)           _why="this identity may not read Clusters here — an RBAC grant, not a missing cluster" ;;
      UNREACHABLE)         _why="the Supervisor could not be reached — check the address and the network" ;;
      PLAINTEXT)           _why="the endpoint answered plaintext where TLS was expected — check the server URL" ;;
      NO_KUBE_TARGET)      _why="the kubeconfig names no cluster to talk to — make vks-login" ;;
      KUBECONFIG_UNUSABLE) _why="the kubeconfig is unusable (something it names is missing) — make vks-login" ;;
      *)                   _why="$(head -1 "$_rep_err")" ;;
    esac
    rm -f "$_rep_err"
    echo "  cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}: COULD NOT ASK — ${_why}"
    echo "                     (this is NOT 'the cluster does not exist')"
    return 2
  fi
  rm -f "$_rep_err"
  [ -n "$json" ] || { echo "  cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}: NOT FOUND"; return 2; }
  # jq, NOT python3. MEASURED 2026-08-09 walking scenario-1 on a bare photon:5.0 jump box against a
  # real 9.1 lab: python3 is ABSENT on Photon, so this function died `python3: command not found`
  # (rc 127) on an OS this repo documents as a supported jump box — and `make check-tools` had
  # printed "all REQUIRED tools present." moments earlier. jq is already REQUIRED and carried in the
  # air-gap bundle, so this adds no dependency; adding python3 to the OS floor was rejected when this
  # repo hit the identical class once before (see lib/os.sh's pick_port note): that floor is
  # provisioned BY HAND on a box with no internet.
  #
  # SEMANTICS PRESERVED EXACTLY: the same four gating conditions, the same observedGeneration
  # staleness rule, the same "(also)" listing of the rest, the same readiness verdict.
  # shellcheck disable=SC2016
  local _rep
  _rep="$(printf '%s' "$json" | jq -r '
    def pad($s; $n): $s + (" " * ([0, $n - ($s|length)] | max));
    . as $c
    | ($c.metadata.generation) as $gen
    | ($c.status // {}) as $st
    | (($st.conditions // []) | map({key: .type, value: .}) | from_entries) as $conds
    # The three that actually say the topology controller finished and the CP answers, plus
    # Available. ⚠️ Available IS IN THIS LIST BECAUSE THE OTHER THREE FLAP. MEASURED on this lab:
    # during provisioning ControlPlaneInitialized/RemoteConnectionProbe/TopologyReconciled were all
    # True for one poll — a waiter gating on just those three BROKE OUT and declared the cluster
    # ready — and the very next reconcile bumped metadata.generation and reset them, with 0 of 2
    # workers available. observedGeneration catches a STALE read; it cannot catch a LATER
    # regression. Available is the CAPI aggregate and was False throughout, so it is the one that
    # does not lie. Nodes are still checked below: a condition is a claim, a Ready node is the end
    # result.
    | ["ControlPlaneInitialized","RemoteConnectionProbe","TopologyReconciled","Available"] as $need
    | ($need | map(
        . as $n
        | ($conds[$n]) as $c2
        | if $c2 == null then
            { line: "  " + pad($n; 22) + ": ABSENT (a fresh cluster has no conditions for a while)",
              ok: false }
          else
            ($c2.observedGeneration) as $og
            | (if $og != null and $og != $gen then " [STALE gen \($og) != \($gen)]" else "" end) as $stale
            | { line: "  " + pad($n; 22) + ": \($c2.status)\($stale)",
                ok: (($c2.status == "True") and ($stale == "")) }
          end)) as $rows
    | ( [ "  phase        : \($st.phase)   (NOT readiness — see the header)",
          "  generation   : \($gen)" ]
        + ($rows | map(.line))
        + ( $conds | to_entries | sort_by(.key)
            | map(select(.key as $k | ($need | index($k)) == null)
                  | "    (also) " + pad(.key; 18) + " \(.value.status)") )
        + [ "__READY__ " + (if ($rows | all(.ok)) then "true" else "false" end) ]
      )[]
  ' 2>/dev/null)"
  [ -n "$_rep" ] || { echo "  cluster ${VKS_NAMESPACE}/${VKS_CLUSTER_NAME}: could not parse status JSON"; return 2; }
  printf '%s\n' "$_rep" | grep -v '^__READY__ '
  printf '%s\n' "$_rep" | grep -q '^__READY__ true$'
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

  # jq, NOT python3 — same reason as report() above (python3 is absent on a Photon jump box, and
  # this is the command scenario-1 Step 4 runs immediately after vks-cluster-create). jq is already
  # REQUIRED and carried. Semantics preserved exactly, including "declining to judge" whenever the
  # evidence cannot identify a single control-plane LoadBalancer.
  # shellcheck disable=SC2016
  printf '%s' "$svc_json" | jq -r \
      --arg adv "$adv" --arg advport "$advport" --arg cl "$VKS_CLUSTER_NAME" --arg ns "$VKS_NAMESPACE" '
    # The port comes from the Cluster. If it has not been published yet we do not invent one — we
    # accept any port and let the ownerRef do the identifying, rather than silently matching nothing.
    ($advport | tonumber? // 0) as $port
    | [ (.items // [])[]
        | select(.spec.type == "LoadBalancer")
        | select($port == 0 or ((.spec.ports // []) | map(.port) | index($port) != null))
        | select((.metadata.ownerReferences // [])
                 | any(.kind == "VirtualMachineService" and .name == $cl)) ] as $cands
    | ( $cands | map(((.status.loadBalancer.ingress // [{}])[0]) | (.ip // .hostname // "")) ) as $ips
    | if ($adv == "" and ($cands | length) == 0) then
        "  endpoint     : NOT YET KNOWABLE (no advertised endpoint, no control-plane LB yet)"
      elif ($cands | length) != 1 then
        "  endpoint     : advertised \(if $adv == "" then "<not set yet>" else $adv end); CANNOT IDENTIFY the control-plane LB",
        "                 \($cands|length) candidate Service(s) matched [\(if ($cands|length)==0 then "none" else ($cands|map(.metadata.name)|join(", ")) end)] -- declining to judge"
      else
        ($cands[0].metadata.name) as $name | ($ips[0]) as $lb
        | if ($adv == "" or $lb == "") then
            "  endpoint     : NOT YET KNOWABLE (advertised=\(if $adv=="" then "-" else $adv end)  svc/\($name)=\(if $lb=="" then "-" else $lb end))"
          elif ($adv | test("[A-Za-z]")) then
            "  endpoint     : advertised \($adv) is a NAME; svc/\($name) holds \($lb) -- not comparable, reporting both"
          elif ($adv == $lb) then
            "  endpoint     : AGREE (\($adv) == svc/\($name))"
          else
            "  endpoint     : *** DIVERGENT *** advertises \($adv) but svc/\($name) holds \($lb)",
            "                 MEASURED on this lab (4 incarnations): a cluster in this state did not",
            "                 converge in 25 min and did not self-heal.  The advertised value has each",
            "                 time been the PREVIOUS incarnation of this cluster NAME.",
            "                 spec.controlPlaneEndpoint is set by the platform, so this is very likely",
            "                 unrecoverable -- but do NOT just delete and recreate under the SAME name,",
            "                 which reproduced it three times running.",
            "                 1. CAPTURE THE EVIDENCE FIRST (deleting destroys the only copy):",
            "                      kubectl -n \($ns) get cluster \($cl) -o yaml > /tmp/diverged-cluster.yaml",
            "                      kubectl -n \($ns) get svc,endpoints -o yaml > /tmp/diverged-svc.yaml",
            "                 2. THEN recreate under a DIFFERENT name, which is also the experiment:",
            "                      make vks-cluster-create VKS_CLUSTER_NAME=\($cl)2",
            "                    converges  -> stale state tied to the reused name",
            "                    lags again -> the platform VIP allocator; send your platform team",
            "                                  the two files above and this table"
          end
      end
  ' 2>/dev/null || true
  return 0
}

if [ "$WAIT_SECONDS" -gt 0 ]; then
  # READ THE ENDPOINT ONCE, BEFORE BURNING THE BUDGET (B92).
  #
  # A cluster whose advertised controlPlaneEndpoint diverges from its LoadBalancer has, on this lab,
  # never converged -- measured across four incarnations, none of which self-healed. The wait branch
  # used to enter its loop without looking, so `VKS_CLUSTER_WAIT_SECONDS=1800` spent the full 30
  # minutes to reach a conclusion that was already knowable in one read, and only THEN printed the
  # remedy from the timeout path.
  #
  # GATED AT THE CALL SITE, NOT INSIDE THE FUNCTION. endpoint_report is print-only by contract --
  # its header says so and test-endpoint-report asserts "DIVERGENT still exits 0 (never gates)" --
  # and it is also called on the report-once path (below), which the Makefile advertises as
  # read-only. Making the FUNCTION return non-zero would break both. Capturing its output here
  # changes neither.
  #
  # ONLY the DIVERGENT verdict stops. Every DECLINE path it has -- NOT YET KNOWABLE (either value
  # empty), a NAME-shaped endpoint that is not comparable to an IP, AGREE, or no candidate Service --
  # falls through unchanged, so a healthy or still-provisioning cluster is never blocked.
  # NO `2>/dev/null` here: endpoint_report already silences kubectl/jq stderr internally, so the
  # only thing this would hide is a fault in the function itself. Measured with a failing mktemp:
  # suppressed, the guard reported "CANNOT READ the Cluster" — a cluster that reads perfectly —
  # while the un-captured sibling call printed the real cause. An error naming the wrong cause is
  # worse than a crash.
  _ep_once="$(endpoint_report || true)"
  [ -n "$_ep_once" ] && printf '%s\n' "$_ep_once"
  case "$_ep_once" in
    *'*** DIVERGENT ***'*)
      die "refusing to wait ${WAIT_SECONDS}s on a cluster whose endpoint already diverges.
  The remedy is printed above, and waiting cannot change it: spec.controlPlaneEndpoint is written by
  the platform and has not been observed to self-correct. Capture the evidence and recreate under a
  DIFFERENT name -- recreating under the same one reproduced this three times running." ;;
  esac
  # SAME SHAPE AS THE DIVERGENT GUARD ABOVE, for the same reason: read the state ONCE before
  # spending the budget. A Cluster that DOES NOT EXIST cannot become ready by waiting — the create
  # either never ran or was rejected, and both are visible right now. MEASURED: row 3 waited the
  # full 1800s for a Cluster whose create had been rejected 60 seconds earlier.
  # Only rc=3 (the definitive DOES NOT EXIST) stops here. Every "could not ask" class still falls
  # through and waits, because those genuinely can resolve while we watch.
  # `report; rc=$?` would DIE HERE: this script is `set -euo pipefail` and report() returns
  # non-zero for every not-yet-ready cluster, so the script would exit before the check — refusing
  # the healthy and provisioning cases it must let through. Caught by the two existing cases going
  # red, which is what they are for.
  _rep_first=0; report || _rep_first=$?
  if [ "$_rep_first" -eq 3 ]; then
    die "refusing to wait ${WAIT_SECONDS}s for a cluster the Supervisor says does not exist.
  Nothing was created, so nothing can converge. Either 'make vks-cluster-create' was never run, or
  it was REJECTED -- re-run it and read its output; a rejection names the field it objected to and
  costs about a second, because it validates server-side before applying."
  fi

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
