#!/usr/bin/env bash
# test-gateway-image.sh — OFFLINE RED/GREEN proof of 96-verify-gateway-image.sh.
#
# WHY THIS EXISTS. 96 asserts a property of a RUNNING cluster, so the obvious way to prove it is a
# ~30-minute `make e2e-kind`. That cost is exactly how gates end up shipped unproven — and an
# unproven gate is indistinguishable from no gate. 96 therefore takes GATEWAY_IMAGE_FIXTURE=<dir>,
# reading <dir>/<ns>.json instead of the cluster, so its CLASSIFIER is provable in milliseconds here.
#
# WHAT THIS DOES *NOT* PROVE, stated so nobody over-reads the green: that `kubectl get pods -o json`
# on a real cluster produces the shape these fixtures assume, and that a real CRI reports
# `.image` in the form the prefix test expects (runtimes normalise — a docker.io/ prefix, a digest
# form). Those are settled only by the live run in e2e-kind. This file proves the LOGIC; e2e proves
# the INTEGRATION. Both are needed and neither substitutes for the other.
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX" "${GATE_OUT:-}"' EXIT
fail=0; ran=0
GATE="${SCRIPT_DIR}/96-verify-gateway-image.sh"
[ -x "$GATE" ] || die "instrument missing or not executable: $GATE"

harbor_pod()  { printf '{"items":[{"metadata":{"name":"%s"},"status":{"containerStatuses":[{"image":"h.local/infra/istio/%s:1.30.3","imageID":"h.local/infra/istio/%s@sha256:aa"}]}}]}' "$1" "$2" "$2"; }
public_pod()  { printf '{"items":[{"metadata":{"name":"%s"},"status":{"containerStatuses":[{"image":"docker.io/istio/%s:1.30.3","imageID":"docker.io/istio/%s@sha256:bb"}]}}]}' "$1" "$2" "$2"; }

# NO command substitution here, deliberately, and it cost two bugs to learn why:
#   (a) a global assigned inside $( ) is LOST — it runs in a SUBSHELL (coding-style.md);
#   (b) worse, the `trap … EXIT` above FIRES when that subshell exits, so `rm -rf "$FIX"` deleted
#       the fixture directory after the very first case and every later one read a missing file.
# Output goes to a FILE and rc is read directly from the gate's own invocation.
GATE_OUT="$(mktemp)"
case_is() { # <label> <want-rc: 0|nonzero> <grep-ERE or "">
  ran=$((ran + 1))
  local rc
  HARBOR_URL=h.local INGRESS_CONTROLLER=istio GATEWAY_IMAGE_FIXTURE="$FIX" \
    bash "$GATE" > "$GATE_OUT" 2>&1
  rc=$?
  local okrc=1
  if [ "$2" = 0 ]; then [ "$rc" -eq 0 ] && okrc=0; else [ "$rc" -ne 0 ] && okrc=0; fi
  if [ "$okrc" -ne 0 ]; then
    printf 'FAIL  %s — rc=%s (wanted %s)\n' "$1" "$rc" "$2"; sed 's/^/        /' "$GATE_OUT"; fail=1; return
  fi
  if [ -n "${3:-}" ] && ! grep -qE "$3" "$GATE_OUT"; then
    printf 'FAIL  %s — rc ok but the message did not match /%s/\n' "$1" "$3"; sed 's/^/        /' "$GATE_OUT"; fail=1; return
  fi
  printf 'ok    %s\n' "$1"
}

# 1. GREEN: control-plane + data-plane, both from Harbor.
harbor_pod istiod-1     pilot    > "${FIX}/istio-system.json"
harbor_pod vks-uis-istio proxyv2 > "${FIX}/vks-ingress.json"
case_is "GREEN when every image came from Harbor" 0 'gateway image provenance: OK'

# 2. RED: the data-plane proxy pulled from the PUBLIC registry — the bug the gate exists for.
public_pod vks-uis-istio proxyv2 > "${FIX}/vks-ingress.json"
case_is "RED when the auto-provisioned proxy pulled from docker.io" 1 'NOT from h.local'

# 3. RED: control-plane from the public registry (a renamed --set key hits istiod too).
harbor_pod vks-uis-istio proxyv2 > "${FIX}/vks-ingress.json"
public_pod istiod-1      pilot   > "${FIX}/istio-system.json"
case_is "RED when istiod itself pulled from docker.io" 1 'NOT from h.local'

# 4. RED: NO data-plane pod at all. This is the subset-blindness an adversary proved on the first
#    draft: istiod alone satisfied a raw image count, so the gate passed having never seen a gateway.
harbor_pod istiod-1 pilot > "${FIX}/istio-system.json"
printf '{"items":[]}' > "${FIX}/vks-ingress.json"
case_is "RED (BLIND) when no data-plane pod exists — must not pass on istiod alone" 1 'data-plane'

# 5. RED: no control-plane pod either.
printf '{"items":[]}' > "${FIX}/istio-system.json"
harbor_pod vks-uis-istio proxyv2 > "${FIX}/vks-ingress.json"
case_is "RED (BLIND) when no control-plane pod exists" 1 'CONTROL-PLANE'

# 6. Init containers are read, not silently skipped.
printf '{"items":[{"metadata":{"name":"gw"},"status":{"containerStatuses":[{"image":"h.local/infra/istio/proxyv2:1","imageID":"h.local/x@sha256:a"}],"initContainerStatuses":[{"image":"docker.io/istio/proxyv2:1","imageID":"docker.io/x@sha256:b"}]}}]}' > "${FIX}/vks-ingress.json"
harbor_pod istiod-1 pilot > "${FIX}/istio-system.json"
case_is "RED when only an INIT container came from the public registry" 1 'NOT from h.local'

# 7. imageID rescues a normalised .image (a CRI may report a bare/normalised ref).
printf '{"items":[{"metadata":{"name":"gw"},"status":{"containerStatuses":[{"image":"istio/proxyv2:1.30.3","imageID":"h.local/infra/istio/proxyv2@sha256:cc"}]}}]}' > "${FIX}/vks-ingress.json"
case_is "GREEN when .image is normalised but imageID resolves to Harbor" 0 'matched via imageID'

[ "$ran" -eq 7 ] || die "expected 7 cases, ran ${ran} — this harness lost track of itself"
[ "$fail" -eq 0 ] || { log_error "gateway-image gate: FAILED"; exit 1; }
log_info "gateway-image gate: OK — ${ran} cases (classifier only; the LIVE integration is proven by e2e-kind)"
