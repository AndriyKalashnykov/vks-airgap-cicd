#!/usr/bin/env bash
# test-airgap-toolchain.sh — can a REAL air-gapped box (no internet, no toolchain) actually do the job?
#
# WHAT THIS EXISTS TO CATCH.
#   ORIGINALLY (and this is why the test was written): the sneakernet e2e's "air-gap box"
#   `vks-jumpbox:<os>-<engine>` ran `make deps`, so it already had kubectl/helm/jq/yq before the bundle
#   arrived; the e2e asserted only that CRANE was absent. The bundle therefore carried no toolchain for
#   the INSTALL half, the runbook told operators to run `make platform`/`gitops`/`verify` on a box whose
#   tools could not exist, and every test was green.
#
#   THAT IS NO LONGER TRUE, and saying it here was a false rationale on a control — corrected
#   2026-07-18. `jumpbox-run.sh` no longer runs `make deps` on the sneakernet path ("NO `make deps`
#   HERE. THAT WAS THE LIE."), and MEASURED on the built images: crane, kubectl, helm, jq and yq are
#   ALL ABSENT from `vks-jumpbox:photon-podman` and `vks-jumpbox:ubuntu-podman`. The e2e also now runs
#   `make check-tools` after bundle-load, which lists all five as `carried` and EXECUTES each — so it
#   WOULD notice a bundle that dropped one.
#
#   WHAT THIS STILL ADDS, precisely: the e2e asserts only that CRANE was absent beforehand, and its box
#   sits on the `kind` network. This test proves PROVENANCE — a box with no mise at all
#   (Dockerfile.airgap) and NO NETWORK AT ALL, asserting all five absent first, so the five that appear
#   can only have come from the carried bundle.
#
# This test runs the bundle-load on a box that is BARE (jumpbox/Dockerfile.airgap: OS packages only) and
# has NO NETWORK AT ALL (`--network none`, so not even a package mirror can save it), on BOTH supported
# jump-box OSes, and asserts:
#   BEFORE: crane, kubectl, helm, jq, yq are ALL MISSING            (else the box is pre-provisioned and
#                                                                    the test proves nothing — the rigging)
#   AFTER : all five are installed AND EXECUTE                       (a file that is +x is not a binary
#                                                                    that works — the mise-shim trap)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${BUNDLE_DIR:?}"
require_cmd docker "this is a LOCAL TEST HARNESS (it builds and runs throwaway OS images)"   # docker-ok: test harness only, never on the operator path

TARBALL="${AIRGAP_TARBALL:-}"
if [ -z "$TARBALL" ]; then
  # Reuse a bundle if one is lying around; otherwise cut one (needs the image cache).
  # shellcheck disable=SC2012  # our own timestamped bundle names — no exotic filenames
  # NOT `*.tar.*` — that glob matches the .sha256 SIDECAR, and the newest file is the sidecar (written
  # after the tarball), so it picked the checksum file AS the bundle.
  TARBALL="$(ls -t "${REPO_ROOT}"/vks-airgap-cicd-bundle-*.tar "${REPO_ROOT}"/vks-airgap-cicd-bundle-*.tar.gz "${REPO_ROOT}"/vks-airgap-cicd-bundle-*.tar.zst 2>/dev/null | head -1 || true)"
  [ -n "$TARBALL" ] || die "no bundle found. Cut one first (it must carry the toolchain):
      make mirror-pull && make builder-build && make bundle
  or point this at one:  make airgap-toolchain-test AIRGAP_TARBALL=/path/to/bundle.tar"
fi
[ -f "${TARBALL}.sha256" ] || die "no checksum beside ${TARBALL} — 'make bundle' writes it, and bundle-load requires it."

TOOLS="crane kubectl helm jq yq"
OSES="${AIRGAP_OS:-photon ubuntu}"
declare -A BASES=( [photon]="photon:5.0" [ubuntu]="ubuntu:26.04" )

