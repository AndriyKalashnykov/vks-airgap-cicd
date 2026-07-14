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
: "${HARBOR_USERNAME:?}"
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
  MOUNTS+=(-v "${tb_abs}:/run/bundle/$(basename "$tb_abs"):ro")
  ENVS+=(-e JUMPBOX_MODE=airgap-half -e "JUMPBOX_TARBALL=/run/bundle/$(basename "$tb_abs")")
  log_info "running ${JUMPBOX_OS} AIR-GAP jump box (sneakernet half) — Harbor=${HARBOR_URL}, tarball=$(basename "$tb_abs")"
else
  log_info "running ${JUMPBOX_OS} jump box · engine=${JUMPBOX_ENGINE} · Harbor=${HARBOR_URL} (insecure=${HARBOR_INSECURE})"
fi

export HARBOR_PASSWORD
exec docker run --rm --privileged --network kind \
  "${ENVS[@]}" \
  -v "${REPO_ROOT}:/src:ro" \
  -v "${WORK}/kubeconfig:/run/jumpbox/kubeconfig:ro" \
  "${MOUNTS[@]}" \
  "$JUMPBOX_IMAGE" bash /src/scripts/jumpbox-run.sh
