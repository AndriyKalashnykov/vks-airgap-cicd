#!/usr/bin/env bash
# jumpbox-run.sh — runs INSIDE the Photon 5 jump-box container (as user vks), launched by
# `make jumpbox`. Validates that the README jump-box instructions actually work on a real
# Photon 5 box that is connected to BOTH the internet and the KinD cluster:
#   1. make deps  — the jump-box toolchain installs (mise tools + crane/tkn/argocd via the
#                   prereqs script) on Photon 5. This is the dependency path the README promises.
#   2. rootless podman build + run — the README's preferred container engine works in isolation.
#   3. cluster reachability — the API server + Harbor are reachable from the kind Docker network
#                   via the INTERNAL kubeconfig (what a real jump box uses).
#
# A clean "JUMPBOX_OK" means the README bootstrap + `make deps` are correct for Photon 5.
set -euo pipefail

WORK="${HOME}/work"
rm -rf "$WORK"; mkdir -p "$WORK"
# Copy the read-only repo mount into a writable workspace (like a fresh clone); skip heavy /
# gitignored build outputs so the jump box starts clean.
tar -C /src --exclude='./.git' --exclude='./bundle' --exclude='./app/target' \
    --exclude='./apps/java/webui/target' --exclude='./.jumpbox' -cf - . | tar -C "$WORK" -xf -
cd "$WORK"

. /etc/os-release
echo "### jump box: ${PRETTY_NAME} · user=$(whoami) · engine=$(command -v podman) ###"

echo "### 1/3 make deps — install the jump-box toolchain on Photon 5 ###"
make deps
# Pick up the mise-installed shims in this shell.
eval "$(mise activate bash)" 2>/dev/null || true
hash -r
echo "toolchain present:"
for t in kubectl helm kustomize yq jq crane tkn argocd; do
  printf '  %-9s %s\n' "$t" "$(command -v "$t" || echo 'MISSING')"
done

echo "### 2/3 rootless podman build + run smoke, and crane (mirror engine, mise) ###"
ctx="$(mktemp -d)"
printf 'FROM photon:5.0\nRUN echo jumpbox-rootless-ok > /marker\n' > "${ctx}/Dockerfile"
podman build -t jb-smoke "$ctx" 2>&1 | tail -3
podman run --rm jb-smoke cat /marker
echo "crane (mirror engine): $(crane version 2>&1 | head -1)"

echo "### 3/3 cluster + Harbor reachability from the jump box (internal kubeconfig) ###"
export KUBECONFIG=/run/jumpbox/kubeconfig
kubectl get nodes -o wide
harbor_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${HARBOR_URL}/api/v2.0/systeminfo" 2>/dev/null || echo 000)"
echo "Harbor (${HARBOR_URL}) systeminfo -> HTTP ${harbor_code}"
[ "$harbor_code" = "200" ] || { echo "ERROR: Harbor not reachable from the jump box"; exit 1; }

echo "JUMPBOX_OK"
