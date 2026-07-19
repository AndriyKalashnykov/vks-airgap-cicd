#!/usr/bin/env bash
# jumpbox-launch.sh — launch a jump-box container against the running KinD cluster.
#
# WHY THIS IS A SCRIPT AND NOT A MAKEFILE RECIPE
# ---------------------------------------------
# It used to be a ~50-line `\`-continued recipe, and EVERY silent failure in the jump-box harness
# happened inside it:
#   * five reads of a RENAMED state file (`.env.kind`) that had been dead for weeks — one failed loudly
#     with an error naming the wrong cause, the other four failed SILENTLY (the CA was never mounted, so
#     the box could not trust Harbor and got HTTP 000);
#   * `grep` in a command substitution killing the recipe under `set -e` with NO output (exit 1 on
#     no-match, exit 2 on a MISSING FILE) — four separate instances;
#   * the Harbor CA mounted but never NAMED, so the thing that needed it could not find it.
#
# A recipe cannot be shellcheck'd, cannot be unit-tested, and cannot be coherently `set -euo pipefail`'d
# — each line is its own shell, and a `\`-continued block is one enormous statement whose failures are
# invisible. This file can be all three. That is the entire justification.
#
# It reads its configuration through `load_env` (the ONE loader), instead of re-implementing a
# sink-reader with grep/sed/`|| true`. That is what deleted most of the original code: HARBOR_URL,
# HARBOR_INSECURE, HARBOR_CA_FILE, HARBOR_USERNAME and HARBOR_PASSWORD all arrive resolved, with the
# state overlay already layered on top of .env — which is precisely what the hand-rolled reader kept
# getting wrong.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# From the Makefile.
: "${JUMPBOX_OS:?}"; : "${JUMPBOX_ENGINE:?}"; : "${JUMPBOX_IMAGE:?}"
VCF_SRC="${JUMPBOX_VCF_SRC:-}"
TARBALL="${JUMPBOX_TARBALL:-}"

require_cmd kind "the KinD cluster must be up (make kind-up install-harbor ...)"
require_cmd docker "the jump-box harness runs the container on the kind Docker network"   # docker-ok: this is a LOCAL TEST HARNESS for the KinD stand-in — kind's nodes ARE docker containers. It is never on the air-gap operator path (podman + crane).
docker network inspect kind >/dev/null 2>&1 \
  || die "the kind Docker network does not exist — bring the cluster up first (make kind-up)"   # docker-ok: same — KinD-only harness.

: "${HARBOR_URL:?HARBOR_URL is not set — run 'make install-harbor' first}"
: "${HARBOR_USERNAME:?set HARBOR_USERNAME in .env (admin for scenario 1, your robot for scenario 2)}"
: "${HARBOR_PASSWORD:?HARBOR_PASSWORD is not set (state overlay or .env) — the engine cannot push to Harbor}"
HARBOR_INSECURE="${HARBOR_INSECURE:-0}"

WORK="${REPO_ROOT}/.jumpbox"
mkdir -p "$WORK"

# The kubeconfig the CONTAINER will use: `--internal` gives the address reachable from INSIDE the kind
# network (the host-facing one points at 127.0.0.1, which in the container is the container itself).
kind get kubeconfig --name "${KIND_CLUSTER_NAME:?}" --internal > "${WORK}/kubeconfig"

MOUNTS=()
ENVS=(
  -e "HARBOR_URL=${HARBOR_URL}"
  -e "HARBOR_INSECURE=${HARBOR_INSECURE}"
  -e "HARBOR_USERNAME=${HARBOR_USERNAME}"
  -e HARBOR_PASSWORD                      # NAME ONLY — the value is inherited from the environment,
                                          # never placed on argv where ps/procfs would expose it.
  -e GITEA_ADMIN_PASSWORD                 # ditto. B3: the air-gap half now runs the runbook's Step 4,
                                          # and 50-seed-gitea-repos.sh hard-requires this. It is NOT
                                          # generated in the container: `.env` is deliberately excluded
                                          # from the /src copy, .env.example ships it COMMENTED, and the
                                          # synthetic .env.state carries only HARBOR_*. 05-kind-up.sh
                                          # already state_set it on the HOST, so passing it through is
                                          # both the faithful shape (a real operator sets it in .env)
                                          # and the only one that works.
  -e "JUMPBOX_ENGINE=${JUMPBOX_ENGINE}"
  -e "JUMPBOX_OS=${JUMPBOX_OS}"
)

# The self-signed Harbor CA. MOUNT IT **AND NAME IT** — mounting alone was the original bug: the file
# was there and nothing inside knew where it was, so the engine could not trust Harbor.
if [ "$HARBOR_INSECURE" != "1" ] && [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "$HARBOR_CA_FILE" ]; then
  install -m 0644 "$HARBOR_CA_FILE" "${WORK}/harbor-ca.crt"   # 0644: a CA is PUBLIC trust material, and a
                                                              # 0600 one is unreadable by the container's uid
  MOUNTS+=(-v "${WORK}/harbor-ca.crt:/run/jumpbox/harbor-ca.crt:ro")
  ENVS+=(-e "HARBOR_CA_FILE=/run/jumpbox/harbor-ca.crt")
