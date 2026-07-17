#!/usr/bin/env bash
# e2e-ordering-verdict.sh — the LAST line of `make e2e-kind`, printed to STDOUT where the operator
# actually looks (B42).
#
# A WARM `make e2e-kind` SILENTLY REUSES an existing cluster and tests only an idempotent re-apply:
# it CANNOT prove namespace CREATE-ordering (a missing or late `ensure_namespace` label is invisible
# once the namespace already exists), yet it exits 0 and looks IDENTICAL to a real pass. A mid-run
# `log_warn` at kind-up time is buried thousands of stderr lines above the finish — effectively
# silent. So 05-kind-up.sh PUBLISHES the reuse fact (state_set KIND_REUSED) and this script reads it
# back and prints the verdict at the very end, on stdout.
#
# Reuse is a VALID fast dev mode — this does NOT fail the run (exit 0). It just makes the caveat
# unmissable. `E2E_FRESH=1 make e2e-kind` (or `make kind-down` first) gives a guaranteed cold run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/state.sh
. "${SCRIPT_DIR}/lib/state.sh"

sf="$(state_file 2>/dev/null || true)"
reused="$(grep -m1 '^KIND_REUSED=' "$sf" 2>/dev/null | cut -d= -f2- || true)"

case "$reused" in
  1)
    cat <<'BANNER'

  ======================================================================
  WARNING — CREATE-ORDERING NOT PROVEN: this e2e REUSED a warm cluster.
  It tested an idempotent re-apply over already-created namespaces, where
  a missing or late ensure_namespace label CANNOT fail — so this run is
  NOT evidence for namespace create-ordering (B42), even though it passed.
  For that evidence, run a COLD cluster:
      E2E_FRESH=1 make e2e-kind      (or:  make kind-down && make e2e-kind)
  ======================================================================

BANNER
    ;;
  0)
    printf '\n  OK — create-ordering EXERCISED: this e2e ran on a freshly-created cluster.\n\n'
    ;;
  *)
    printf '\n  NOTE — create-ordering UNKNOWN: no KIND_REUSED in the state sink (kind-up may not have run).\n\n'
    ;;
esac
