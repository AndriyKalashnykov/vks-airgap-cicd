#!/usr/bin/env bash
# 04-harbor-reachable.sh — READ-ONLY: is HARBOR_URL actually SERVING? Needs no cluster and no kubectl.
#
# scenario-1 asks this at STEP 4, immediately after `make install-harbor-service`, because a
# REINSTALLED Harbor takes a NEW LoadBalancer IP and the operator's A record still names the old one.
#
# It is separate from `make lab-preflight` on purpose. lab-preflight's other three checks (CRD-create,
# a DEFAULT StorageClass, a LoadBalancer provider) are GUEST-CLUSTER preconditions, and at Step 4 the
# current context is the SUPERVISOR — the guest cluster is not created until Step 6. Pointing Step 4
# at lab-preflight therefore reports PROBLEMs on a CORRECT walk, and a gate that is red when nothing
# is wrong is a gate people learn to ignore. lab-preflight still calls the SAME function, so
# install-all keeps full coverage; this target just answers the question Step 4 is asking.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
load_env

# HARBOR_REACHABLE_WAIT_SECONDS -- wait for it, do not just sample it.
#
# The document says, in the sentence immediately before this command, that "Harbor takes about 10
# minutes to answer", and then asks for a point-in-time probe whose Expect is `Harbor answers at`.
# MEASURED 2026-08-12, the create-from-nothing row of the scenario-1 walk: the A record had been
# created seconds earlier, this ran, printed "does not resolve yet", exited 0, and the document's
# promised output never appeared. A reader gets the same thing and has to invent a poll loop.
#
# DEFAULT 900, i.e. it waits WITHOUT being asked. A default of 0 with the document passing the knob
# was the wrong call: a reader who types the bare command still gets the failure this exists to
# prevent, and the knob is one more thing the document has to carry.
#
# 900 is measured, not guessed. Row 3 of the walk, 2026-08-12: `install issued for
# harbor.tanzu.vmware.com` at 16:00:39Z, `Harbor answers at` at 16:08:04Z -- 7m25s. 900s is ~2x that.
#
# It costs lab-preflight NOTHING: that calls harbor_reachable_report DIRECTLY
# (24-lab-preflight.sh:131), not this script, so its fail-fast is unaffected. Set 0 to sample once.
#
# The loop keys on harbor_reachable_ok, NOT on the reporter: the reporter returns 0 for "does not
# resolve yet" -- a note, not a problem -- so a loop built on it would exit on the first pass and
# declare Harbor reachable.
WAIT="${HARBOR_REACHABLE_WAIT_SECONDS:-900}"
# WHOLE SECONDS. `15m` is the plausible typo precisely because the document speaks in minutes, and
# without this it produced `[: 15m: integer expression expected` on stderr, SKIPPED the wait, and
# exited 0 -- i.e. silently restored the exact behaviour the wait was added to fix. `set -e` cannot
# catch it: the `[` is inside an `if` condition, where set -e is suspended.
case "$WAIT" in
  ''|*[!0-9]*) die "HARBOR_REACHABLE_WAIT_SECONDS must be WHOLE SECONDS, got '${WAIT}' (900, not 15m)" ;;
esac

if [ "$WAIT" -gt 0 ]; then
  _state="$(harbor_reachable_state)"
  # DIAGNOSE AT SECOND ONE, THEN WAIT. `silent` -- the name resolves and nothing answers -- is the
  # STALE A RECORD this target was written for, and harbor_reachable_report names it in about a
  # second. Waiting 15 minutes before saying so turns a one-second true positive into a slow one.
  # So: print the cause NOW, and still wait, because the same state is ALSO what a Harbor that is
  # merely still booting looks like. The operator gets the actionable line immediately and can stop;
  # an unattended run keeps its budget. Telling the two apart properly needs the live LoadBalancer
  # IP, which would cost this script its deliberate no-cluster / no-kubectl property.
  if [ "$_state" = silent ]; then
    printf '\n' >&2
    harbor_reachable_report || true
    printf '  ^ that is the diagnosis NOW. It is also what a Harbor that is still booting looks\n' >&2
    printf '    like, so this waits up to %ss anyway. If the address above is the PREVIOUS\n' "$WAIT" >&2
    printf '    install'"'"'s, stop here and fix the A record -- waiting cannot fix it.\n' >&2
  fi
  if [ "$_state" != serving ]; then
    printf '\n  waiting up to %ss for %s to answer ...\n' "$WAIT" "${HARBOR_URL:-<unset>}" >&2
    _w=0
    while [ "$_w" -lt "$WAIT" ]; do
      sleep 15; _w=$((_w + 15))
      harbor_reachable_ok && break
      [ $((_w % 60)) = 0 ] && printf '  still waiting (%s/%ss) ...\n' "$_w" "$WAIT" >&2
    done
  fi
fi

printf '\n=================== harbor reachable ===================\n' >&2
rc=0
harbor_reachable_report || rc=$?
# A WAIT THAT TIMED OUT IS A FAILURE, even though the reporter calls an unresolvable name a note.
# Without this the target exits 0 after waiting 15 minutes for something that never arrived, and the
# reader walks on to `make mirror`, which is the failure this wait exists to prevent.
if [ "$WAIT" -gt 0 ] && ! harbor_reachable_ok; then
  printf '  it did not answer within %ss — do NOT go on to Step 5 until it does.\n' "$WAIT" >&2
  rc=1
fi
printf '========================================================\n' >&2
exit "$rc"
