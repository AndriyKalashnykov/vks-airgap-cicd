#!/usr/bin/env bash
# SC2030/SC2031: every case deliberately scopes its stub PATH to a subshell so one case's fake
# kubectl/helm cannot leak into the next. "That change might be lost" IS the intended design here.
# shellcheck disable=SC2030,SC2031
# test-capacity.sh — RED-proof for capacity_assert_fits / capacity_mi / capacity_chart_request.
#
# WHY THIS EXISTS. Two adversary rounds refuted the first version of capacity.sh and converged on
# ONE defect: with ZERO candidate nodes the probe prints "0 0 0 0" — rc 0, non-empty output — which
# walked past every fail-open guard and HARD-DIED with "roomiest has 0Mi", telling the operator to
# free memory that was not the problem. It is reachable two ways, and cases 5 and 6 below pin both:
#   - a kubeconfig that cannot LIST NODES (kubectl emits a valid empty List on stdout WITH rc=1) —
#     the tenant shape, and this repo's DEFAULT posture (RULE ZERO-B);
#   - with NO RBAC assumption at all, a cluster whose only node carries a NoSchedule taint.
# The KinD e2e cannot exercise either (kind's control plane is untainted), so without this file the
# class would first appear on the real lab.
#
# Every case is OFFLINE by construction: kubectl/helm/yq/python3 are STUBS on PATH where a case
# needs them, so this needs no cluster and cannot be flaky.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }
# shellcheck source=scripts/lib/os.sh
. "$SCRIPT_DIR/lib/os.sh" 2>/dev/null
# shellcheck source=scripts/lib/capacity.sh
. "$SCRIPT_DIR/lib/capacity.sh"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); return 0; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); return 0; }
# chk <rc> <ok-msg> <fail-msg> -- an explicit if/else. `cond && ok || bad` runs BOTH when ok()
# returns non-zero, which is the shape this repo's rules forbid for any pass/fail decision, and a
# test harness IS a gate.
chk() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$3"; fi; }
# has <text> <pattern> -- rc 0 iff present. Keeps the greps out of the && chains above.
has() { printf '%s' "$1" | grep -q "$2"; }

STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
mk() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$STUB/$1"; chmod +x "$STUB/$1"; }

# A node/pod document with parameterised nodes. `alloc` is Ki, matching what a real API server emits.
doc() { # doc <n-nodes> <alloc-Mi> <taint-json> <pod-req-Mi>
  python3 - "$@" <<'PY'
import json,sys
n,alloc,taint,req = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
items=[]
for i in range(n):
    spec = {"taints": json.loads(taint)} if taint != "none" else {}
    items.append({"kind":"Node","metadata":{"name":f"node{i}"},"spec":spec,
                  "status":{"allocatable":{"memory":f"{alloc*1024}Ki"},
                            "conditions":[{"type":"Ready","status":"True"}]}})
    if req:
        items.append({"kind":"Pod","metadata":{"name":f"p{i}"},"spec":{"nodeName":f"node{i}",
                      "containers":[{"resources":{"requests":{"memory":f"{req}Mi"}}}]},
                      "status":{"phase":"Running"}})
print(json.dumps({"items":items}))
PY
}

run_fits() { # run_fits <quantity> ; echoes rc, output on stderr captured by the caller
  ( PATH="$STUB:$PATH"; capacity_assert_fits "$1" thing "do the thing" ) 2>&1; return $?
}

# ── 1. a genuinely full cluster MUST die (the gate's reason to exist) ─────────────────────────
mk kubectl "$(printf 'exec cat %q' "$STUB/full.json")"
doc 2 2833 none 2700 > "$STUB/full.json"
out="$(run_fits 768Mi)"; rc=$?
if [ "$rc" -ne 0 ] && has "$out" 'short'; then ok "a full cluster DIES and names the shortfall"
else bad "a full cluster did not die (rc=$rc): $out"; fi

# ── 2. a roomy cluster MUST pass, and say memory ──────────────────────────────────────────────
doc 2 2833 none 100 > "$STUB/full.json"
out="$(run_fits 768Mi)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'memory margin'; then ok "a roomy cluster PASSES and reports a memory margin"
else bad "a roomy cluster did not pass cleanly (rc=$rc): $out"; fi

