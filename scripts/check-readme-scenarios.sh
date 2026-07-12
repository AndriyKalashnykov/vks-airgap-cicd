#!/usr/bin/env bash
# check-readme-scenarios.sh — the README is SCENARIO-BASED. Enforce it.
#
# THE STRUCTURE THIS GATE PROTECTS
#   A reader picks exactly one path and follows it end to end:
#       KinD  |  Real lab Scenario 1 (I install Harbor+ArgoCD)  |  Real lab Scenario 2 (tenant)
#   Each scenario must therefore ANSWER EVERY DECISION ITSELF. A reader in Scenario 2 must not have
#   to know that some topic section elsewhere in the document also applies to them.
#
# WHY IT IS A GATE
#   The rule was stated and agreed, and the document drifted anyway: Istio — whose mode is decided
#   ENTIRELY by scenario (KinD installs a mesh; both real labs attach to the one VKS already has) —
#   sat in a standalone 108-line topic section between KinD and Scenario 1. A reader in Scenario 2
#   would never see it, and the runbook they DID follow told them to run the bare
#   `make install-ingress`, which would have helm-installed a second istiod over the platform's mesh.
#   Topic sections are how scenario-based docs rot: they look tidy and they orphan decisions.
#
# WHAT IT CHECKS: each scenario section resolves each decision below within its OWN body.
# It is deliberately COARSE (keyword presence) — it proves a decision is ADDRESSED, not that the
# prose is correct. Correctness is the claim-by-claim audit; this stops the STRUCTURE regressing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

README="${REPO_ROOT}/README.md"
[ -f "$README" ] || die "no README.md"

# Extract a '## <heading match>' section body (up to the next '## ').
section() { awk -v pat="$1" '
  $0 ~ /^## / { if (inb) exit; if (index($0,pat)) { inb=1; next } }
  inb { print }' "$README"; }

# scenario|heading fragment
SCENARIOS='KinD|Try it locally end-to-end with KinD
Scenario-1|Scenario 1: Harbor & ArgoCD need to be installed
Scenario-2|Scenario 2: Harbor & ArgoCD already installed'

# decision|regex that shows the scenario ADDRESSES it
DECISIONS='cluster-access|VKS_AUTH_METHOD|vks-authentication|kind-up
harbor|install-harbor|Harbor
argocd|install-argocd|ArgoCD
istio-mode|istio-existing|we install
ingress-cmd|install-ingress
verify|make verify|e2e-kind|install-all
access-uis|vks.local|port-forward'

rc=0

# Extract each scenario body ONCE into a temp file. (The previous version did the matching with
# nested `while IFS='|' read` loops over here-strings; the IFS juggling corrupted state and a
# `grep` for a string that WAS present reported absent — a blind gate. Files + plain greps are
# boring and correct.)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
scenario_names=(); scenario_files=()
while IFS='|' read -r sc head; do
  [ -z "$sc" ] && continue
  section "$head" > "${TMP}/${sc}.body"
  scenario_names+=("$sc"); scenario_files+=("${TMP}/${sc}.body")
  [ -s "${TMP}/${sc}.body" ] || { log_error "scenario '${sc}' section not found (heading changed?): ${head}"; rc=1; }
done <<< "$SCENARIOS"

printf '\n  %-14s' 'DECISION' >&2
for sc in "${scenario_names[@]}"; do printf '%-14s' "$sc" >&2; done
printf '\n  %s\n' "$(printf '%0.s-' {1..58})" >&2

while IFS= read -r dline; do
  [ -z "$dline" ] && continue
  dec="${dline%%|*}"; pats="${dline#*|}"
  printf '  %-14s' "$dec" >&2
  for k in "${!scenario_names[@]}"; do
    f="${scenario_files[$k]}"
    hit=0
    # `grep -F -e p1 -e p2 ...` — no arrays, no IFS games.
    args=(); old="$IFS"; IFS='|'; for p in $pats; do args+=(-e "$p"); done; IFS="$old"
    grep -qiF "${args[@]}" "$f" 2>/dev/null && hit=1
    if [ "$hit" -eq 1 ]; then printf '%-14s' 'OK' >&2
    else printf '%-14s' 'MISSING' >&2; rc=1; fi
  done
  printf '\n' >&2
done <<< "$DECISIONS"

echo >&2
if [ "$rc" -eq 0 ]; then
  log_info "check-readme-scenarios: OK — every scenario answers every decision within its own section."
else
  log_error "check-readme-scenarios: a scenario does NOT answer a decision it must."
  log_error "  This README is SCENARIO-BASED: a reader follows ONE path end to end. Do not park the"
  log_error "  answer in a standalone topic section — put it in EACH scenario that needs it."
  log_error "  (That is exactly how the Istio install-vs-attach decision got orphaned, and the"
  log_error "   real-lab runbooks ended up telling operators to install a second istiod.)"
fi
exit "$rc"
