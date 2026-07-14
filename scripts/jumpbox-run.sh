#!/usr/bin/env bash
# jumpbox-run.sh — runs INSIDE the jump-box container (Photon OS or Ubuntu, per JUMPBOX_OS),
# as user vks, launched by `make jumpbox`. Validates that the README jump-box instructions
# actually work on a real box connected to BOTH the internet and the KinD cluster:
#   1. make deps  — the jump-box toolchain installs (mise tools + crane/tkn/argocd via the
#                   prereqs script) on this OS. This is the dependency path the README promises.
#   2. rootless engine build + run — the README's preferred container engine works in isolation.
#   3. cluster reachability — the API server + Harbor are reachable from the kind Docker network
#                   via the INTERNAL kubeconfig (what a real jump box uses).
#
# A clean "JUMPBOX_OK" means the README bootstrap + `make deps` are correct for this OS.
set -euo pipefail

WORK="${HOME}/work"
rm -rf "$WORK"; mkdir -p "$WORK"
# Copy the read-only repo mount into a writable workspace (like a fresh clone), EXCLUDING every
# gitignored operator-local file: `.env` / `.env.kind` (host-specific paths like a host KUBECONFIG,
# plus whatever perms the KinD flow leaves — often 0600) and `./secrets` (mode 0600 tokens). A real
# `git clone` never has any of them, the harness doesn't need them (it gets the kubeconfig via the
# docker mount at /run/jumpbox and HARBOR_URL via -e), and on a base whose default user already holds
# uid 1000 (ubuntu:24.04/26.04 ship a `ubuntu` user there) the container's `vks` lands on uid 1001 and
# cannot read the 0600 files — so copying them fails the tar. `.env.example` is KEPT (load_env needs it).
# NB: GNU tar's --exclude-vcs-ignores is NOT usable here — it ignores git's leading-slash-anchored
# patterns (`/secrets/`, `/bundle/`), verified on this repo — so the excludes are explicit.
# The `.env*` excludes are DERIVED from what is actually on disk, not enumerated. The enumerated list
# is exactly what rotted: it named `./.env` and `./.env.kind`, then #192 renamed the sink to
# `.env.state` — and the ubuntu leg started dying with
#     tar: ./.env.state: Cannot open: Permission denied
# because that 0600 file is owned by the host's uid 1000 and the container's `vks` is uid 1001. The
# comment above described this trap perfectly and the list still went stale. Deriving it means the
# next rename cannot reintroduce the bug. (`.env.example` is KEPT — load_env needs it.)
EXCL="$(mktemp)"
{
  printf './.git\n./secrets\n./bundle\n*/target\n./.jumpbox\n'
  ( cd /src && find . -maxdepth 1 -name '.env*' ! -name '.env.example' -print )
} > "$EXCL"
tar -C /src --exclude-from="$EXCL" -cf - . | tar -C "$WORK" -xf -
rm -f "$EXCL"
cd "$WORK"

. /etc/os-release
# Container engine — mirror the repo's CONTAINER_ENGINE (podman-preferred, docker fallback);
# override with JUMPBOX_ENGINE. This harness targets the README's rootless-podman path.
ENGINE="${JUMPBOX_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
# EXPORT IT. This file is a SECOND engine chooser: `make deps` and 16-engine-trust-check inside the box
# call container_engine() (lib/os.sh), a THIRD one. On a one-engine image the two agree by luck; the day
# an image carries both, the harness would print engine=docker in its banner while the work underneath
# ran on podman — a leg reporting an engine it never used. One choice, exported, so they cannot diverge.
export CONTAINER_ENGINE="$ENGINE"
echo "### jump box: ${PRETTY_NAME} · user=$(whoami) · engine=${ENGINE} ($(command -v "$ENGINE")) ###"

# ASSERT the image is single-engine. The banner above is only honest if the OTHER engine is absent:
# container_engine() prefers podman whenever it is present, so a docker leg on a both-engines image
# silently runs podman and looks green. Fail loudly rather than measure the wrong engine.
_other="podman"; [ "$ENGINE" = podman ] && _other="docker"
if command -v "$_other" >/dev/null 2>&1; then
  echo "FATAL: this image has BOTH engines (${ENGINE} and ${_other}). A matrix leg must run the engine it" >&2
  echo "       claims: container_engine() prefers podman when present, so a 'docker' leg here would run" >&2
  echo "       PODMAN and report a green that measured the wrong engine. Build a single-engine image." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# MODE=airgap-half — the AIR-GAP half of the two-box sneakernet (make e2e-sneakernet).
