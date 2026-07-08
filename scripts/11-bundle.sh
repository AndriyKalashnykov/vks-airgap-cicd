#!/usr/bin/env bash
# 11-bundle.sh — (SNEAKERNET) package the pulled image cache + install manifests
# into a single transferable archive to carry into the air gap.
#
# The archive contains $BUNDLE_DIR (images/ OCI cache + manifests/). Carry the git
# repo itself separately (git clone / copy) — it holds the scripts, Makefile, and
# k8s/Tekton/ArgoCD assets the inside host runs. On the air-gapped host, run
# 20-bundle-load.sh, then 21-mirror-push.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

: "${BUNDLE_DIR:?}"
[ -d "${BUNDLE_DIR}/images" ] || die "no image cache at ${BUNDLE_DIR}/images — run 'make mirror-pull' first"

OUT_DIR="${BUNDLE_OUT_DIR:-$REPO_ROOT}"
stamp="$(date -u +%Y%m%d-%H%M%S)"
base="vks-cicd-bundle-${stamp}"

# Prefer zstd (fast, small); fall back to gzip.
if have zstd; then
  tarball="${OUT_DIR}/${base}.tar.zst"
  comp=(--zstd)
else
  tarball="${OUT_DIR}/${base}.tar.gz"
  comp=(--gzip)
  log_warn "zstd not found — using gzip (larger/slower)"
fi

log_info "creating bundle $tarball from $BUNDLE_DIR"
# -C the parent so the archive unpacks to a predictable 'bundle/' dir name.
run tar -C "$(dirname "$BUNDLE_DIR")" "${comp[@]}" \
  -cf "$tarball" "$(basename "$BUNDLE_DIR")"

if have sha256sum; then
  ( cd "$(dirname "$tarball")" && sha256sum "$(basename "$tarball")" > "${tarball}.sha256" )
  log_info "checksum: $(cat "${tarball}.sha256")"
fi

size="$(du -h "$tarball" | cut -f1)"
log_info "bundle ready: $tarball ($size)"
log_info "carry it (and this git repo) into the air gap, then: make bundle-load BUNDLE_TARBALL=$tarball && make mirror-push"