# ── 3a. python3 ABSENT -> SKIP (a bare Photon jump box has none). A thin stub PATH is not enough:
#       os.sh needs real tools, so build a COMPLETE PATH minus python3.
NOPY="$STUB/nopy"; mkdir -p "$NOPY"
for f in /usr/bin/* /bin/*; do b="$(basename "$f")"; case "$b" in python3*|python) continue;; esac
  ln -sf "$f" "$NOPY/$b" 2>/dev/null; done
ln -sf "$STUB/kubectl" "$NOPY/kubectl" 2>/dev/null
out="$( PATH="$NOPY"; capacity_assert_fits 768Mi thing 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'SKIPPED (not a pass)'; then ok "python3 ABSENT -> SKIPPED, caller survives"
else bad "python3 absent killed the caller (rc=$rc): $out"; fi

# ── 3b. python3 PRESENT BUT BROKEN -> also SKIP. `command -v` tests PRESENCE, not capability, and
#       a parser failure says nothing about the quantity, so it must not be reported as a bad value.
mk python3 'exit 127'
out="$(run_fits 768Mi)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'parser is unusable'; then ok "python3 present-but-BROKEN -> SKIPPED, not reported as a bad quantity"
else bad "broken python3 killed the caller or misnamed the cause (rc=$rc): $out"; fi
rm -f "$STUB/python3"

# ── 4. unreachable cluster -> SKIP, caller survives ───────────────────────────────────────────
mk kubectl 'exit 1'
out="$(run_fits 768Mi)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'could not read the cluster'; then ok "unreachable cluster -> SKIPPED, caller survives"
else bad "unreachable cluster killed the caller (rc=$rc)"; fi

# ── 5. THE TENANT SHAPE: nodes Forbidden -> a VALID empty List on stdout, rc=1 ─────────────────
#      This is the CRITICAL. It must SKIP and must NOT blame memory.
mk kubectl 'printf "%s" "{\"items\":[]}"; exit 1'
out="$(run_fits 768Mi)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'cannot list nodes'; then
  ok "nodes-Forbidden -> SKIPPED and named as RBAC, not memory"
else
  bad "nodes-Forbidden did not skip/misnamed the cause (rc=$rc): $out"
fi
if printf '%s' "$out" | grep -qiE 'free memory|short'; then bad "nodes-Forbidden STILL advises freeing memory"
else ok "nodes-Forbidden does NOT advise freeing memory"; fi

# ── 6. NO RBAC ASSUMPTION: every node tainted, 8000Mi free -> must SKIP, not die ───────────────
mk kubectl "$(printf 'exec cat %q' "$STUB/full.json")"
doc 1 8000 '[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"}]' 0 > "$STUB/full.json"
out="$(run_fits 768Mi)"; rc=$?
if [ "$rc" -eq 0 ] && has "$out" 'ALL excluded'; then ok "all-nodes-tainted (8000Mi free) -> SKIPPED, not a capacity failure"
else bad "all-nodes-tainted died or misreported (rc=$rc): $out"; fi

# ── 7. quantity parsing: legal forms accepted, a BARE integer refused as a bytes typo ──────────
for q in 768Mi 1Gi 2.5Gi 512Ki 100M; do
  if ( capacity_mi "$q" ) >/dev/null 2>&1; then ok "capacity_mi accepts $q"; else bad "capacity_mi REFUSED the legal quantity $q"; fi
done
for q in 768 beeg ''; do
  if ( capacity_mi "$q" ) >/dev/null 2>&1; then bad "capacity_mi accepted '$q' (a bare int is BYTES)"; else ok "capacity_mi refuses '${q:-<empty>}'"; fi
done

# ── 8. capacity_chart_request: never a PARTIAL maximum ─────────────────────────────────────────
#      A render whose SECOND record is unparseable must yield NOTHING, not the first record's
#      total -- that would be a false GREEN produced by the check itself.
mk helm 'echo rendered'
mk yq 'printf "100Mi\nbeeg\n5000Mi\n"'
outq="$( PATH="$STUB:$PATH"; capacity_chart_request /x 1 2>/dev/null )"
if [ -z "$outq" ]; then ok "a partially-unparseable render yields NOTHING (no partial maximum)"; else bad "partial render returned '$outq' — a false GREEN"; fi
mk yq 'printf "128Mi\n\n256Mi\n"'
outq="$( PATH="$STUB:$PATH"; capacity_chart_request /x 1 2>/dev/null )"
if [ "$outq" = "256Mi" ]; then ok "a good render returns the MAX across Deployments (256Mi)"; else bad "good render returned '$outq', want 256Mi"; fi
# yq must READ STDIN like the real one, or it keeps emitting after helm fails and the case
# measures the stub instead of the product (it did, and reported a false FAIL).
mk yq 'read -r _ || exit 0; printf "128Mi\n"'
mk helm 'exit 1'
outq="$( PATH="$STUB:$PATH"; capacity_chart_request /x 1 2>/dev/null )"
if [ -z "$outq" ]; then ok "a failed render yields NOTHING (never 0Mi, which always fits)"; else bad "failed render returned '$outq'"; fi

# ── 9. the fail-open must not depend on CALL POSITION ──────────────────────────────────────────
#      A plain assignment under set -e must survive a helm failure, not just a $( ) argument.
( set -euo pipefail; PATH="$STUB:$PATH"
  # shellcheck source=scripts/lib/os.sh
  . "$SCRIPT_DIR/lib/os.sh" 2>/dev/null
  # shellcheck source=scripts/lib/capacity.sh
  . "$SCRIPT_DIR/lib/capacity.sh"
  v="$(capacity_chart_request /x 1)"; printf 'SURVIVED %s' "${v:-<empty>}" ) >/dev/null 2>&1; rc=$?
chk "$rc" "a plain assignment under set -e survives a failed render" "a plain assignment under set -e was KILLED by a failed render"

# ── 10. the escape hatch escapes EVERYTHING, including quantity validation ─────────────────────
( CAPACITY_PREFLIGHT=0 capacity_assert_fits 'beeg' thing ) >/dev/null 2>&1; rc=$?
chk "$rc" "CAPACITY_PREFLIGHT=0 skips even an invalid quantity" "CAPACITY_PREFLIGHT=0 did not escape the quantity check"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
