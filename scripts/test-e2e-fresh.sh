#!/usr/bin/env bash
# test-e2e-fresh.sh — B42: assert the E2E_FRESH cold-mode wiring + the final ordering verdict.
#
# (1) `make -n E2E_FRESH=1 e2e-kind` must ACTUALLY recurse into kind-down (cold), `=0` must not.
#     The discriminator is the kind-down RECIPE BODY (`kind-down.sh`), NOT the string "kind-down":
#     under `make -n` the conditional line `if [ "0" = "1" ]; then … make kind-down; fi` is PRINTED
#     verbatim (it contains "kind-down") even when false — only a real recursion prints `kind-down.sh`.
#     `make -n` never executes the recipe, so this is offline and cannot tear down a cluster.
# (2) e2e-ordering-verdict.sh must print the right stdout banner for KIND_REUSED = 1 / 0 / unset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# --- (1) E2E_FRESH wiring, via make -n (prints, never executes) -------------------------------------
n1=$(make -n E2E_FRESH=1 e2e-kind 2>/dev/null | grep -c 'kind-down\.sh' || true)
n0=$(make -n E2E_FRESH=0 e2e-kind 2>/dev/null | grep -c 'kind-down\.sh' || true)
v=$(make  -n E2E_FRESH=0 e2e-kind 2>/dev/null | grep -c 'e2e-ordering-verdict\.sh' || true)
if [ "$n1" -ge 1 ]; then ok "E2E_FRESH=1 → e2e-kind runs kind-down FIRST (cold, proves create-ordering)"; else bad "E2E_FRESH=1 did NOT trigger kind-down (n1=$n1)"; fi
if [ "$n0" -eq 0 ]; then ok "E2E_FRESH=0 → e2e-kind does NOT kind-down (warm/fast default)"; else bad "E2E_FRESH=0 unexpectedly triggered kind-down (n0=$n0)"; fi
if [ "$v"  -ge 1 ]; then ok "the final e2e-ordering-verdict step is wired into e2e-kind"; else bad "e2e-ordering-verdict.sh is NOT the last e2e-kind step (v=$v)"; fi

# --- (2) the verdict banner for each KIND_REUSED value (offline, a controlled state file) -----------
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
verdict() { # <value-or-empty> → the verdict script's stdout against a state file holding KIND_REUSED
  local sf="$tmp/.env.state"; : > "$sf"
  [ -n "${1:-}" ] && printf 'KIND_REUSED=%s\n' "$1" > "$sf"
  VKS_STATE_FILE="$sf" "${SCRIPT_DIR}/e2e-ordering-verdict.sh" 2>/dev/null
}
if verdict 1  | grep -q 'CREATE-ORDERING NOT PROVEN'; then ok "verdict: KIND_REUSED=1 → loud NOT-PROVEN banner"; else bad "verdict: KIND_REUSED=1 did not warn"; fi
if verdict 0  | grep -q 'create-ordering EXERCISED';  then ok "verdict: KIND_REUSED=0 → EXERCISED (fresh)";      else bad "verdict: KIND_REUSED=0 wrong"; fi
if verdict "" | grep -q 'UNKNOWN';                    then ok "verdict: no KIND_REUSED → UNKNOWN";               else bad "verdict: empty state wrong"; fi

if [ "$fail" -ne 0 ]; then log_error "test-e2e-fresh: FAILED"; exit 1; fi
log_info "test-e2e-fresh: OK — E2E_FRESH cold-mode wiring + the reuse verdict banner"
