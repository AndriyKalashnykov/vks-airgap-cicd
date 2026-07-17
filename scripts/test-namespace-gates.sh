#!/usr/bin/env bash
# test-namespace-gates.sh — offline RED-proofs that the two shipped namespace/inject GATES actually
# catch the regression they exist for, plus unit tests of psa.sh's branches. (Backlog B30c.)
#
# WHY THIS SHAPE, AND WHY IT IS NOT THE REFUTED B37 `make red-prove`:
#   The FIRST test of this class (reverted) was BLIND — it RED-proved by mutating the HELPER
#   (`psa.sh`'s labelling branch), which was never broken; the real bug was a MISSING CALL at an
#   installer call site. So this test mutates the CALL / the pod-LABEL (the real regression), never
#   the helper. It is NOT flip-detection: there is no baseline↔current comparison and nothing is
#   "transplanted". It is a plain mutation test — "break the real invariant in a throwaway git repo,
#   assert the gate FAILS with its OWN signature; run it unmodified, assert it PASSES."
#
#   `rc≠0` is NEVER sufficient: THREE of check-pod-inject-label's exit-1 branches print a path
#   containing "gitea" (line 126's `die "…parsed 0 workloads… k8s/gitea/gitea.yaml…"`, the PARSE
#   branch, and the parser-`die`), so `rc≠0 && grep gitea` is a false-RED that proves nothing — the
#   exact blindness that reverted the prior test. Every RED assertion therefore POSITIVE-matches the
#   intended branch's signature AND NEGATIVE-matches the accident signatures.
#
#   A THROWAWAY `git init` repo (the repo's own precedent, test-adversary-gate-rearm.sh), NOT a
#   `git worktree`: worktrees share `.git/worktrees/` (a prune-race across concurrent `make
#   test-scripts` runs) and are blocked by the subagent read-only hook. `git ls-files` reads the
#   INDEX and `open()` reads the working tree, so an edit made AFTER `git add` is visible to
#   check-pod-inject-label with no commit and no git identity needed.
#
# shellcheck disable=SC2016  # grep/sed patterns contain a literal `$VAR` — the $ must stay literal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# ---- a throwaway git repo mirroring the trees the two gates read -----------------------------------
TMP="$(mktemp -d)" || die "mktemp -d failed"
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then die "mktemp -d produced no dir — refusing to run (a blank \$TMP would make cp/rm target /)"; fi
trap 'rm -rf "$TMP"' EXIT
cp -a "${REPO_ROOT}/scripts" "${REPO_ROOT}/k8s" "${REPO_ROOT}/deploy" \
      "${REPO_ROOT}/apps" "${REPO_ROOT}/.env.example" "$TMP"/
git -C "$TMP" init -q
git -C "$TMP" add -A    # index only; git ls-files needs this, open() reads the (later-mutated) tree

# run a gate against $TMP; combined output → $TMP/gate.out, returns rc.
# REPO_ROOT MUST be pinned to $TMP: os.sh EXPORTS REPO_ROOT (os.sh:31), so the value this test set
# when it sourced os.sh leaks into the gate child, whose `if [ -z REPO_ROOT ]` guard then skips
# recompute and the gate silently scans the REAL (unmutated) tree — always green. That makes the
# positive control vacuous AND makes each RED-proof FALSE-RED (the gate stays green on the mutated
# $TMP, so the `rc != 0` assertion fails and the test fails loudly — not a silent false-green, but
# still wrong). Pinning it forces the gate onto the throwaway copy.
run_gate() { ( cd "$TMP" && REPO_ROOT="$TMP" bash "scripts/$1" ) >"$TMP/gate.out" 2>&1; }
restore()  { cp -a "${REPO_ROOT}/$1" "$TMP/$1"; }   # re-pristine one file from the real tree

