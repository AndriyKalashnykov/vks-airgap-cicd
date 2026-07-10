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
tar -C /src --exclude='./.git' --exclude='./.env' --exclude='./.env.kind' \
    --exclude='./secrets' --exclude='./bundle' \
    --exclude='./app/target' --exclude='./apps/java/webui/target' --exclude='./.jumpbox' \
    -cf - . | tar -C "$WORK" -xf -
cd "$WORK"

. /etc/os-release
# Container engine — mirror the repo's CONTAINER_ENGINE (podman-preferred, docker fallback);
# override with JUMPBOX_ENGINE. This harness targets the README's rootless-podman path.
ENGINE="${JUMPBOX_ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}"
echo "### jump box: ${PRETTY_NAME} · user=$(whoami) · engine=${ENGINE} ($(command -v "$ENGINE")) ###"

echo "### 1/3 make deps — install the jump-box toolchain on this OS ###"
make deps
# Pick up the mise-installed shims in this shell.
eval "$(mise activate bash)" 2>/dev/null || true
hash -r
echo "toolchain present:"
for t in kubectl helm kustomize yq jq crane tkn argocd; do
  printf '  %-9s %s\n' "$t" "$(command -v "$t" || echo 'MISSING')"
done

echo "### 2/3 rootless ${ENGINE} build + run smoke, and crane (mirror engine, mise) ###"
ctx="$(mktemp -d)"
# A short-named base (alpine) exercises unqualified-search-registries resolution + a rootless
# overlay build — the exact things Photon's podman lacks by default — on either OS variant.
printf 'FROM alpine:3\nRUN echo jumpbox-rootless-ok > /marker\n' > "${ctx}/Dockerfile"
"$ENGINE" build -t jb-smoke "$ctx" 2>&1 | tail -3
"$ENGINE" run --rm jb-smoke cat /marker
echo "crane (mirror engine): $(crane version 2>&1 | head -1)"

echo "### 3/3 cluster + Harbor reachability from the jump box (internal kubeconfig) ###"
export KUBECONFIG=/run/jumpbox/kubeconfig
kubectl get nodes -o wide
harbor_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${HARBOR_URL}/api/v2.0/systeminfo" 2>/dev/null || echo 000)"
echo "Harbor (${HARBOR_URL}) systeminfo -> HTTP ${harbor_code}"
[ "$harbor_code" = "200" ] || { echo "ERROR: Harbor not reachable from the jump box"; exit 1; }

echo "JUMPBOX_OK"