# This container is a FRESH air-gap box: it has ONLY the carried bundle tarball (the
# repo's ./bundle cache was excluded from the /src copy above) plus the target Harbor's
# coordinates + push creds (via -e, exactly what a real air-gap operator carries in .env).
# It reconstructs the image cache PURELY from the tarball, then pushes + integrity-verifies
# it into the internal Harbor. This is the faithful two-box run that the same-machine
# relocate-sim could not exercise (it never left the host, hiding host-state leakage).
# ---------------------------------------------------------------------------
if [ "${JUMPBOX_MODE:-validate}" = "airgap-half" ]; then
  echo "### two-box sneakernet — AIR-GAP half (fresh box; cache comes ONLY from the carried tarball) ###"
  : "${HARBOR_URL:?HARBOR_URL must be passed to the air-gap box (-e)}"
  : "${JUMPBOX_TARBALL:?JUMPBOX_TARBALL must point at the carried bundle tarball}"
  [ -f "$JUMPBOX_TARBALL" ] || { echo "ERROR: carried tarball not found: $JUMPBOX_TARBALL"; exit 1; }

  # Reconstruct the Harbor coordinates the host's .env.kind would carry, so load_env
  # resolves the KinD Harbor LB IP + creds (NOT the .env.example placeholder harbor.vks.local).
  # 0600 + inside the ephemeral container only; the password arrived via -e (name only), not argv.
  {
    printf 'HARBOR_URL=%s\n'      "$HARBOR_URL"
    printf 'HARBOR_INSECURE=%s\n' "${HARBOR_INSECURE:-0}"
    printf 'HARBOR_USERNAME=%s\n' "${HARBOR_USERNAME:-admin}"
    [ -n "${HARBOR_PASSWORD:-}" ] && printf 'HARBOR_PASSWORD=%s\n' "$HARBOR_PASSWORD"
    printf 'HARBOR_CA_FILE=./secrets/harbor-ca.crt\n'
    # `.env.state`, NOT `.env.kind` — the sink was renamed in #192, and writing the legacy name made
    # load_env emit "reading legacy .env.kind" on every sneakernet run. Sixth site of that rename's rot.
  } > "$WORK/.env.state"
  chmod 600 "$WORK/.env.state"
  if [ "${HARBOR_INSECURE:-0}" != "1" ] && [ -f /run/jumpbox/harbor-ca.crt ]; then
    mkdir -p secrets; cp /run/jumpbox/harbor-ca.crt secrets/harbor-ca.crt; chmod 0644 secrets/harbor-ca.crt
  fi

  # NO `make deps` HERE. THAT WAS THE LIE.
  #
  # This box is supposed to be AIR-GAPPED. Running `make deps` downloaded crane from the internet (via
  # mise), so the e2e proved the opposite of its own name: the image cache was genuinely carried, and the
  # TOOLCHAIN was quietly fetched over the network. A real operator, on a box with no route out, would have
  # got `crane: command not found` at `make mirror-push` — after carrying an 11 GB tarball across the gap.
  #
  # The toolchain now comes from the BUNDLE (11-bundle.sh stages crane; 20-bundle-load.sh installs it).
  # Removing this line is what makes this e2e a real test: if the bundle stops carrying crane, the
  # air-gap half dies here, exactly as a real operator would.
  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v crane >/dev/null 2>&1; then
    echo "FATAL: crane is ALREADY on this 'air-gapped' box before the bundle was loaded — the fidelity of"
    echo "       this test depends on it NOT being here. Something installed it (a stale image layer, a"
    echo "       leaked mount). Fix that, or this leg proves nothing."
    exit 1
  fi
  echo "### air-gap box: NO internet toolchain. crane must come from the carried bundle. ###"

  # Fidelity assert: the image cache MUST be empty here — nothing leaked from the host.
  if [ -n "$(ls -A bundle 2>/dev/null || true)" ]; then
    echo "ERROR: bundle/ is not empty in the air-gap box — host cache leaked (fidelity broken)"; exit 1
  fi

  # THE RUNBOOK'S OWN PRE-CARRY GATE — and until 2026-07-14 NOTHING RAN IT.
  # docs/sneakernet.md Step 0b tells the operator to run exactly this BEFORE carrying 12 GB across a room,
  # and calls it "the cheapest failure available". `grep -c check-tools scripts/jumpbox-run.sh` was 0: the
  # doc staked its safety gate on a command no test had ever executed, so a regression in the CARRIED
  # classification or the PRE-CARRY exit path would ship silently. Now the harness runs the doc's command,
  # on the doc's box, at the doc's moment.
  #
  # It must PASS here: the five carried tools are legitimately absent (the bundle brings them), and every
  # OS package the tarball cannot carry is present on this image.
  echo "### check-tools (PRE-CARRY) — the runbook's Step 0b gate, on the air-gap box, before the carry ###"
  make check-tools CHECK_TOOLS_PHASE=pre-carry

  echo "### bundle-load — reconstruct the image cache from ONLY the carried tarball ###"
  make bundle-load BUNDLE_TARBALL="$JUMPBOX_TARBALL"

  # And the doc's OTHER claim (Step 3): "After bundle-load, run a plain `make check-tools`: it must be
  # FULLY CLEAN. That run is the one that proves this box can actually run the install." Assert it.
  echo "### check-tools (DEFAULT) — after bundle-load it must be FULLY clean: the box can run the install ###"
  make check-tools

  echo "### mirror-push — push the loaded images into the internal Harbor ###"
  make mirror-push

  # THE OFFLINE MAVEN BUILDER. This box has NO INTERNET and NO CONTAINER ENGINE — it pushes the builder
  # that the INTERNET box built and the bundle carried, using the carried crane. Before the split,
  # `make builder-image` needed Maven Central AND Harbor in one command, so NEITHER sneakernet box could
  # run it: the air-gapped Java build simply could not be produced. This leg is what proves it now can.
  echo "### builder-push — push the CARRIED Maven builder into Harbor (no internet; crane, not an engine) ###"
  make builder-push

  echo "### mirror-verify — integrity-check Harbor's copy (the sneakernet assertion) ###"
  make mirror-verify
  echo "JUMPBOX_SNEAKERNET_OK"
  exit 0