# ===== POSITIVE CONTROLS (B39 known-answer) — the gates MUST be GREEN on the unmodified tree, or the
#       HARNESS (a non-git dir, an empty ls-files, a wrong REPO_ROOT), not the gate, is broken, and
#       every RED below would be meaningless. A hard ERROR, distinct from a FAIL.
run_gate check-namespace-labelled.sh || { cat "$TMP/gate.out" >&2; die "positive control FAILED: check-namespace-labelled is RED on the unmodified tree — the harness is broken, not the gate"; }
ok "positive control: check-namespace-labelled GREEN on the unmodified tree"
run_gate check-pod-inject-label.sh   || { cat "$TMP/gate.out" >&2; die "positive control FAILED: check-pod-inject-label is RED on the unmodified tree — the harness is broken, not the gate"; }
ok "positive control: check-pod-inject-label GREEN on the unmodified tree"

# ===== RED 1 — delete the GITEA `ensure_namespace` CALL from the installer `install-all` reaches.
#   The call ALSO lives in lib/istio.sh (reached only by install-ingress), so deleting ONLY the
#   40-install-gitea.sh copy reproduces the exact B29/F2 bug AND discriminates the gate's SCOPED grep
#   from a repo-wide one — a repo-wide grep would find the surviving lib/istio.sh call and stay green.
gf="scripts/40-install-gitea.sh"
n0=$(grep -c 'ensure_namespace "\$GITEA_NAMESPACE"' "$TMP/$gf")
sed -i '/ensure_namespace "\$GITEA_NAMESPACE"/d' "$TMP/$gf"
n1=$(grep -c 'ensure_namespace "\$GITEA_NAMESPACE"' "$TMP/$gf")
disc=$(grep -c 'ensure_namespace "\$GITEA_NAMESPACE"' "$TMP/scripts/lib/istio.sh")
if [ "$n0" -eq 1 ] && [ "$n1" -eq 0 ] && [ -s "$TMP/$gf" ] && [ "$disc" -ge 1 ]; then
  ok "mutation landed: GITEA call removed from 40-install-gitea.sh (survives in lib/istio.sh — scoped-grep discriminator holds)"
else
  bad "GITEA mutation did NOT land as intended (n0=$n0 n1=$n1 file-nonempty? disc=$disc) — the RED below proves nothing"
fi
run_gate check-namespace-labelled.sh; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -q 'reach no ensure_namespace call' "$TMP/gate.out" \
   && grep -qi 'GITEA' "$TMP/gate.out" \
   && ! grep -qE 'NS_SPEC drift|could not read NS_SPEC|checked 0 namespaces' "$TMP/gate.out"; then
  ok "RED: check-namespace-labelled reddens with its real signature when the GITEA call is deleted"
else
  bad "check-namespace-labelled did NOT redden correctly on the deleted GITEA call (rc=$rc): $(head -1 "$TMP/gate.out")"
fi
restore "$gf"

# ===== RED 2 — a SECOND owned namespace in a DIFFERENT installer (per-map coverage): the TEKTON row.
#   Same both-places property (the call also lives in lib/istio.sh), same discriminator.
tf="scripts/41-install-tekton.sh"
m0=$(grep -c 'ensure_namespace "\${TEKTON_NAMESPACE' "$TMP/$tf")
sed -i '/ensure_namespace "\${TEKTON_NAMESPACE/d' "$TMP/$tf"
m1=$(grep -c 'ensure_namespace "\${TEKTON_NAMESPACE' "$TMP/$tf")
tdisc=$(grep -c 'ensure_namespace "\$TEKTON_NAMESPACE"' "$TMP/scripts/lib/istio.sh")
if [ "$m0" -eq 1 ] && [ "$m1" -eq 0 ] && [ -s "$TMP/$tf" ] && [ "$tdisc" -ge 1 ]; then
  ok "mutation landed: TEKTON call removed from 41-install-tekton.sh (survives in lib/istio.sh)"
else
  bad "TEKTON mutation did NOT land as intended (m0=$m0 m1=$m1 tdisc=$tdisc)"
fi
run_gate check-namespace-labelled.sh; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -q 'reach no ensure_namespace call' "$TMP/gate.out" \
   && grep -qi 'TEKTON' "$TMP/gate.out" \
   && ! grep -qE 'NS_SPEC drift|could not read NS_SPEC|checked 0 namespaces' "$TMP/gate.out"; then
  ok "RED: check-namespace-labelled reddens when the TEKTON call is deleted (second installer)"
