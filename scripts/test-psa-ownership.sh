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

# ISOLATION, asserted rather than assumed. SKIP_DOTENV=1 covers `.env` ONLY. The legacy `.env.kind`
# is sourced LAST by load_env and beats .env.example, .env AND the state file — measured: dropping
# `INGRESS_CONTROLLER=istio-existing` into it fails 4 of 6 cases. It is gitignored, so it never shows
# in `git status`, and older versions of this repo wrote it: a long-lived tree plausibly has one.
[ ! -f "${REPO_ROOT}/.env.kind" ] || die "legacy .env.kind is present — load_env sources it LAST, so it beats this harness's fixture and would produce a FALSE RED. Move it aside before running this test."

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
STATE_TR="${BIN}/state-traefik.env"; printf 'INGRESS_CONTROLLER=traefik\n' > "$STATE_TR"

case_is "istio mode: a mesh namespace is judged OURS and GATES" istio 1 'REJECTS these pods'
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
# POSITIVE CONTROL FIRST. A bare negative match passes when the gate produced NOTHING: replacing
# 49-psa-check.sh with `exit 127` made this case report ok. Demand the row exists before believing
# the absence of the diagnostic means anything.
if ! grep -q 'platform-owned' "$OUT"; then
  printf 'FAIL  istio-existing: the gate produced NO judged row — the negative match below would be vacuous\n'
  sed 's/^/        /' "$OUT"; fail=1
elif grep -qE 'resolved to|will NOT work here' "$OUT"; then
  printf 'FAIL  istio-existing: the wrong-mode diagnostic FIRED when the mode was correct\n'
  sed 's/^/        /' "$OUT"; fail=1
else
  printf 'ok    istio-existing: the wrong-mode diagnostic is ABSENT (proven by a NEGATIVE match)\n'
fi

# THE DISCRIMINATOR for case 2. Measured: hardcoding "'istio'" into the diagnostic instead of
# "${INGRESS_CONTROLLER:-istio}" passes 6/6, because in the only mode case 2 exercises the effective
# value IS "istio" — so that case cannot test the one property its label, and the eight-line comment
# block above the diagnostic, are entirely about. Driving a THIRD mode settles it.
case_is "the diagnostic prints the EFFECTIVE value, not a literal (traefik)" traefik 1 "resolved to 'traefik'" "$STATE_TR"

# THE HIGH FIX, PINNED. The diagnostic used to key on `own = mesh && ours = 1` with no test on the
# VERDICT, so in the default istio mode with mesh namespaces healthy and correctly labelled it
# printed six lines advising `istio-existing` over a gate that had just said PSA OK — advice which,
# followed, sets ours=0 for namespaces we DO own and silently UN-GATES them. A second fixture whose
# istio-system is correctly labelled `baseline` proves the guard: same mode, no finding, no advice.
cat > "${BIN}/kubectl" <<'HEALTHY'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"config current-context"*) echo "fake-cluster"; exit 0 ;;
  *"get namespace istio-system"*|*"get ns istio-system"*)
      case "$args" in *jsonpath*) printf 'baseline' ;; esac   # CORRECTLY LABELLED
      exit 0 ;;
  *"get namespace"*|*"get ns "*) exit 1 ;;
  *"-n istio-system get pods"*) printf 'istiod-x 1/1 Running 0 1m\n'; exit 0 ;;
  *"get pods"*) exit 0 ;;
  *"label --dry-run=server"*enforce=restricted*)
      echo "Warning: violates PodSecurity \"restricted:latest\"" >&2; exit 0 ;;
esac
exit 0
HEALTHY
chmod +x "${BIN}/kubectl"
ran=$((ran + 1))
run_gate istio
if ! grep -qE '^[[:space:]]+istio-system' "$OUT"; then
  printf 'FAIL  healthy-row guard: no istio-system row — the negative match would be vacuous\n'
  sed 's/^/        /' "$OUT"; fail=1
elif grep -qE 'resolved to|will NOT work here' "$OUT"; then
  printf 'FAIL  healthy-row guard: the diagnostic FIRED on a correctly-labelled row — its advice would UN-GATE a namespace we own\n'
  sed 's/^/        /' "$OUT"; fail=1
else
  printf 'ok    healthy-row guard: no advice attached to a non-finding\n'
fi

# F2 regression: the counter must agree with the table. In istio mode the mesh row IS ours, so the
# summary must NOT claim zero were ours while having just judged one.
run_gate istio
ran=$((ran + 1))
# Same positive control, and POSIX `[[:space:]]` not `\s` (a GNU extension that would silently
# never match under toybox/busybox, making this permanently vacuous).
if ! grep -qE '^[[:space:]]+istio-system' "$OUT"; then
  printf 'FAIL  F2: the gate produced no istio-system row — this counter check would be vacuous\n'
  sed 's/^/        /' "$OUT"; fail=1
elif grep -qE 'measured .*\(0 of them ours\)' "$OUT"; then
  printf 'FAIL  F2: the summary says "0 of them ours" while the table judged istio-system\n'
  sed 's/^/        /' "$OUT"; fail=1
else
  printf 'ok    F2: the counter agrees with the table (no "0 of them ours" over a judged row)\n'
fi

[ "$ran" -eq 8 ] || die "expected 8 cases, ran ${ran} — NOTE: this counts CASES RUN, not properties proven (it read 6/6 while one case was vacuous)"
[ "$fail" -eq 0 ] || { log_error "psa ownership: FAILED"; exit 1; }
log_info "psa ownership: OK — ${ran} cases (decision logic only; a real cluster presenting this shape is UNVERIFIED — see the handoff)"