fi

echo "### 1/4 make deps — install the jump-box toolchain on this OS ###"
make deps
# Pick up the mise-installed shims in this shell.
eval "$(mise activate bash)" 2>/dev/null || true
hash -r
echo "toolchain present:"
for t in kubectl helm kustomize yq jq crane tkn argocd; do
  printf '  %-9s %s\n' "$t" "$(command -v "$t" || echo 'MISSING')"
done

echo "### 2/4 rootless ${ENGINE} build + run smoke, and crane (mirror engine, mise) ###"
# DOCKER LEGS: bring up a ROOTLESS daemon, as the `vks` user, and MEASURE that it really is rootless.
# (podman is daemonless — nothing to start, which is precisely why it is the default.)
if [ "$ENGINE" = docker ]; then
  _uid="$(id -u)"                                # derived; it is 1001 on ubuntu:26.04 (a default `ubuntu`
  export XDG_RUNTIME_DIR="/run/user/${_uid}"     # user already holds 1000) — never hardcode it
  export DOCKER_HOST="unix://${XDG_RUNTIME_DIR}/docker.sock"
  command -v dockerd-rootless.sh >/dev/null 2>&1 \
    || { echo "FATAL: dockerd-rootless.sh not on PATH — 'make deps' should have installed/symlinked it"; exit 1; }
  echo "starting ROOTLESS dockerd as $(whoami) (uid $(id -u))"
  setsid dockerd-rootless.sh --storage-driver=fuse-overlayfs >/tmp/dockerd.log 2>&1 &
  for _ in $(seq 1 45); do docker info >/dev/null 2>&1 && break; sleep 1; done   # docker-ok: this harness's engine IS docker on this leg, by explicit operator choice (JUMPBOX_ENGINE=docker)
  docker info >/dev/null 2>&1 || { echo "FATAL: rootless dockerd did not start:"; tail -20 /tmp/dockerd.log; exit 1; }  # docker-ok: same
  # MEASURE it — do not assert it. The PROCESS OWNER is ground truth; SecurityOptions is derived from it.
  dpid="$(pgrep -x dockerd | head -1)"
  downer="$(ps -o user= -p "$dpid" | tr -d ' ')"
  droot="$(docker info --format '{{.DockerRootDir}}')"   # docker-ok: same
  echo "  dockerd owner    = ${downer}   (must NOT be root — else the sudo column is unmeasurable)"
  echo "  DockerRootDir    = ${droot}"
  echo "  docker info Name = $(docker info --format '{{.Name}}')  (must be THIS container: $(hostname))"  # docker-ok: same
  [ "$downer" != root ] || { echo "FATAL: dockerd is running as ROOT — this leg would report sudo=NO for a path that costs one"; exit 1; }
  case "$droot" in "$HOME"/*) : ;; *) echo "FATAL: DockerRootDir ${droot} is not under \$HOME — that is not a rootless daemon"; exit 1 ;; esac
fi
ctx="$(mktemp -d)"
# A short-named base (alpine) exercises unqualified-search-registries resolution + a rootless
# overlay build — the exact things Photon's podman lacks by default — on either OS variant.
printf 'FROM alpine:3\nRUN echo jumpbox-rootless-ok > /marker\n' > "${ctx}/Dockerfile"
"$ENGINE" build -t jb-smoke "$ctx" 2>&1 | tail -3
"$ENGINE" run --rm jb-smoke cat /marker
echo "crane (mirror engine): $(crane version 2>&1 | head -1)"

echo "### 3/4 cluster + Harbor reachability from the jump box (internal kubeconfig) ###"
export KUBECONFIG=/run/jumpbox/kubeconfig
kubectl get nodes -o wide
# TLS-mode-aware: secure Harbor (HARBOR_INSECURE=0, the lab-faithful default) serves HTTPS
# on the LB IP with a self-signed cert we must trust via the mounted CA; insecure = plain HTTP.
if [ "${HARBOR_INSECURE:-0}" = "1" ]; then
  harbor_scheme=http; harbor_ca_args=()
else
  harbor_scheme=https; harbor_ca_args=()
  [ -f /run/jumpbox/harbor-ca.crt ] && harbor_ca_args=(--cacert /run/jumpbox/harbor-ca.crt)
fi
harbor_code="$(curl -s -o /dev/null -w '%{http_code}' "${harbor_ca_args[@]}" --max-time 10 \
  "${harbor_scheme}://${HARBOR_URL}/api/v2.0/systeminfo" 2>/dev/null || echo 000)"
echo "Harbor (${harbor_scheme}://${HARBOR_URL}) systeminfo -> HTTP ${harbor_code}"
[ "$harbor_code" = "200" ] || { echo "ERROR: Harbor not reachable from the jump box over ${harbor_scheme}"; exit 1; }

# --- THE ENGINE ACTUALLY PUSHING TO HARBOR -------------------------------------------------------
# Until now this harness NEVER exercised an engine against Harbor: it built from alpine:3 on docker.io
# and merely CURLED Harbor. So the disputed step — "can this engine, on this OS, trust a self-signed
# registry and push to it" — was untested for docker AND for podman. curl proves the network and the CA
# for *curl*; it proves nothing about what the ENGINE's daemon (or podman's per-command --cert-dir) does.
#
# 16-engine-trust-check.sh is the whole registry-TLS surface — login + pull + build + push + a `crane
# validate --remote` pull-back — in ~60s, pushing a UNIQUE tag. We run THAT, not `make builder-image`:
# builder-image would take ~20 min baking a Maven cache (which tests `mvn` reaching Maven Central inside
# the build, not the engine) and would overwrite the SHARED builder tag the real pipeline consumes, from
# four matrix legs, leaving the infra project in an unattributable state.
if [ -n "${HARBOR_PASSWORD:-}" ]; then
  echo "### 5/5 ${ENGINE} -> Harbor: login + pull + build + push + verify (the disputed step) ###"
  make engine-trust-check
else
  echo "### 5/5 SKIPPED — no HARBOR_PASSWORD in this container, so the engine never touches Harbor."
  echo "###      That is the ONE claim this harness exists to prove. Do not read this run as proof."
  exit 1
fi

# 4/4 — OPTIONAL: install the VCF/VKS lab CLIs (argocd-vcf + vcf + plugins) when the operator
# mounts the licensed artifacts (VCF_CLI_SRC_DIR). Proves the install targets work on THIS OS.
if [ -n "${VCF_CLI_SRC_DIR:-}" ] && [ -d "${VCF_CLI_SRC_DIR}" ] && [ -n "$(ls -A "${VCF_CLI_SRC_DIR}" 2>/dev/null)" ]; then
  echo "### 4/4 VCF/VKS lab CLIs (argocd-vcf + vcf + plugins) from mounted artifacts ###"
  make install-vcf-clis
  export PATH="${HOME}/.local/bin:${PATH}"; hash -r
  echo "installed lab CLIs:"
  argocd version --client 2>&1 | head -1
  vcf version 2>&1 | head -1
  vcf plugin list 2>&1 | tail -6
else
  echo "### 4/4 VCF lab CLIs SKIPPED (no VCF_CLI_SRC_DIR mounted — set JUMPBOX_VCF_SRC) ###"
fi

echo "JUMPBOX_OK"
