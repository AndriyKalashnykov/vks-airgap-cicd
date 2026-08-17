#!/usr/bin/env bash
# test-validate-counts.sh — pin how `validate.sh`'s kc() REPORTS its counts.
#
# WHY THIS EXISTS: the fix that stopped `skipped` resources being reported as "validated, all
# schemas resolvable" was RED-proven BY HAND in a commit message. An uncommitted RED-proof expires
# at the next commit touching the gate or its toolchain — and this gate's behaviour is pinned to
# kubeconform's `.summary` schema (v0.8.0 at time of writing), so a rename there would silently
# revert the fix with every gate still green at the same count.
#
# HERMETIC BY CONSTRUCTION: a stub `kubeconform` on PATH emits a FIXED summary, so no network, no
# CDN, no cache. That matters beyond convenience — an adversary round measured that the obvious
# live-network proof CANNOT establish this: with `KUBECONFORM_SCHEMA_K8S/_CRD` pointed at an empty
# dir, four directories still validated via `-schema-location default` (githubusercontent), which no
# env var overrides. Blackhole the network and all eight move to the errors path instead. So the
# per-dir split under a live network is a NETWORK-STATE observation, not a property of the code.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

# run_with VALID INVALID ERRORS SKIPPED [env assignments...] -> writes $OUT, sets $RC
#
# ⚠️ kc() reads its counts from TWO DIFFERENT PLACES: `invalid` and `errors` are counted from
# `.resources[]?` by status, while `valid`/`skipped`/`total` come from `.summary`. So a stub that
# emits `"resources":[]` reports invalid=0 and errors=0 NO MATTER WHAT the summary says. My first
# version of this harness did exactly that, and case 3 — the positive control — is what caught it:
# `invalid:1` in the summary produced rc=0 because kc() never saw a statusInvalid resource. The stub
# must therefore SYNTHESISE resource entries to match the counts, which is the whole reason case 3
# exists and must never be deleted.
run_with() {
  local v="$1" inv="$2" err="$3" skp="$4"; shift 4
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin"
  local res
  res="$(python3 - "$v" "$inv" "$err" "$skp" <<'PY'
import json, sys
v, inv, err, skp = (int(x) for x in sys.argv[1:5])
r  = [{"filename": "f.yaml", "kind": "Service", "status": "statusValid"}   for _ in range(v)]
r += [{"filename": "f.yaml", "kind": "Service", "status": "statusInvalid", "msg": "synthetic"} for _ in range(inv)]
r += [{"filename": "f.yaml", "kind": "Widget",  "status": "statusError",   "msg": "synthetic"} for _ in range(err)]
r += [{"filename": "f.yaml", "kind": "Widget",  "status": "statusSkipped"} for _ in range(skp)]
print(json.dumps({"resources": r,
                  "summary": {"valid": v, "invalid": inv, "errors": err, "skipped": skp}}))
PY
)"
  { printf '#!/usr/bin/env bash\n'
    printf 'cat <<%s\n%s\n%s\n' "'EOJ'" "$res" "EOJ"
  } > "$d/bin/kubeconform"
  chmod 0755 "$d/bin/kubeconform"
  OUT="$(env PATH="$d/bin:$PATH" "$@" bash scripts/validate.sh 2>&1)"; RC=$?
  rm -rf "$d"
}

echo "== validate.sh count-reporting contract =="

# 1. THE FIXED DEFECT. skipped>0 must never be reported as validated-and-resolvable.
run_with 6 0 0 10
if printf '%s' "$OUT" | grep -qE 'all schemas resolvable \(Invalid=0\)$'; then
  bad "skipped>0 must not print the OLD over-claim" "found 'all schemas resolvable (Invalid=0)'"
else ok "skipped>0 does not print the OLD over-claim"; fi
if printf '%s' "$OUT" | grep -qF 'skipped (NO SCHEMA - not checked)'; then
  ok "skipped>0 prints the honest count"
else bad "skipped>0 must print the honest count" "no 'skipped (NO SCHEMA - not checked)' line"; fi

# 2. A clean run must still make the clean claim — a fix that silences the good case is a regression.
run_with 4 0 0 0
if printf '%s' "$OUT" | grep -qF 'Invalid=0, Skipped=0'; then
  ok "skipped==0 still prints the clean claim"
else bad "skipped==0 must still print the clean claim" "no 'Invalid=0, Skipped=0'"; fi

# 3. POSITIVE CONTROL for the harness itself: invalid>0 must FAIL. Without this, every assertion
#    above could be passing because the stub is broken and kc() never ran at all.
run_with 1 1 0 0
if [ "$RC" -ne 0 ]; then ok "invalid>0 fails the gate (rc=$RC) — the harness reaches kc()"
else bad "invalid>0 must fail the gate" "rc=0; the stub or the invocation is not reaching kc()"; fi

# 4. THE KNOWN GAP, pinned deliberately so closing it is a CHOICE and not an accident.
#    An ALL-SKIPPED dir passes even under KUBECONFORM_REQUIRE_SCHEMAS=1, because the zero-examined
#    guard tests `total`, which FOLDS skipped. Asserting today's behaviour means a future fix that
#    changes it turns THIS case red and the author must come here and decide.
run_with 0 0 0 5 KUBECONFORM_REQUIRE_SCHEMAS=1
if [ "$RC" -eq 0 ]; then
  ok "KNOWN GAP pinned: all-skipped passes under REQUIRE_SCHEMAS=1 (rc=0) — see B156/#88"
else
  bad "the all-skipped gap appears CLOSED (rc=$RC)" \
      "if that was intentional, update this case and the disclosure comment at the zero-examined guard"
fi
# and the disclosure must be present, so a reader of the guard is not misled by its own prose
if grep -qF 'CANNOT SEE AN ALL-SKIPPED DIRECTORY' scripts/validate.sh; then
  ok "the zero-examined guard carries its own limitation in a comment"
else bad "the guard's limitation is undisclosed" "expected the CANNOT SEE AN ALL-SKIPPED note"; fi

# 5. errors>0 must not let the reader infer total-minus-errors was verified.
run_with 1 0 2 3
if printf '%s' "$OUT" | grep -qF 'skipped with NO SCHEMA'; then
  ok "errors>0 also discloses the skipped count"
else bad "errors>0 must disclose skipped too" "a reader would infer total-errors were validated"; fi

printf '\n== %s passed, %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