fails=0
for os in $OSES; do
  base="${BASES[$os]:-}"
  [ -n "$base" ] || die "unknown AIRGAP_OS '${os}' (known: ${!BASES[*]})"
  img="vks-airgap-bare:${os}"

  log_info "═══ ${os} (${base}) — building a BARE air-gap box: OS packages only, no toolchain ═══"
  run docker build -q --build-arg "BASE=${base}" -f "${REPO_ROOT}/jumpbox/Dockerfile.airgap" -t "$img" "$REPO_ROOT" >/dev/null

  # --network none: no internet, and no package mirror either. Whatever the flow needs must be in the
  # bundle or on the OS already. The repo is mounted read-only and copied in, exactly as an operator
  # would carry it (they cannot `git clone` — there is no network).
  # `-i` IS LOAD-BEARING. Without it `docker run` has NO STDIN, so `bash -s <<INNER` reads NOTHING, exits
  # 0 immediately, and the `if` calls that a PASS. This test "passed" in ONE SECOND — a 12 GB bundle-load
  # cannot — and asserted nothing at all. A test that cannot fail is worse than no test.
  if docker run --rm -i --network none \
      -v "${TARBALL}:/carry/bundle.tar:ro" \
      -v "${TARBALL}.sha256:/carry/bundle.tar.sha256:ro" \
      -v "${REPO_ROOT}:/src:ro" \
      -e "TOOLS=${TOOLS}" \
      "$img" bash -s <<'INNER'
set -euo pipefail
# COPY WHAT AN OPERATOR ACTUALLY CARRIES — the repo, and nothing else.
# NOT `cp -r /src`: that drags in the host's `secrets/`, `.env*` and the 12 GB `bundle/`, all owned by
# the host's uid and mode 0600 — and on ubuntu:26.04 the image already has a default `ubuntu` user at
# uid 1000, so our `vks` is 1001 and cannot read ANY of them ("Permission denied" x400).
mkdir -p /home/vks/repo && cd /home/vks/repo
tar -C /src --exclude=./bundle --exclude=./secrets --exclude='./.env' --exclude='./.env.state*' \
            --exclude='./.git' --exclude='./vks-airgap-cicd-bundle-*' -cf - . 2>/dev/null | tar -xf -
[ -f Makefile ] && [ -d scripts ] || { echo "FAILED: the repo did not copy"; exit 1; }
rm -rf bundle                       # the cache must come ONLY from the carried tarball

echo "--- BEFORE bundle-load: the box must be BARE (a pre-provisioned box proves nothing) ---"
rigged=0
for t in $TOOLS; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "    FAIL  $t is ALREADY on this 'air-gapped' box ($(command -v "$t")) — the test is rigged"
    rigged=1
  else
    echo "    ok    $t absent"
  fi
done
[ "$rigged" -eq 0 ] || { echo "FAILED: the air-gap box was pre-provisioned"; exit 1; }

# The carried media. bundle-load REQUIRES the checksum; recompute the name it expects.
cp /carry/bundle.tar .
sha256sum bundle.tar > bundle.tar.sha256

# H6 — ~/.local/bin is NOT on PATH here, deliberately (the Dockerfile no longer pre-sets it). On a real
# jump box that is the common case (non-login shell, `sudo make`, cron), and the next step after this is
# `make platform` -> `kubectl: command not found` on a box that cannot install anything. bundle-load must
# DIE on it, not warn at the end of a 12 GB load.
echo "--- bundle-load must REFUSE while the install dir is off PATH (a warning is not enough) ---"
if make bundle-load BUNDLE_TARBALL="$PWD/bundle.tar" > /tmp/off.log 2>&1; then
  echo "    FAIL  it SUCCEEDED with the tools unreachable — 'make platform' would then die here"
  exit 1
fi
grep -q 'NOT on your PATH' /tmp/off.log \
  && echo "    ok    refused, naming the real problem" \
  || { echo "    FAIL  it failed for the WRONG reason:"; tail -3 /tmp/off.log | sed 's/^/          /'; exit 1; }

