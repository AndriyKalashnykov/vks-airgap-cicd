#!/usr/bin/env bash
# Every KinD e2e target that invokes a SCRIPT directly must export SKIP_DOTENV.
#
# B483: `e2e-kind-tenant` did not, so it read the operator's LAB-configured `.env`, where
# ARGOCD_NAMESPACE is the Supervisor's vSphere Namespace — and its check looked in the WRONG
# NAMESPACE of the RIGHT CLUSTER, dying `ArgoCD is not installed` while argocd-server was Running.
#
# EXEMPT: a target whose recipe only delegates to `$(MAKE) <other-target>`. The sub-make applies the
# delegate's own target-specific export, so the guard would be redundant there — `e2e-kind-both` is
# the live example. The exemption is DERIVED from the recipe (does it call a script?), never a
# hand-typed target list, which is the enumerated-list rot this repo keeps getting bitten by.
#
# RED-proof (by hand, 2026-08-25): delete the `e2e-kind-tenant: export SKIP_DOTENV` line and this
# reports `MISSING the SKIP_DOTENV guard` with rc=1.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0; checked=0; exempt=0
# Derive the target list from the Makefile itself — not a literal list.
targets=$(grep -oE '^e2e-kind[a-z-]*:' Makefile | tr -d ':' | sort -u)
[ -n "$targets" ] || { echo "FAIL: found no e2e-kind* targets — the extractor is broken, not the Makefile"; exit 1; }

while read -r t; do
  [ -n "$t" ] || continue
  # The recipe body: tab-indented lines following the LAST rule line for this target.
  # A target can have SEVERAL rule lines (`t: export VAR = ...` then `t: ## help`). Collect the
  # tab-indented body after EVERY one of them; stopping at the first was a false-EXEMPT bug caught
  # while writing this test — it read e2e-kind's recipe as empty and called it a delegator.
  recipe=$(awk -v t="^${t}:" '
    $0~t      {f=1; next}
    /^\t/     {if(f) print; next}
    /^#/      {next}   # a column-0 comment INTERLEAVED in a recipe does not end it (GNU make)
    /^[[:space:]]*$/ {next}
    {f=0}' Makefile)
  # Does it invoke a script directly (as opposed to only delegating to $(MAKE))?
  if printf '%s' "$recipe" | grep -qE '\$\(SCRIPTS\)/'; then
    checked=$((checked+1))
    if grep -qE "^${t}: export SKIP_DOTENV" Makefile; then
      echo "  ok      ${t}: guarded"
    else
      echo "  FAIL    ${t}: invokes a script directly but is MISSING the SKIP_DOTENV guard"
      echo "          it will read the operator's .env — see B483 (wrong namespace, right cluster)"
      fail=1
    fi
  else
    exempt=$((exempt+1))
    echo "  exempt  ${t}: delegates to \$(MAKE) only — the sub-make carries the delegate's export"
  fi
done <<< "$targets"

echo "test-e2e-dotenv-guard: ${checked} script-invoking target(s) checked, ${exempt} exempt"
[ "$checked" -gt 0 ] || { echo "FAIL: 0 targets checked — vacuous"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
echo "test-e2e-dotenv-guard: OK"
