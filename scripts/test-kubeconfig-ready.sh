#!/usr/bin/env bash
# test-kubeconfig-ready.sh — the B32 residual. kubeconfig_ready must gate on the FILE existing (C13),
# not merely on the var being set (which load_env always makes true); and the read-only preflight
# ACCUMULATORS (23,49), the CREATOR (30-vks-login), and the different-file checker (71) must NOT call
# it — a die in those paths is a behavior regression the idea-round explicitly excluded.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

echo "== kubeconfig_ready: GREEN when the file exists, RED (die) when set-but-absent =="
# GREEN — an existing kubeconfig passes.
f="$(mktemp)"
if ( KUBECONFIG="$f"; kubeconfig_ready ) >/dev/null 2>&1; then ok "existing kubeconfig -> rc 0"; else bad "an existing kubeconfig must pass"; fi
rm -f "$f"

# RED — set but the file is absent -> die, and the message names how to produce it.
out="$( ( KUBECONFIG="/nonexistent/kc-$$"; kubeconfig_ready ) 2>&1 )"; grc=$?
if [ "$grc" -ne 0 ] && printf '%s' "$out" | grep -q 'does not exist' && printf '%s' "$out" | grep -q 'vks-login'; then
  ok "missing kubeconfig -> die with the produce-it-first message"
else
  bad "missing kubeconfig must die with the fix message (rc=$grc): $out"
fi

# RED CONTROL — the OLD bare `: "${KUBECONFIG:?}"` (what these sites had) PASSES the same missing-file
# input. That vacuity IS the C13 bug kubeconfig_ready fixes; if this control stops firing the test is
# measuring nothing.
if ( KUBECONFIG="/nonexistent/kc-$$"; : "${KUBECONFIG:?}" ) >/dev/null 2>&1; then
  ok "RED control: the OLD bare :? PASSES a missing file (the C13 gap kubeconfig_ready closes)"
else
  bad "RED control: the old bare :? unexpectedly failed — the test premise is wrong"
fi

# A path WITH SPACES must produce a clean die, not a glob/word-split error.
out2="$( ( KUBECONFIG="/no such dir/kc file"; kubeconfig_ready ) 2>&1 )"; grc2=$?
if [ "$grc2" -ne 0 ] && printf '%s' "$out2" | grep -q 'does not exist'; then ok "a space-containing missing path -> clean die"; else bad "space-path not handled cleanly (rc=$grc2): $out2"; fi

# A colon-MERGED KUBECONFIG (kubectl merges multiple files) must NOT die — `[ -f ]` on the whole string
# is meaningless, so it is deferred to kubectl even when the components do not exist here.
if ( KUBECONFIG="/nonexistent-a-$$:/nonexistent-b-$$"; kubeconfig_ready ) >/dev/null 2>&1; then
  ok "a colon-merged KUBECONFIG passes (deferred to kubectl, no spurious die)"
else
  bad "a colon-merged KUBECONFIG must NOT die (it is a valid kubectl multi-file config)"
fi

echo "== wiring: the 6 consumers CALL kubeconfig_ready; excluded sites DO NOT =="
for s in 40-install-gitea 41-install-tekton 50-seed-gitea-repos 60-configure-tekton 70-configure-argocd 99-verify; do
  if grep -qE '^[[:space:]]*kubeconfig_ready[[:space:]]*$' "${SCRIPT_DIR}/${s}.sh"; then ok "${s} calls kubeconfig_ready"; else bad "${s} should call kubeconfig_ready"; fi
done
# EXCLUSIONS — a die-helper in an accumulator / creator / different-file checker is a regression. This
# guard is the whole point: a future refactor must not quietly convert these.
for s in 23-argocd-preflight 49-psa-check 30-vks-login 71-argocd-register-guest 06-install-harbor; do
  if grep -qE '^[[:space:]]*kubeconfig_ready\b' "${SCRIPT_DIR}/${s}.sh"; then bad "${s} MUST NOT call kubeconfig_ready (accumulator/creator/different-file)"; else ok "${s} correctly does NOT call kubeconfig_ready"; fi
done

echo
if [ "$rc" -eq 0 ]; then log_info "test-kubeconfig-ready: OK — ${checks} checks (C13 gate + wiring/exclusion guard)"; else log_error "test-kubeconfig-ready: FAILED (${checks} checks)"; fi
exit "$rc"