else
  bad "check-namespace-labelled did NOT redden correctly on the deleted TEKTON call (rc=$rc): $(head -1 "$TMP/gate.out")"
fi
restore "$tf"

# ===== RED 3 — delete the gitea pod-template inject LABEL; the gate must redden with its LABEL
#   signature, NOT a parser/empty-ls-files accident (the F1 false-RED this whole test guards against).
yf="k8s/gitea/gitea.yaml"
l0=$(grep -c 'sidecar.istio.io/inject: "false"' "$TMP/$yf")
sed -i '/sidecar.istio.io\/inject: "false"/d' "$TMP/$yf"
l1=$(grep -c 'sidecar.istio.io/inject: "false"' "$TMP/$yf")
if [ "$l0" -eq 1 ] && [ "$l1" -eq 0 ] && [ -s "$TMP/$yf" ] \
   && python3 -c 'import sys,yaml;list(yaml.safe_load_all(open(sys.argv[1])))' "$TMP/$yf" 2>/dev/null; then
  ok "mutation landed: gitea inject label removed and the YAML still parses"
else
  bad "gitea label mutation did NOT land / broke the YAML (l0=$l0 l1=$l1) — a PARSE error would be a false-RED"
fi
run_gate check-pod-inject-label.sh; rc=$?
if [ "$rc" -ne 0 ] \
   && grep -q 'do not decline sidecar injection' "$TMP/gate.out" \
   && grep -q 'no sidecar.istio.io/inject' "$TMP/gate.out" \
   && ! grep -qE 'parser failed|parsed 0 workloads|^PARSE' "$TMP/gate.out"; then
  ok "RED: check-pod-inject-label reddens with its LABEL signature when the gitea inject label is deleted"
else
  bad "check-pod-inject-label did NOT redden correctly on the deleted label (rc=$rc): $(head -1 "$TMP/gate.out")"
fi
restore "$yf"

# ===== Part B — psa.sh branch unit tests via DRY_RUN=1 (run() echoes `DRY_RUN <cmd>` to stderr).
export DRY_RUN=1
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"

# invalid level -> die (subshell so the exit does not kill this test)
if ( psa_label_namespace testns bogus ) >"$TMP/b.log" 2>&1; then
  bad "psa_label_namespace accepted an invalid level 'bogus' (it must die)"
elif grep -q 'must be restricted' "$TMP/b.log"; then
  ok "psa_label_namespace dies on an invalid level"
else
  bad "psa_label_namespace failed on 'bogus' but without the expected die message"
fi

# none -> no-op, no label
o=$(psa_label_namespace testns none 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'kubectl label' <<<"$o"; then ok "psa: level=none is a no-op (no kubectl label)"; else bad "psa: level=none emitted a label or failed (rc=$rc)"; fi

# empty -> no-op, no label
o=$(psa_label_namespace testns "" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'kubectl label' <<<"$o"; then ok "psa: empty level is a no-op"; else bad "psa: empty level emitted a label or failed (rc=$rc)"; fi

# baseline -> enforce + audit + warn, all = baseline
o=$(psa_label_namespace testns baseline 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'enforce=baseline' <<<"$o" && grep -q 'audit=baseline' <<<"$o" && grep -q 'warn=baseline' <<<"$o"; then
  ok "psa: baseline sets enforce+audit+warn=baseline"
else
  bad "psa: baseline did not set all three labels (rc=$rc)"
fi

# ensure_namespace ns "" -> create + istio-injection=disabled, but NO pod-security label
o=$(ensure_namespace testns "" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'create namespace' <<<"$o" && grep -q 'istio-injection=disabled' <<<"$o" && ! grep -q 'pod-security' <<<"$o"; then
  ok "ensure_namespace (empty level): creates ns + istio-injection=disabled, no PSA label"
else
  bad "ensure_namespace empty-level behaviour wrong (rc=$rc)"
fi

# ---- verdict: a FAIL beats everything; only a clean run is OK ---------------------------------------
if [ "$fail" -ne 0 ]; then
  log_error "test-namespace-gates: FAILED"
  exit 1
fi
log_info "test-namespace-gates: OK — both gates RED-proven (GITEA + TEKTON call, gitea inject label) + psa branches"
