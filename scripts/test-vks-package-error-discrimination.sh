#!/usr/bin/env bash
# test-vks-package-error-discrimination.sh — `vks-package.sh install` must never die SILENTLY, and
# must name WHICH of three very different things went wrong.
#
# WHY THIS EXISTS (MEASURED 2026-08-26, stubbed kubectl, before the fix):
#
#   _versions() is a `kubectl | jq` PIPELINE, and the call site was
#       vers="$(_versions "$PACKAGE")"          # no `|| true`
#       [ -n "$vers" ] || _die_unknown "..."    # <- the guard, on the NEXT line
#   Under `set -euo pipefail` a failing kubectl makes the pipeline non-zero, so the ASSIGNMENT is
#   non-zero and `set -e` kills the script ONE LINE ABOVE the guard written for exactly that case.
#   `2>/dev/null` inside _versions hid the MESSAGE but not the STATUS, so nothing was printed at all:
#
#     kubectl says                     | before      | after
#     ---------------------------------|-------------|---------------------------------------
#     no Carvel API ("resource type")  | rc=1, 262 B | rc=1, 674 B, names the cause + remedy
#     Forbidden (a namespaced tenant)  | rc=1, 262 B | rc=1, 721 B, names RBAC, quotes kubectl
#     API present, 0 items  (CONTROL)  | rc=1, 545 B | rc=1, 545 B  UNCHANGED
#     API present, package exists (CTL)| installs    | installs      UNCHANGED
#
#   THE CONTROL IS THE DISCRIMINATOR: the guard worked only on the success-with-empty path and was
#   dead on BOTH error paths. In the field that is `make install-ingress ISTIO_INSTALL_METHOD=package`
#   creating two namespaces and then exiting 1 with no message.
#
#   `_die_unknown` carried the SAME shape independently (its own `kubectl | jq | sed` is a STATEMENT,
#   so a failing kubectl killed it before its final die()) -- i.e. the error reporter would itself
#   have died silently. Case C pins that: it asserts the FINAL line, not merely that something printed.
#
# The two CONTROLS are not decoration. Without them this file would pass just as happily over a
# script that died on every input, which is the failure mode it exists to catch.
#
# WHAT THIS DOES **NOT** COVER, stated rather than implied. The `|| true` added to _die_unknown's own
# pipeline is DEFENCE IN DEPTH and has no RED case here: after the fix, the two kubectl-failure paths
# die earlier with specific messages, so _die_unknown is reached only when kubectl SUCCEEDS (case 3,
# where its pipeline cannot fail) or from the PACKAGE-unset / empty-stderr arms. Its guard is
# therefore unproven by this file. RED-proof for THIS file is the `|| true` on the ASSIGNMENT:
# remove it and case 1 returns to 262 bytes -- measured 2026-08-26, 4 assertions RED, both controls
# still green.
#
# Offline by construction: kubectl is a STUB, so this needs no lab and cannot be flaky.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }

fail=0; ran=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

STUB="$(mktemp -d)"; KC="$(mktemp)"
trap 'rm -rf "$STUB" "$KC"' EXIT
printf 'apiVersion: v1\nkind: Config\ncurrent-context: c\nclusters: []\ncontexts: []\nusers: []\n' > "$KC"

mk() { printf '#!/usr/bin/env bash\ncase "$*" in\n  *"get packages"*) %s ;;\n  *) exit 0 ;;\nesac\n' "$1" > "$STUB/kubectl"; chmod +x "$STUB/kubectl"; }
run() {
  PATH="$STUB:$PATH" KUBECONFIG="$KC" SKIP_DOTENV=1 VKS_PACKAGE_NAMESPACE=vmware-system-tkg \
    timeout 60 bash scripts/vks-package.sh install istio.kubernetes.vmware.com 2>&1
}

echo "  case 1: NO Carvel API — must die LOUDLY naming the cause, not silently"
mk 'echo "error: the server doesn'"'"'t have a resource type \"packages\"" >&2; exit 1'
out="$(run)"; ran=$((ran+1))
if printf '%s' "$out" | grep -qF 'not serving the Carvel packaging API'; then
  ok "named the missing API group"
else bad "did not name the missing API group (silent death?): ${#out} bytes"; fi
if printf '%s' "$out" | grep -qF 'ISTIO_INSTALL_METHOD=helm'; then
  ok "offered the remedy that actually exists on a non-VKS cluster"
else bad "no actionable remedy"; fi
# istio-existing is NONSENSE here: a cluster with no Carvel API has no platform-owned mesh to attach to.
if printf '%s' "$out" | grep -qF 'istio-existing'; then
  bad "offered istio-existing — there is no platform mesh to attach to on such a cluster"
else ok "did not offer istio-existing"; fi

echo "  case 2: FORBIDDEN (a namespaced tenant) — a DIFFERENT cause, a different message"
mk 'echo "Error from server (Forbidden): packages.data.packaging.carvel.dev is forbidden: User cannot list resource \"packages\" at the cluster scope" >&2; exit 1'
out="$(run)"; ran=$((ran+1))
if printf '%s' "$out" | grep -qF 'may not LIST packages'; then ok "named the RBAC cause"
else bad "conflated an RBAC denial with a missing API"; fi
if printf '%s' "$out" | grep -qF 'Forbidden'; then ok "quoted what kubectl actually said"
else bad "swallowed kubectl's own message"; fi

echo "  case 3 (CONTROL): API present, ZERO packages — the pre-existing diagnostic, UNCHANGED"
mk 'echo "{\"items\":[]}"; exit 0'
out="$(run)"; ran=$((ran+1))
if printf '%s' "$out" | grep -qF 'packages available on this cluster'; then
  ok "kept the original empty-cluster diagnostic"
else bad "the empty-cluster path regressed"; fi
# _die_unknown's OWN pipeline was unguarded: assert its LAST line, which is what `set -e` used to eat.
if printf '%s' "$out" | grep -qF 're-run with PACKAGE='; then
  ok "_die_unknown reached its final die() (its own pipeline no longer kills it)"
else bad "_die_unknown died before its final line — the reporter is dying silently"; fi

echo "  case 4 (CONTROL): the package EXISTS — must NOT be blocked by any of the above"
mk 'echo "{\"items\":[{\"spec\":{\"refName\":\"istio.kubernetes.vmware.com\",\"version\":\"1.28.5+vmware.1-vks.1\"}}]}"; exit 0'
out="$(run)"; ran=$((ran+1))
if printf '%s' "$out" | grep -qF 'installing istio.kubernetes.vmware.com'; then
  ok "proceeded to install — no false block"
else bad "FALSE BLOCK on a healthy cluster: $(printf '%s' "$out" | tail -1)"; fi

[ "$ran" -eq 4 ] || { echo "  harness lost track of itself (ran=$ran)"; exit 1; }
[ "$fail" -eq 0 ] || { echo "vks-package-error-discrimination: FAILED"; exit 1; }
echo "vks-package-error-discrimination: OK — ${ran} cases"
