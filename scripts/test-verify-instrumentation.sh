#!/usr/bin/env bash
# scripts/test-verify-instrumentation.sh — the two diagnostics 99-verify.sh emits must actually say
# something, and must say the RIGHT thing.
#
# WHY THIS EXISTS. Both are pure-diagnostic changes, so a green `static-check` says nothing about
# them: the denominator would not move, and by this repo's own rule an unchanged denominator means
# the gate is BLIND to the change. These are the two properties that can rot silently:
#
#   1. The ArgoCD nudge's failure must be REPORTED. It used to be `>/dev/null 2>&1 || true`, and
#      that silence is what left a 136-314s stall unattributed for weeks. The message must also
#      name the RBAC cause lib/argocd.sh:645 measured, not guess at a kubeconfig fault.
#   2. The TaskRun timing block must print a COUNT even when it finds nothing, because silence has
#      five indistinguishable causes and would reproduce the exact defect it exists to fix.
#
# Driven through the REAL function with a stubbed kubectl on PATH — never by re-implementing the
# logic, which is how a test comes to agree with a bug.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# A kubectl that FAILS the annotate (Forbidden — the measured scenario-2 shape) and returns no
# TaskRuns, so both diagnostics are exercised on their unhappy paths.
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "annotate" ]; then
    echo 'Error from server (Forbidden): applications.argoproj.io "x" is forbidden' >&2
    exit 1
  fi
done
exit 0
STUB
chmod +x "$TMP/bin/kubectl"

src="$(sed -n '/---- ArgoCD: force the write-back/,/ArgoCD did not converge/p' "${REPO_ROOT}/scripts/99-verify.sh")"
[ -n "$src" ] || { echo "  FAIL  could not locate the ArgoCD block in 99-verify.sh"; exit 1; }

# 1. the nudge's failure is reported, names the classification, and quotes kubectl
out="$(
  PATH="$TMP/bin:$PATH" bash -c '
    set -uo pipefail
    . "'"${REPO_ROOT}"'/scripts/lib/os.sh" >/dev/null 2>&1 || true
    app=demo
    ARGOCD_NAMESPACE=argocd
    KUBECONFIG='"$TMP"'/kc
    pr=pipelinerun.tekton.dev/demo-ci-abcde
    CI_NAMESPACE=ci
    sel="tekton.dev/pipeline=demo-ci"
    '"$src"'
  ' 2>&1 || true
)"
if grep -q 'refresh nudge FAILED' <<<"$out"; then ok "a failed ArgoCD nudge is REPORTED, not swallowed"
else bad "the failed nudge produced no warning — this is the silence the change removes"; fi
if grep -qi 'forbidden' <<<"$out"; then ok "kubectl's own words are quoted"; else bad "kubectl's stderr was not shown"; fi
if grep -qi 'RBAC' <<<"$out"; then ok "names the RBAC cause (lib/argocd.sh:645), not a kubeconfig guess"
else bad "does not name the measured RBAC cause"; fi

# 2. the timing block prints a COUNT even with zero TaskRuns
tsrc="$(sed -n '/---- INSTRUMENT: split scheduling/,/---- ArgoCD: force the write-back/p' "${REPO_ROOT}/scripts/99-verify.sh")"
tout="$(
  PATH="$TMP/bin:$PATH" bash -c '
    set -uo pipefail
    . "'"${REPO_ROOT}"'/scripts/lib/os.sh" >/dev/null 2>&1 || true
    app=demo
    CI_NAMESPACE=ci
    pr=pipelinerun.tekton.dev/demo-ci-abcde
    '"$tsrc"'
  ' 2>&1 || true
)"
if grep -qE 'timing\[demo\].*TaskRun\(s\)' <<<"$tout"; then ok "prints a COUNT even when it finds nothing"
else bad "printed nothing — silence has five causes and reproduces the defect it fixes"; fi
if grep -q 'demo-ci-abcde' <<<"$tout"; then ok "names THIS PipelineRun (run-scoped, not pipeline-scoped)"
else bad "does not name the specific PipelineRun"; fi

if [ "$fail" -eq 0 ]; then echo "test-verify-instrumentation: OK"; else echo "test-verify-instrumentation: FAILED"; exit 1; fi
