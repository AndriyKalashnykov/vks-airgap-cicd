#!/usr/bin/env bash
# ci-tier: fast — offline; throwaway doc copies under mktemp. No network, no cluster.
#
# test-vcenter-scenario-split.sh — RED-proofs for check-vcenter-scenario-split.sh (B536).
#
# WHY IT EXISTS. The gate underwrites a SENTENCE PRINTED TO AN OPERATOR by `make creds`:
#   "docs/scenario-2.md never asks for VCENTER_* , while docs/scenario-1.md does."
# A hand-run RED-proof expires at the next commit (gates.md), and this claim is the kind that rots
# silently — someone adds a vCenter step to scenario-2 and the note keeps asserting the opposite to
# the audience least able to notice it is wrong (RULE ZERO-B).
#
# ⚠️ IT OPERATES ON COPIES. The gate reads two real documents, so a test that mutated them in place
# would be one interrupted run away from leaving the repo's own docs edited.
# shellcheck disable=SC2016
#   The printf formats below contain BACKTICKS on purpose — they write markdown code spans into the
#   fixture docs, mimicking how the real documents mention `VCENTER_HOST`. Single quotes are
#   REQUIRED: double quotes would COMMAND-SUBSTITUTE the backticks, which is the exact trap this
#   repo records for `git commit -m` and `gh pr create --body`.
#   MUST sit above the first COMMAND: placed after `set -uo pipefail` it is silently inert.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

mkfix() {
  local T; T="$(mktemp -d /tmp/vcsplit.XXXX)"
  mkdir -p "$T/scripts" "$T/docs"
  cp -a "${SCRIPT_DIR}/lib" "$T/scripts/lib"
  cp "${SCRIPT_DIR}/check-vcenter-scenario-split.sh" "$T/scripts/"
  cp "${REPO}/docs/scenario-1.md" "${REPO}/docs/scenario-2.md" "$T/docs/"
  printf '%s' "$T"
}
run() { ( cd "$1" && REPO_ROOT="$1" bash scripts/check-vcenter-scenario-split.sh >"$1/.out" 2>&1 ); echo $?; }

# ── 1. the real documents -> GREEN, and it must SAY the split it measured ───────────────────────
T="$(mkfix)"; rc="$(run "$T")"
if [ "$rc" -eq 0 ] && grep -q 'scenario-2 does not' "$T/.out"; then ok "the real docs satisfy the split"
else bad "the real docs must be GREEN; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 2. scenario-2 GAINS a mention -> RED. This is the direction that makes the printed sentence
#      FALSE for the tenant, so it is the one that matters most.
T="$(mkfix)"; printf '\nSet `VCENTER_HOST` in .env.\n' >> "$T/docs/scenario-2.md"; rc="$(run "$T")"
if [ "$rc" -ne 0 ] && grep -q 'scenario-2.md mentions VCENTER' "$T/.out"; then ok "scenario-2 gains a mention -> RED, and names the file"
else bad "a VCENTER_* mention in scenario-2 must be RED; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 3. scenario-1 STOPS asking -> RED. The other half of the sentence. ──────────────────────────
T="$(mkfix)"
sed -i 's/VCENTER_HOST/VC_H/g; s/VCENTER_USERNAME/VC_U/g; s/VCENTER_PASSWORD/VC_P/g' "$T/docs/scenario-1.md"
rc="$(run "$T")"
if [ "$rc" -ne 0 ] && grep -q 'ZERO times' "$T/.out"; then ok "scenario-1 stops asking -> RED, and names the file"
else bad "scenario-1 losing every mention must be RED; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 4. A MISSING document -> RED naming the GATE. `grep -c` on an unreadable file prints 0 and
#      exits 2; without the existence check that would read as "scenario-2 mentions it 0 times",
#      i.e. a PASS on a repo whose docs are gone — a fail-open in the safe-looking direction.
T="$(mkfix)"; rm -f "$T/docs/scenario-2.md"; rc="$(run "$T")"
if [ "$rc" -ne 0 ] && grep -q 'not found' "$T/.out"; then ok "a missing document -> RED, and blames the GATE not the docs"
else bad "a missing document must be RED with a gate-blaming message; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 5. The gate must NOT pin the COUNT. Adding an unrelated VCENTER_* mention to scenario-1 (13 ->
#      14) is a legitimate doc edit; a count-pinning gate would go RED on it. This is the
#      enumerated-value rot the gate's header refuses.
T="$(mkfix)"; printf '\nAlso set `VCENTER_HOST` for the second vCenter.\n' >> "$T/docs/scenario-1.md"; rc="$(run "$T")"
if [ "$rc" -eq 0 ]; then ok "an EXTRA scenario-1 mention stays GREEN (the split is pinned, not the count)"
else bad "adding a scenario-1 mention must NOT be RED — the gate pins the split; rc=$rc"; fi; rm -rf "$T"

printf '\ntest-vcenter-scenario-split: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