echo "--- bundle-load, with the PATH the operator was told to set (no network at all) ---"
export PATH="$HOME/.local/bin:$PATH"
# The gate runs ALONE, on its own line, and its OWN rc decides. It used to be piped into `grep` for
# prettier output — under `set -o pipefail` that is merely fragile, but it is exactly the shape that
# hands you a green from a command that failed. Capture, then read.
make bundle-load BUNDLE_TARBALL="$PWD/bundle.tar" > /tmp/load.log 2>&1; rc=$?
grep -E 'installed |KEPT |verifying checksum|NOT in the bundle' /tmp/load.log | sed 's/.*msg=//' | sed 's/^/    /' || true
[ "$rc" -eq 0 ] || { echo "FAILED: bundle-load exited $rc"; tail -25 /tmp/load.log; exit 1; }

echo "--- AFTER: every tool must be present AND RUN (a +x file is not a working binary) ---"
bad=0
for t in $TOOLS; do
  case "$t" in
    crane)   v="$(crane version 2>&1 | head -1)" ;;
    kubectl) v="$(kubectl version --client 2>&1 | head -1)" ;;
    helm)    v="$(helm version --short 2>&1 | head -1)" ;;
    *)       v="$($t --version 2>&1 | head -1)" ;;
  esac
  case "$v" in
    ''|*[Mm]ise*|*"not found"*|*"Exec format"*) echo "    FAIL  $t -> '${v:-<nothing>}'"; bad=1 ;;
    *) printf '    ok    %-8s %s\n' "$t" "$v" ;;
  esac
done
[ "$bad" -eq 0 ] || { echo "FAILED: a carried tool does not work on this box"; exit 1; }

# The image cache must have come from the tarball, not from anywhere else.
n=$(find bundle/images -maxdepth 1 -type d | wc -l)
echo "    ok    image cache reconstructed from the carried tarball ($((n-1)) images)"

# THE ACTUAL CLAIM. "Five binaries copied" is not "this box can run the flow" — and the difference is not
# academic: this test used to stop at the line above, so it could not see that `awk` is absent from a bare
# photon:5.0 while lib/apps.sh (every per-app loop) and 23-mirror-verify.sh both need it. `check-tools` is
# the command the runbook tells the operator to trust before carrying 12 GB across a room, so it is the
# thing that must be true here.
echo "--- can this box actually RUN THE FLOW? (make check-tools — what the runbook tells operators to trust) ---"
make check-tools > /tmp/tools.log 2>&1; rc=$?
sed 's/.*msg=//' /tmp/tools.log | sed 's/^/    /' | tail -20
[ "$rc" -eq 0 ] || { echo "FAILED: check-tools says this box CANNOT run the flow (exit $rc)"; exit 1; }

# helm WITHOUT CHARTS IS 62 MB OF DEAD WEIGHT, and istio is the DEFAULT ingress. `helm repo add` cannot
# work here, so the charts must be CARRIED. Rendering one offline is the proof.
echo "--- can the DEFAULT ingress (istio) actually install here? ---"
chart="$(find bundle/charts -name 'base-*.tgz' -print -quit 2>/dev/null || true)"
if [ -z "$chart" ]; then
  echo "    FAIL  no istio charts in the bundle — 'make install-ingress' (default: istio) would need"
  echo "          'helm repo add https://istio-release.storage.googleapis.com', impossible on this box."
  exit 1
fi
helm template istio-base "$chart" >/dev/null 2>&1 \
  && echo "    ok    helm renders the CARRIED istio chart offline ($(basename "$chart"))" \
  || { echo "    FAIL  the carried istio chart does not render"; exit 1; }

echo "AIRGAP_TOOLCHAIN_OK"
INNER
  then
    log_info "═══ ${os}: PASS — a bare, network-less box got its whole toolchain from the bundle ═══"
  else
    log_error "═══ ${os}: FAIL ═══"
    fails=$((fails + 1))
  fi
done

[ "$fails" -eq 0 ] || die "airgap-toolchain-test: ${fails} OS leg(s) FAILED"
log_info "airgap-toolchain-test: OK — [${OSES}] each reconstructed BOTH the image cache and the toolchain from the carried bundle alone, with no network."
