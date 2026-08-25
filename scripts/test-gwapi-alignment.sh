#!/usr/bin/env bash
# check-gwapi-istio-alignment.sh has never been demonstrated to go RED. This proves every arm.
#
# WHY THIS FILE EXISTS: an adversary observed that BOTH halves of the helm comparison
# (ISTIO_VERSION and GATEWAY_API_VERSION) are UNCOMMENTED in .env.example, so `load_env`'s `set -a`
# exports them AFTER any per-run override -- measured, `GATEWAY_API_VERSION=v1.4.1 bash <gate>`
# returns rc=0. That is CORRECT for production (both are pins coupled to images/images.txt by
# check-image-alignment; a per-run override would install an Istio nobody mirrored), but it means
# the gate's fail-closed arm -- the one whose own header opens "WHY THIS EXISTS: I GUESSED" -- could
# not be RED-proved at all. A gate never seen to fail is indistinguishable from no gate.
#
# The seam is a HERMETIC TREE, not a production override: copy the gate + lib into a temp dir with a
# synthetic .env.example. No test-only branch is added to the product.
#
# NETWORK: the gate fetches istio's go.mod, so this test does too. It SKIPS loudly when offline
# rather than reporting a pass it did not earn.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0; T=""
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
cleanup() { [ -n "$T" ] && rm -rf "$T"; }
trap cleanup EXIT

curl -fsSL --max-time 15 -o /dev/null https://raw.githubusercontent.com/istio/istio/release-1.30/go.mod 2>/dev/null || {
  printf '  SKIP  github unreachable — this test drives an ONLINE gate; a green here would be unearned\n'; exit 0; }

# tree <istio> <gwapi> [pkg]  -> a hermetic repo the gate can be run inside
tree() {
  cleanup; T="$(mktemp -d)"; mkdir -p "$T/scripts/lib"
  cp "$ROOT/scripts/check-gwapi-istio-alignment.sh" "$T/scripts/"
  cp "$ROOT"/scripts/lib/*.sh "$T/scripts/lib/"
  { printf 'ISTIO_VERSION=%s\nGATEWAY_API_VERSION=%s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf 'ISTIO_PACKAGE_VERSION=%s\n' "$3"; } > "$T/.env.example"
}
run() { ( cd "$T" && env "$@" bash scripts/check-gwapi-istio-alignment.sh >"$T/out" 2>&1 ); }
said() { grep -qF "$1" "$T/out"; }

# --- the HELM arm: the RED that had never been demonstrated -------------------------------------
tree 1.30.3 v1.4.1
run E=1; rc=$?
{ [ "$rc" -ne 0 ] && said MISMATCH; } && ok "HELM arm goes RED on a wrong GATEWAY_API_VERSION (rc=$rc)" \
  || bad "HELM arm RED" "rc=$rc; this gate exists because someone GUESSED this pin, and it has now been shown never to fail"
tree 1.30.3 v1.5.1
run E=1; rc=$?
[ "$rc" -eq 0 ] && ok "HELM arm green when the pin is right (no false RED)" || bad "HELM arm green" "rc=$rc"

# --- the PACKAGE arm ----------------------------------------------------------------------------
tree 1.30.3 v1.5.1 1.28.5+vmware.1-vks.1
run E=1; rc=$?
{ [ "$rc" -ne 0 ] && said 'does not match the'; } && ok "PACKAGE arm goes RED when the pin vendors a different gwapi" \
  || bad "PACKAGE arm RED" "rc=$rc — a package pin two minors off installs an Istio the CRDs crash-loop against"
tree 1.30.3 v1.5.1 1.30.3+vmware.1-vks.1
run E=1; rc=$?
[ "$rc" -eq 0 ] && ok "PACKAGE arm green when both pins agree" || bad "PACKAGE arm green" "rc=$rc"

# F7: a 200 whose body has NO gateway-api line must FAIL CLOSED, like the helm arm on the same
# condition. release-1.8/go.mod is a real 200 (~5 KB) with zero sigs.k8s.io/gateway-api lines.
tree 1.30.3 v1.5.1 1.8.6+vmware.1-vks.1
run E=1; rc=$?
{ [ "$rc" -ne 0 ] && said 'found no sigs.k8s.io/gateway-api'; } && ok "F7 fetch-OK-but-extraction-empty fails CLOSED" \
  || bad "F7 fails closed" "rc=$rc — silent rc=0 here made the gate LESS informative with a pin set than unset"

# F8: a malformed pin derives a 404 branch; the message must name the URL and accuse the PIN.
tree 1.30.3 v1.5.1 '1.28+vmware.1-vks.1'
run E=1
{ said 'fetch failed: https://' && said 'the PIN is the suspect'; } && ok "F8 fetch failure names the URL and the pin" \
  || bad "F8 message" "a malformed pin reads as a network problem and sends the reader to the wrong suspect"

# F9: unset is the DEFAULT path (ISTIO_PACKAGE_VERSION is commented in .env.example), so the
# half-coverage disclosure must be a WARN and the OK line must carry the caveat.
tree 1.30.3 v1.5.1
run E=1
{ grep -q 'level=WARN.*FLOATS' "$T/out" && said 'HELM PATH ONLY'; } && ok "F9 the default path WARNs and caveats its own OK" \
  || bad "F9 disclosure" "the path every real run takes says 'OK' with no hint half the gate did not run"
said 'checked offline' && bad "F9 wording" "still says 'offline'; this gate is ONLINE — the reason is that an unset version is chosen at INSTALL time" \
  || ok "F9 does not call an online gate 'offline'"

# GWAPI_REQUIRE_FETCH must cover the package arm too, not just the helm one.
tree 1.30.3 v1.5.1 '1.28+vmware.1-vks.1'
run GWAPI_REQUIRE_FETCH=1; rc=$?
[ "$rc" -ne 0 ] && ok "GWAPI_REQUIRE_FETCH=1 makes an unfetchable PACKAGE pin fatal" \
  || bad "GWAPI_REQUIRE_FETCH covers the package arm" "rc=$rc"

printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
