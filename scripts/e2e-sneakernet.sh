#!/usr/bin/env bash
# e2e-sneakernet.sh — the faithful TWO-BOX sneakernet, across an OS MATRIX.
#
#   [host = the INTERNET box]   mirror-pull -> bundle   (the bundle carries `crane`)
#   ---- carry ONLY the tarball across the gap ----
#   [a FRESH jump-box container = the AIR-GAP box]   bundle-load -> mirror-push -> mirror-verify
#
# WHY AN OS MATRIX, AND NOT JUST PHOTON
# -------------------------------------
# The far side is exactly where the two OSes diverge, and every divergence is invisible on the
# near side:
#   * the COMPRESSOR IS CHOSEN BY THE OUTSIDE BOX (11-bundle.sh: zstd if present, else gzip) and
#     must be DECODED BY THE INSIDE BOX. `zstd` is absent from BOTH base images (photon:5.0,
#     ubuntu:26.04) — this only works because the jump-box images install it. Nothing else tests
#     that coupling, and a bundle you cannot unpack is a wasted trip across an air gap.
#   * Photon's coreutils are TOYBOX, not GNU (`tar`, and the `gzip -t` that already false-failed
#     here once).
#   * the CARRIED `crane` must actually exec on the target OS.
#
# WHY A FRESH CLUSTER PER LEG (this is the load-bearing bit)
# ---------------------------------------------------------
# An OCI push establishes blob existence with a HEAD and SKIPS THE UPLOAD if the registry says it
# already has it. So a second leg pushed into the SAME Harbor would upload NOTHING, print
# "existing blob" 36 times, and exit 0 — a green leg that pushed nothing and proved nothing. Each
# leg therefore gets its own cluster and its own empty Harbor, so its push is a REAL push.
#
# The host's ./bundle image cache IS reused across legs. That is legitimate: it belongs to the
# *internet* box, which is the same machine in both legs. The thing under test is the AIR-GAP box,
# and that is a brand-new container every time.
#
# WHY A SCRIPT AND NOT A RECIPE: it was a ~45-line `\`-continued Makefile block. A recipe cannot be
# linted, cannot be `set -euo pipefail`'d coherently, and hides its failures — which is how every
# silent bug in the sibling jump-box harness got in.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

cd "$REPO_ROOT"

# The OS matrix. `make e2e-sneakernet` -> photon; `make e2e-sneakernet-both` -> photon ubuntu.
SNEAKERNET_OS="${SNEAKERNET_OS:-photon}"

# The transfer medium (USB/optical). A fresh mktemp per run unless the operator names one, so
# nothing pre-exists. Kept OUT of BUNDLE_DIR so `tar` never archives its own output.
TRANSFER="${SNEAKERNET_TRANSFER:-}"
_transfer_owned=0
if [ -z "$TRANSFER" ]; then TRANSFER="$(mktemp -d)"; _transfer_owned=1; fi

cleanup() {
  local rc=$?
  [ "$_transfer_owned" = 1 ] && rm -rf "$TRANSFER"
  make kind-down >/dev/null 2>&1 || true
  return $rc
}
trap cleanup EXIT

log_info "sneakernet e2e — OS matrix: ${SNEAKERNET_OS} · transfer dir: ${TRANSFER}"

# --- the INTERNET box (the host) -------------------------------------------------------------
# Pull once; the cache is legitimately shared across legs (same internet box). Digest-pinned
# images already fully pulled are cache-skipped, so a re-run costs seconds.
log_info "[internet box / host] pulling images into ${BUNDLE_DIR:-./bundle}"
make mirror-pull

log_info "[internet box / host] bundling into the transfer dir (stages crane into the bundle)"
make bundle BUNDLE_OUT_DIR="$TRANSFER"

tarball=""
for f in "$TRANSFER"/vks-airgap-cicd-bundle-*.tar \
         "$TRANSFER"/vks-airgap-cicd-bundle-*.tar.zst \
         "$TRANSFER"/vks-airgap-cicd-bundle-*.tar.gz; do
  [ -f "$f" ] && { tarball="$f"; break; }
done
[ -n "$tarball" ] || die "bundle produced no tarball in ${TRANSFER}"
log_info "carrying ONLY $(basename "$tarball") ($(du -h "$tarball" | cut -f1)) across the gap"

# --- one leg per OS --------------------------------------------------------------------------
legs=0
for os in $SNEAKERNET_OS; do
  echo
  log_info "═══ AIR-GAP LEG: ${os} ═══"

  # A fresh cluster + an EMPTY Harbor, so this leg's push is a real push (see the header).
  make kind-down >/dev/null 2>&1 || true
  make kind-up install-harbor

  log_info "[air-gap box / ${os}] a FRESH jump box holding ONLY the tarball: bundle-load -> mirror-push -> mirror-verify"
  make jumpbox JUMPBOX_OS="$os" JUMPBOX_TARBALL="$tarball"

  legs=$((legs + 1))
  log_info "═══ ${os}: OK — reconstructed the cache from the carried tarball alone, installed the CARRIED crane, pushed, and integrity-verified ═══"
done

[ "$legs" -gt 0 ] || die "SNEAKERNET_OS was empty — no leg ran (a vacuous green is not a pass)"

echo
log_info "e2e-sneakernet: OK — ${legs} air-gap leg(s) [${SNEAKERNET_OS}], each a FRESH box + a FRESH empty Harbor,"
log_info "                each reconstructing the image cache AND its toolchain from ONLY the carried tarball."
