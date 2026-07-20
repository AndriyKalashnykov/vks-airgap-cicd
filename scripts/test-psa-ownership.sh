#!/usr/bin/env bash
# test-psa-ownership.sh — 49-psa-check.sh's MESH-OWNERSHIP branch, driven by a fake kubectl.
#
# WHY THIS EXISTS. `grep -rln 49-psa-check` finds only parsers and references: **nothing executed
# this script**, so the ownership logic — the part that decides whether a namespace is OURS to gate
# or the platform's to merely report — had ZERO behavioural coverage. An adversary had to build a
# throwaway fake-kubectl to review it at all; that harness is worth keeping rather than rebuilding.
#
# WHAT IT PINS
#   1. mode `istio`          -> a `mesh` row is judged OURS and GATES (rc=1 when under-labelled)
#   2. mode `istio-existing` -> the SAME row is informational, not gated (rc=0)
#   3. the counter agrees with the table (the F2 bug: `measured_ours` keyed on the `own` COLUMN while
#      gating keyed on the mode-derived `$ours`, so the gate judged two namespaces, then reported
#      "0 of them ours", then "measured NOTHING" — a verdict its own table disproved three lines up)
#   4. the wrong-mode diagnostic fires, and names the EFFECTIVE VALUE plus the fact that an env
#      override on the make line will NOT work (the remedy that actually unblocks an operator)
#
# WHY A FAKE kubectl AND NOT A CLUSTER: the branch is pure decision logic over four kubectl reads.
# A live run costs ~30 minutes and cannot be made to produce the platform-mesh shape on demand;
# a fake produces it in milliseconds and can be made to produce the OPPOSITE shape too, which is
# what makes the RED meaningful.
#
# WHAT IT DOES NOT PROVE: that a real cluster ever presents this shape (a platform `istio-system`
# measuring `baseline` while carrying no adequate label). That is `inferred` and settled only on a
# lab — see the handoff. This file proves the DECISION, not that the decision is ever reached.
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

BIN="$(mktemp -d)"; OUT="$(mktemp)"; trap 'rm -rf "$BIN" "$OUT"' EXIT
fail=0; ran=0

# A fake kubectl that presents ONE platform-owned mesh namespace: pods running, NO enforce label,
# and `restricted` refused (so psa_min_level resolves to baseline). Everything else is absent.
cat > "${BIN}/kubectl" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"config current-context"*) echo "fake-cluster"; exit 0 ;;
esac
# only istio-system exists
case "$args" in
  *"get namespace istio-system"*|*"get ns istio-system"*)
      case "$args" in *jsonpath*) printf '' ;; esac   # UNLABELLED
      exit 0 ;;
  *"get namespace"*|*"get ns "*) exit 1 ;;            # every other namespace is absent
esac
case "$args" in
  *"-n istio-system get pods"*) printf 'istiod-x 1/1 Running 0 1m\nistio-ingress-y 1/1 Running 0 1m\n'; exit 0 ;;
  *"get pods"*) exit 0 ;;
esac
# psa_min_level probes: restricted REFUSED, baseline accepted
case "$args" in
  *"label --dry-run=server"*enforce=restricted*)
      echo "Warning: existing pods in namespace \"istio-system\" violate PodSecurity \"restricted:latest\"" >&2
      exit 0 ;;
  *"label --dry-run=server"*) exit 0 ;;
esac
exit 0
FAKE
chmod +x "${BIN}/kubectl"

run_gate() { # <controller> [state-file] -> rc, output in $OUT
  PATH="${BIN}:$PATH" SKIP_DOTENV=1 INGRESS_CONTROLLER="$1" VKS_STATE_FILE="${2:-${BIN}/none}" \
    bash "${SCRIPT_DIR}/49-psa-check.sh" > "$OUT" 2>&1
}

case_is() { # <label> <controller> <want-rc: 0|nonzero> <grep-ERE or ""> [state-file]
  ran=$((ran + 1))
  local rc ok=1
  run_gate "$2" "${5:-}"; rc=$?
  if [ "$3" = 0 ]; then [ "$rc" -eq 0 ] && ok=0; else [ "$rc" -ne 0 ] && ok=0; fi
  if [ "$ok" -ne 0 ]; then
    printf 'FAIL  %s — rc=%s (wanted %s)\n' "$1" "$rc" "$3"; sed 's/^/        /' "$OUT"; fail=1; return
  fi
  if [ -n "${4:-}" ] && ! grep -qE "$4" "$OUT"; then
    printf 'FAIL  %s — rc ok but output did not match /%s/\n' "$1" "$4"; sed 's/^/        /' "$OUT"; fail=1; return
  fi
  printf 'ok    %s\n' "$1"
}

# NOTE ON THE MODE: 49-psa-check reads INGRESS_CONTROLLER AFTER load_env, and load_env's files beat
# the environment — which is exactly the trap this gate's diagnostic now explains. SKIP_DOTENV=1 and
# an absent VKS_STATE_FILE remove .env and .env.state; .env.example still supplies `istio`, so the
# istio-existing case must publish through a state file rather than the environment.
STATE="${BIN}/state.env"; printf 'INGRESS_CONTROLLER=istio-existing\n' > "$STATE"

case_is "istio mode: a mesh namespace is judged OURS and GATES" istio 1 'istio-system'
case_is "istio mode: the wrong-mode diagnostic names the EFFECTIVE value" istio 1 "resolved to 'istio'"
case_is "istio mode: it says an env override will NOT work (the actionable half)" istio 1 'will NOT work here'

# THE OTHER DIRECTION — without it, every assertion above could pass on a gate that ALWAYS gates.
# Driven through an UNSTAMPED state file, which load_env DOES source (see test-state-overlay case 2);
# the environment cannot carry it, which is the whole point of the diagnostic being tested.
case_is "istio-existing: the SAME row is informational, NOT gated" istio-existing 0 'platform-owned' "$STATE"
# NEGATIVE assertion, written inline because case_is only does POSITIVE matching: passing it an
# empty pattern makes its `[ -n "$4" ]` guard false, so NO check runs and the case silently
# duplicates the one above. That is the vacuous-case class this repo keeps meeting — caught here on
# review, before it could certify anything.
ran=$((ran + 1))
run_gate istio-existing "$STATE"
if grep -qE 'resolved to|will NOT work here' "$OUT"; then
  printf 'FAIL  istio-existing: the wrong-mode diagnostic FIRED when the mode was correct\n'
  sed 's/^/        /' "$OUT"; fail=1
else
  printf 'ok    istio-existing: the wrong-mode diagnostic is ABSENT (proven by a NEGATIVE match)\n'
fi

# F2 regression: the counter must agree with the table. In istio mode the mesh row IS ours, so the
# summary must NOT claim zero were ours while having just judged one.
run_gate istio
ran=$((ran + 1))
if grep -qE 'measured .*\(0 of them ours\)' "$OUT" && grep -qE '^\s+istio-system' "$OUT"; then
  printf 'FAIL  F2: the summary says "0 of them ours" while the table judged istio-system\n'
  sed 's/^/        /' "$OUT"; fail=1
else
  printf 'ok    F2: the counter agrees with the table (no "0 of them ours" over a judged row)\n'
fi

[ "$ran" -eq 6 ] || die "expected 6 cases, ran ${ran} — this harness lost track of itself"
[ "$fail" -eq 0 ] || { log_error "psa ownership: FAILED"; exit 1; }
log_info "psa ownership: OK — ${ran} cases (decision logic only; a real cluster presenting this shape is UNVERIFIED — see the handoff)"
