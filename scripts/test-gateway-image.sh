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
case_is() { # <label> <want-rc: 0|nonzero> <grep-ERE or ""> [ISTIO_INSTALL_METHOD] [INGRESS_CONTROLLER]
  ran=$((ran + 1))
  local rc
  # ⚠️ THE MODE IS A PARAMETER. It was hardcoded to `istio`, so the two SKIP arms had ZERO offline
  # coverage -- this file could not express an input for the branches a backlog row wanted to edit.
  HARBOR_URL=h.local INGRESS_CONTROLLER="${5:-istio}" GATEWAY_IMAGE_FIXTURE="$FIX" \
    ISTIO_INSTALL_METHOD="${4:-helm}" \
    bash "$GATE" > "$GATE_OUT" 2>&1
  rc=$?
  local okrc=1
  if [ "$2" = 0 ]; then [ "$rc" -eq 0 ] && okrc=0; else [ "$rc" -ne 0 ] && okrc=0; fi
  if [ "$okrc" -ne 0 ]; then
    printf 'FAIL  %s — rc=%s (wanted %s)\n' "$1" "$rc" "$2"; sed 's/^/        /' "$GATE_OUT"; fail=1; return
  fi
  # ⚠️ EXACTLY ONE VERDICT TOKEN, ALWAYS. Every assertion in this file is a POSITIVE grep, so an
  # extra token is invisible to all of them -- MEASURED: one spurious `_verdict ASSERTED` beside the
  # definition made a traefik SKIP emit `ASSERTED` *and* `SKIPPED:traefik`, and this suite reported
  # `OK — 15 cases`, rc 0. That is precisely the ambiguity the token was added to remove ("rc=0 alone
  # cannot tell 'verified clean' from 'looked at nothing'"), re-created one layer up: a consumer
  # grepping for ASSERTED would read all three skips as verified passes.
  # Scoped to rc=0. A FAILING run needs no token -- rc!=0 is already unambiguous, and the gate
  # deliberately emits none on its three `die`s. The ambiguity this guards is rc=0-only.
  local _vn
  _vn="$(grep -c 'gateway-image-verdict:' "$GATE_OUT" || true)"
  if [ "$2" = 0 ] && [ "${_vn:-0}" -ne 1 ]; then
    printf 'FAIL  %s — emitted %s verdict tokens, want exactly 1\n' "$1" "$_vn"; sed 's/^/        /' "$GATE_OUT"; fail=1; return
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

# 8/9. ISTIO_INSTALL_METHOD=package sets NO `global.hub`, so its images legitimately come from the
# VKS addon repository, not our Harbor. Asserting our registry there REDS a CORRECT install. The
# gate had ZERO references to ISTIO_INSTALL_METHOD (grep -c = 0) and branched on INGRESS_CONTROLLER
# alone, so `istio` + `package` fell straight through to the Harbor assertion.
printf '{"items":[{"metadata":{"name":"gw"},"status":{"containerStatuses":[{"image":"projects.packages.broadcom.com/vsphere/supervisor/istio/proxyv2:1.28.5","imageID":"projects.packages.broadcom.com/vsphere/supervisor/istio/proxyv2@sha256:aa"}]}}]}' > "${FIX}/vks-ingress.json"
printf '{"items":[{"metadata":{"name":"istiod-1"},"status":{"containerStatuses":[{"image":"projects.packages.broadcom.com/vsphere/supervisor/istio/pilot:1.28.5","imageID":"projects.packages.broadcom.com/vsphere/supervisor/istio/pilot@sha256:bb"}]}}]}' > "${FIX}/istio-system.json"
case_is "SKIPS in package mode — depot images must not be judged against our Harbor" 0 'NOTHING was verified' package
# ...and the SAME fixture must still RED under the default helm method, or the skip is unconditional.
case_is "REDS on the same depot images under the DEFAULT helm method" 1 'NOT from h.local'

# ── THE TWO SKIP ARMS, AND THE VERDICT TOKEN. ────────────────────────────────────────────────────
# ⚠️ THE FIXTURE CARRIES THE DEFECT THIS GATE EXISTS FOR (a data-plane image not from h.local), so
# these cases assert that each skip returns 0 OVER A REAL DEFECT -- which is the point: a skip must
# be a skip, not a silent pass. That is exactly why the verdict token matters, and why the token is
# asserted here rather than only the rc: rc=0 alone cannot tell "verified clean" from "looked at
# nothing", and an adversary measured that ambiguity reaching e2e-kind on DEFAULT settings.
case_is "istio-existing SKIPS over the defect (the mesh is the platform's)" 0 'NOTHING was verified about provenance' helm istio-existing
case_is "...and says so in a MACHINE-READABLE verdict"                      0 'gateway-image-verdict: SKIPPED:istio-existing' helm istio-existing
case_is "traefik SKIPS over the defect (no Istio proxy exists)"             0 'NOTHING was verified here' helm traefik
case_is "...and says so in a MACHINE-READABLE verdict"                      0 'gateway-image-verdict: SKIPPED:traefik' helm traefik
case_is "package SKIPS, with its own verdict"                               0 'gateway-image-verdict: SKIPPED:package' package
# The POSITIVE control: the token must DIFFER on the path that actually asserts, or it is decoration.
# The fixture is a DIRECTORY of per-namespace payloads (see the helpers at the top) -- a flat file
# here made the gate FATAL "no running container found in the CONTROL-PLANE namespace", which is the
# gate correctly refusing an empty read rather than the case failing for its own reason.
rm -f "${FIX}"/*.json
harbor_pod istiod-1     pilot    > "${FIX}/istio-system.json"
harbor_pod vks-uis-istio proxyv2 > "${FIX}/vks-ingress.json"
case_is "a clean tree emits ASSERTED, not SKIPPED"                          0 'gateway-image-verdict: ASSERTED'
# The label says "not SKIPPED" -- so assert it. The one-token check above already forbids a second
# token, but this pins the DIRECTION too: a gate that emitted only `SKIPPED:istio` on the assert path
# would satisfy the count and still be wrong.
ran=$((ran + 1))
if grep -q 'gateway-image-verdict: SKIPPED' "$GATE_OUT"; then
  printf 'FAIL  the clean-tree run emitted a SKIPPED verdict\n'; fail=1
else
  printf 'ok    ...and emits no SKIPPED verdict (the label is asserted, not just claimed)\n'
fi

[ "$ran" -eq 16 ] || die "expected 16 cases, ran ${ran} — this harness lost track of itself"
[ "$fail" -eq 0 ] || { log_error "gateway-image gate: FAILED"; exit 1; }
log_info "gateway-image gate: OK — ${ran} cases (classifier only; the LIVE integration is proven by e2e-kind)"
