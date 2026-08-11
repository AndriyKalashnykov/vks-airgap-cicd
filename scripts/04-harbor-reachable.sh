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

printf '\n=================== harbor reachable ===================\n' >&2
rc=0
harbor_reachable_report || rc=$?
printf '========================================================\n' >&2
exit "$rc"
