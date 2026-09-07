#!/usr/bin/env bash
# test-vks-cluster-delete.sh — pin 97-vks-cluster-delete.sh's VIP-release wait (B524).
# ci-tier: fast — offline; a stub kubectl on PATH, no cluster, no network, no lab contact.
#
# WHAT IT GUARDS. Deleting a guest cluster releases THREE VIPs. MEASURED on cicd-gc3 2026-09-07:
# the control-plane VMService (name == the cluster) plus TWO workload ones whose names are
# hash-suffixed and whose only link to the cluster is a label and a plain ownerReference. Those two
# carry NO `controller: true` and NO `blockOwnerDeletion: true`, so Kubernetes removes them by
# BACKGROUND GARBAGE COLLECTION — strictly AFTER the owner is gone. The old wait did
# `get virtualmachineservice $NAME`, an EXACT-name lookup, so it announced "released" at precisely
# the moment two VIPs were still held. That is the ordering of k8s GC, not a race that might happen.
#
# ⚠️ FOUR FAILURE MODES THIS TEST IS BUILT TO AVOID — all four are recorded incidents in this repo:
#   1. Asserting a hand-typed COPY of the predicate. A sibling test once reported `24 passed` after
#      an adversary DELETED the entire 541-byte guard it was supposedly testing. So this drives
#      97-vks-cluster-delete.sh ITSELF; if the wait is deleted, cases below go red.
#   2. Writing into the real tree. That same sibling truncated a real secrets/*.kubeconfig to 0
#      bytes. `97` derives REPO_ROOT from its OWN location (:31, an unconditional assignment that no
#      env var overrides), so the sandbox holds a COPY of the script and of lib/ — that is the only
#      thing that makes ${REPO_ROOT}/secrets point at the sandbox. The cluster name is one no
#      operator has, and VKS_SUPERVISOR_KUBECONFIG is pinned into the sandbox.
#   3. A stub that does not model the real argv. The widened predicate sends a `-l` SELECTOR and a
#      jsonpath over ownerReferences — argv shapes a naive stub never produces, and without them the
#      prefix-collision case can never go red.
#   4. A stub that cannot be EMPTY-but-FAILING. `wc -l` is 0 for both "nothing left" and "the query
#      was forbidden", so the fail-closed branch is unreachable unless the stub can return rc!=0
#      with empty stdout.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO="$PWD"

p=0; f=0
ok()  { p=$((p+1)); printf 'ok    %s\n' "$1"; }
bad() { f=$((f+1)); printf 'FAIL  %s\n' "$1" >&2; }