fi

# Optional: the licensed VCF CLIs, so the leg can prove `make install-vcf-clis` works on this OS.
if [ -n "$VCF_SRC" ] && [ -d "$VCF_SRC" ]; then
  MOUNTS+=(-v "$(cd "$VCF_SRC" && pwd):/run/vcf-artifacts:ro" -e VCF_CLI_SRC_DIR=/run/vcf-artifacts)
fi

# Optional: the sneakernet half — this container is a FRESH air-gap box holding ONLY the carried tarball.
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "JUMPBOX_TARBALL not found: ${TARBALL}"
  tb_abs="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
  # CARRY THE CHECKSUM TOO. The e2e used to mount ONLY the tarball — so it was not faithful to its own
  # runbook ("carry the tarball, its .sha256, and the repo"), and the far side could not verify what had
  # crossed the gap. bundle-load now REQUIRES the checksum (an archive that crossed removable media is
  # the one place a silent bit-flip is plausible), and it caught this the first time it ran.
  [ -f "${tb_abs}.sha256" ] || die "the bundle has no checksum beside it: ${tb_abs}.sha256
  'make bundle' writes it; the air-gap box requires it. Re-cut the bundle."
  MOUNTS+=(-v "${tb_abs}:/run/bundle/$(basename "$tb_abs"):ro"
           -v "${tb_abs}.sha256:/run/bundle/$(basename "$tb_abs").sha256:ro")
  ENVS+=(-e JUMPBOX_MODE=airgap-half -e "JUMPBOX_TARBALL=/run/bundle/$(basename "$tb_abs")")
  # Which end-of-work sentinel this run must print, decided HERE because this is where mode is
  # already decided. A second `if` elsewhere would be two places that must agree — an enumerated
  # list of two, which is enough to drift.
  EXPECT=JUMPBOX_SNEAKERNET_OK
  log_info "running ${JUMPBOX_OS} AIR-GAP jump box (sneakernet half) — Harbor=${HARBOR_URL}, tarball=$(basename "$tb_abs")"
else
  EXPECT=JUMPBOX_OK
  log_info "running ${JUMPBOX_OS} jump box · engine=${JUMPBOX_ENGINE} · Harbor=${HARBOR_URL} (insecure=${HARBOR_INSECURE})"
fi

export HARBOR_PASSWORD
export GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"
# The log is this control's evidence, and it must NOT live in ${WORK} (= ${REPO_ROOT}/.jumpbox):
# .gitleaks.toml allowlists `^\.jumpbox/`, so anything landing there is invisible to the repo's own
# secret scanner, and nothing ever cleans that directory. The container's environment carries
# HARBOR_PASSWORD and GITEA_ADMIN_PASSWORD, so a captured log is a standing hazard even though every
# known secret site today is redirected or uses --password-stdin. mktemp OUTSIDE the repo, 0600,
# removed on exit. (`exec` is what made a cleanup trap impossible before.)
RUNLOG="$(mktemp)"; chmod 600 "$RUNLOG"
trap 'rm -f "$RUNLOG"' EXIT

# NOT `exec` any more: exec replaces this process, so nothing downstream could inspect the result.
# Safe to drop -- there is no trap to destroy (the one above is the first), `--rm` is daemon-side,
# and there is no -t/-i, so stdout was already a pipe and no tty behaviour changes.
#
# The pipeline is the `if` CONDITION, so `set -e` does not abort it and its status is read directly
# -- no `rc=$?` on a following line, which under `set -euo pipefail` would be unreachable dead code
# that a later reader might "repair" with `|| true`, turning fail-closed into fail-open.
if ! docker run --rm --privileged --network kind \
  "${ENVS[@]}" \
  -v "${REPO_ROOT}:/src:ro" \
  -v "${WORK}/kubeconfig:/run/jumpbox/kubeconfig:ro" \
  "${MOUNTS[@]}" \
  "$JUMPBOX_IMAGE" bash /src/scripts/jumpbox-run.sh 2>&1 | tee "$RUNLOG"; then
  # pipefail makes this docker's status -- but `tee` can also fail (full disk, unwritable target),
  # which would fail a HEALTHY leg with a message pointing at the jump box instead of the harness.
  [ -s "$RUNLOG" ] || log_error "the run log is EMPTY: if the container produced output then 'tee' itself failed (full disk / unwritable ${RUNLOG}) and this leg's failure is the HARNESS, not the jump box."
  exit 1
fi

# The run exited 0. That says no command failed; it does not say the run reached its end.
assert_run_sentinel "$RUNLOG" "$EXPECT" || exit 1
