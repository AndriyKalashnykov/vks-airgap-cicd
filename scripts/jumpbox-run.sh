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
echo "### jump box: ${PRETTY_NAME} · user=$(whoami) · engine=${ENGINE} ($(command -v "$ENGINE")) ###"

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
  } > "$WORK/.env.kind"
  chmod 600 "$WORK/.env.kind"
  if [ "${HARBOR_INSECURE:-0}" != "1" ] && [ -f /run/jumpbox/harbor-ca.crt ]; then
    mkdir -p secrets; cp /run/jumpbox/harbor-ca.crt secrets/harbor-ca.crt; chmod 0644 secrets/harbor-ca.crt
  fi

  echo "### make deps — install the mirror engine (crane) on this OS ###"
  make deps
  eval "$(mise activate bash)" 2>/dev/null || true; hash -r

  # Fidelity assert: the image cache MUST be empty here — nothing leaked from the host.
  if [ -n "$(ls -A bundle 2>/dev/null || true)" ]; then
    echo "ERROR: bundle/ is not empty in the air-gap box — host cache leaked (fidelity broken)"; exit 1
  fi

  echo "### bundle-load — reconstruct the image cache from ONLY the carried tarball ###"
  make bundle-load BUNDLE_TARBALL="$JUMPBOX_TARBALL"
  echo "### mirror-push — push the loaded images into the internal Harbor ###"
  make mirror-push
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