_canary_before="$(md5sum "$REPO/secrets/supervisor.kubeconfig" 2>/dev/null || echo ABSENT)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/lib" "$T/secrets" "$T/bin" "$T/state"
cp "$REPO/scripts/97-vks-cluster-delete.sh" "$T/scripts/"
cp "$REPO"/scripts/lib/*.sh "$T/scripts/lib/"
printf 'stub\n' > "$T/secrets/supervisor.kubeconfig"
# load_env FATALs without it, and the sandbox is a different REPO_ROOT than the real repo.
cp "$REPO/.env.example" "$T/.env.example"

CN=zz-b524-not-a-real-cluster
NS=zz-b524-ns

# ── the stub. Scenario is driven by files under $T/state, so each case sets its own world. ────────
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# A stub that models the REAL argv of every call 97 makes.
S="${STUB_STATE:?}"
NAME="${STUB_CLUSTER:?}"   # so NotFound messages carry the REAL resource token
args="$*"
case "$args" in
  *" delete cluster "*) : > "$S/deleted"; exit 0 ;;   # the Cluster disappears AFTER the delete
  *"jsonpath={.metadata.labels.vks-airgap-cicd"*)          # the ownership label
      printf 'vks-airgap-cicd'; exit 0 ;;
  *" get cluster "*)
      # ⚠️ STATEFUL ON PURPOSE. 97 checks the Cluster EXISTS before deleting (else it exits
      # "nothing to delete" and never reaches the wait), then polls until it is GONE. A stub that
      # reports it absent from the start cannot exercise the wait at all — the first draft of this
      # test did exactly that and the CONTROL caught it.
      [ -e "$S/deleted" ] && exit 1
      [ -e "$S/cluster" ] && exit 0 || exit 1 ;;
  *"-l run.tanzu.vmware.com/cluster.name="*)               # the WORKLOAD label selector
      if [ -e "$S/label-rc" ]; then exit "$(cat "$S/label-rc")"; fi   # rc!=0 WITH EMPTY STDOUT
      [ -e "$S/vms-workload" ] && sed 's|^|virtualmachineservice.vmoperator.vmware.com/|' "$S/vms-workload"
      exit 0 ;;
  *"jsonpath={range .items[*]}{.metadata.name}"*)          # the ownerReference cross-check
      if [ -e "$S/owner-rc" ]; then exit "$(cat "$S/owner-rc")"; fi
      [ -e "$S/owners" ] && cat "$S/owners"
      exit 0 ;;
  *" get virtualmachineservice "*)                          # the CONTROL-PLANE one, by exact name
      # ⚠️ THE KNOB THAT WAS MISSING. Without it the case named FAIL-CLOSED could only inject
      # failure on an arm that ALREADY failed closed — a RED-proof over a subset, and it is exactly
      # why the control-plane arm shipped failing OPEN.
      if [ -e "$S/cp-rc" ]; then printf 'Unable to connect to the server: net/http: request canceled\n' >&2; exit "$(cat "$S/cp-rc")"; fi
      [ -e "$S/vms-cp" ] && exit 0
      # ⚠️ THE REAL MESSAGE SHAPE, with the REAL name. kube_is_notfound requires the server's
      # `Error from server (NotFound)` prefix AND the resource token on the SAME line; a stub that
      # emits a placeholder name silently fails that match and every case goes red for the wrong
      # reason. A double must model the real output, not just the real exit code.
      printf 'Error from server (NotFound): virtualmachineservices.vmoperator.vmware.com "%s" not found\n' "$NAME" >&2; exit 1 ;;
  *" get svc "*)
      if [ -e "$S/svc-rc" ]; then printf 'Unable to connect to the server: net/http: request canceled\n' >&2; exit "$(cat "$S/svc-rc")"; fi
      [ -e "$S/svc" ] && exit 0
      printf 'Error from server (NotFound): services "%s" not found\n' "$NAME" >&2; exit 1 ;;
esac
# ⚠️ DO NOT fall through to `exit 0`. A silent success-empty means a future query nobody modelled is
# unexercised while the suite stays green — the stub would be certifying its own blind spot.
printf 'test stub: UNMODELLED kubectl call: %s\n' "$args" >&2
exit 97
STUB
chmod +x "$T/bin/kubectl"

run97() { # run97 -> stdout+stderr in $OUT, rc in $RC
  OUT="$(PATH="$T/bin:$PATH" STUB_STATE="$T/state" STUB_CLUSTER="$CN" \
         VKS_SUPERVISOR_KUBECONFIG="$T/secrets/supervisor.kubeconfig" \
         VKS_NAMESPACE="$NS" VKS_CLUSTER_NAME="$CN" CONFIRM="$CN" \
         VKS_CLUSTER_DELETE_WAIT_SECONDS=2 VKS_CLUSTER_DELETE_POLL_SECONDS=1 \
         SKIP_DOTENV=1 bash "$T/scripts/97-vks-cluster-delete.sh" 2>&1)"; RC=$?
}
# world — reset to "the Cluster exists and nothing else does". It always starts present because 97
# refuses to proceed otherwise ("nothing to delete"), and it vanishes when the stub sees
# `delete cluster`. Each case then creates whatever it wants to SURVIVE the delete.
world() { rm -f "$T/state"/*; : > "$T/state/cluster"; }

# ── POSITIVE CONTROL FIRST. If the script does not even reach its wait, every case below is
# vacuous — it would "pass" by exiting early on the ownership guard or a missing kubeconfig.
world
run97
if printf '%s' "$OUT" | grep -q 'deleting'; then
  ok "CONTROL: the real script runs past its guards and reaches the wait"
else
  bad "CONTROL: 97 never reached the wait — every case below is vacuous. rc=$RC out=$OUT"
fi

# ── THE DEFECT. CP gone, workload VMServices STILL HOLDING their VIPs.
world           # no cluster, no cp vmservice, no svc
printf '%s\n' "${CN}-39bf68c1a97350babccd3" "${CN}-b040aa492542c22aa31e3" > "$T/state/vms-workload"
run97
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "${CN}-39bf68c1a97350babccd3"; then
  ok "B524: workload VMServices still present -> does NOT release, and NAMES them"
else
  bad "B524 THE DEFECT: released while two workload VIPs were still held. rc=$RC out=$OUT"
fi

# ── the same, reached only through the ownerReference path (no label on this build).
world
printf '%s|Cluster/%s \n' "${CN}-deadbeef" "$CN" > "$T/state/owners"
run97
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "${CN}-deadbeef"; then
  ok "B524: an EXACT ownerReference Cluster/<name> is also caught (label absent)"
else
  bad "B524: the ownerReference arm missed a holder. rc=$RC out=$OUT"
fi

# ── PREFIX COLLISION. A SIBLING cluster's objects must not make this hang forever.
# `cicd-gc1` is a prefix of `cicd-gc10`, and the CP VMService's own owner is
# `VSphereCluster/<name>-<hash>` which CONTAINS the name — a substring test hangs on both.
world
printf '%s\n' "${CN}0-aaaaaaaaaaaa" > "$T/state/vms-workload-IGNORED"   # not the selector's answer
printf '%s|Cluster/%s0 \n' "${CN}0-aaaaaaaaaaaa" "$CN" > "$T/state/owners"
run97
if [ "$RC" -eq 0 ]; then
  ok "PREFIX: a sibling '${CN}0' does NOT hold this delete open (exact match, not substring)"
else
  bad "PREFIX: a sibling cluster made the wait hang — the match is a substring. rc=$RC out=$OUT"
fi

# ── FAIL CLOSED. A forbidden/timed-out query is EMPTY, exactly like "nothing left".
world
echo 1 > "$T/state/label-rc"
run97
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'QUERY-FAILED'; then
  ok "FAIL-CLOSED: a failed VMService query counts as PRESENT, and says so"
else
  bad "FAIL-OPEN: a broken read was reported as released — the incident this wait prevents. rc=$RC out=$OUT"
fi

# ── FAIL CLOSED ON THE ARM THAT MATTERS. A SELECTIVE failure — one dropped request on the
# CONTROL-PLANE read while the other arms answer normally — used to return rc=0 with an empty
# holder list, so the script announced "released" and pointed at `make vks-cluster-create`. Each
# arm carries its own 15s timeout, so a selective failure is ordinary, not exotic.
world
echo 1 > "$T/state/cp-rc"
run97
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'QUERY-FAILED(control-plane-vmservice'; then
  ok "FAIL-CLOSED: a broken CONTROL-PLANE read counts as PRESENT and names the class"
else
  bad "FAIL-OPEN on the control-plane arm — the object this whole feature guards. rc=$RC out=$OUT"
fi

world
echo 1 > "$T/state/svc-rc"
run97
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'QUERY-FAILED(svc'; then
  ok "FAIL-CLOSED: a broken svc read also counts as PRESENT"
else
  bad "FAIL-OPEN on the svc arm. rc=$RC out=$OUT"
fi

# ── the timeout ADVICE must depend on WHICH object is left. Telling an operator not to recreate
# when only a WORKLOAD VIP remains is advice for a hazard that does not apply — the CP address is
# already free and a never-used name is unaffected by pool hygiene.
world
printf '%s\n' "${CN}-workload-only" > "$T/state/vms-workload"
run97
if printf '%s' "$OUT" | grep -q 'CONTROL-PLANE VIP is already released'; then
  ok "timeout advice: workload-only -> says the CP VIP is already released"
else
  bad "timeout advice: workload-only still told the operator not to recreate. out=$OUT"
fi
world; : > "$T/state/vms-cp"
run97
if printf '%s' "$OUT" | grep -q 'Do NOT create a replacement yet'; then
  ok "timeout advice: the CONTROL-PLANE still held -> warns off a recreate"
else
  bad "timeout advice: the CP was held and it did NOT warn. out=$OUT"
fi

# ── a documented tunable must not produce a bash internal error instead of the guidance.
world; : > "$T/state/vms-cp"
OUT="$(PATH="$T/bin:$PATH" STUB_STATE="$T/state" STUB_CLUSTER="$CN" \
       VKS_SUPERVISOR_KUBECONFIG="$T/secrets/supervisor.kubeconfig" \
       VKS_NAMESPACE="$NS" VKS_CLUSTER_NAME="$CN" CONFIRM="$CN" \
       VKS_CLUSTER_DELETE_WAIT_SECONDS=0 VKS_CLUSTER_DELETE_POLL_SECONDS=1 \
       SKIP_DOTENV=1 bash "$T/scripts/97-vks-cluster-delete.sh" 2>&1)"; RC=$?
if ! printf '%s' "$OUT" | grep -q 'unbound variable'; then
  ok "WAIT_SECONDS=0 (a documented tunable) does not die on an unbound variable"
else
  bad "WAIT_SECONDS=0 replaced the guidance block with a bash internal error. out=$OUT"
fi

# ── the clean release, and the disclaimer that must survive it.
world
run97
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'released'; then
  ok "clean: everything gone -> releases with rc=0"
else
  bad "clean: a fully-released cluster did not release. rc=$RC out=$OUT"
fi
if printf '%s' "$OUT" | grep -qi 'QUARANTINED'; then
  ok "the B525 quarantine disclaimer survives the release (absence != reusable)"
else
  bad "the quarantine disclaimer was lost — the target now implies the VIP is immediately reusable"
fi

# ── the timeout must not escalate.
world
printf '%s\n' "${CN}-stuck" > "$T/state/vms-workload"
run97
# ⚠️ `rc != 0` ALONE is a vacuous assertion here — it passed off an unrelated FATAL on the first
# run, before the sandbox had .env.example. Require it to NAME the object it is still waiting on.
# ⚠️ MY FIRST ASSERTION HERE WAS WRONG and matched the script's own benign progress line
# "(asynchronous — two controllers hold finalizers)". Assert the POSITIVE thing the script promises
# at timeout — it says "NOT stripping finalizers" in as many words — plus the name of what is held.
# A negative grep for the WORD 'finalizer' cannot distinguish a promise from an escalation.
# ⚠️ This case holds a WORKLOAD VMService only, so the advice it must carry is the workload branch
# — not 'Do NOT create a replacement yet', which is asserted by its own case above. An earlier
# version demanded both and went red once the advice learned to branch: the assertion, not the code.
if [ "$RC" -ne 0 ] \
   && printf '%s' "$OUT" | grep -q "${CN}-stuck" \
   && printf '%s' "$OUT" | grep -q 'NOT stripping finalizers' \
   && printf '%s' "$OUT" | grep -q 'CONTROL-PLANE VIP is already released'; then
  ok "timeout: NAMES the object still held, refuses to strip finalizers, gives the right advice"
else
  bad "timeout: escalated to stripping finalizers (that orphans VMs and FCDs). out=$OUT"
fi

# ── the SELF-CANARY: this test must not be able to touch the real repo.
# ⚠️ THE CANARY COMPARES A BEFORE-SNAPSHOT, taken at the top of this file. The first version was
# `[ -s f ] || [ ! -e f ]`, which is TRUE for an absent file — so "was already absent" and "we
# deleted it" read identically, and on a box with no secrets/ it was vacuously green.
_canary_now="$(md5sum "$REPO/secrets/supervisor.kubeconfig" 2>/dev/null || echo ABSENT)"
if [ "$_canary_now" = "$_canary_before" ]; then
  ok "SELF-CANARY: the real secrets/supervisor.kubeconfig is byte-identical to before this run"
else
  bad "SELF-CANARY: the real supervisor kubeconfig CHANGED — REPO_ROOT escaped the sandbox"
fi

printf '\n%s\n' "test-vks-cluster-delete: $p passed, $f failed"
[ "$f" -eq 0 ] || exit 1
