#!/usr/bin/env bash
# scripts/test-vcf-cli-resolve.sh — OFFLINE unit tests for scripts/01-install-vcf-clis.sh's
# archive RESOLVE + tar-vs-gz branch logic (resolve_archive + the install_* extract branches
# that pick the right binary out of an operator-supplied folder holding per-arch files AND/OR
# multi-arch "…-Binaries…" bundles). This logic only breaks on a real lab box today.
#
# NO network, NO real downloads: synthetic fixtures + FAKE binaries only. The installer has no
# `main`-guard (it runs load_env + a dispatch case at the top level), so it can't be sourced in
# isolation — we DRIVE it as a subprocess against a fixture VCF_CLI_SRC_DIR + a throwaway
# BIN_DIR and assert the CORRECT binary landed. DRY_RUN=1 stubs the one mutating call
# (`vcf plugin install`), and a fake `vcf` binary stands in for the plugins path's prerequisite,
# so `plugins` resolve + arch-safety is exercised offline too. Each fake binary is a shell script
# that echoes a unique MARKER, so running the installed binary proves WHICH source archive / arch
# resolve_archive selected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$SCRIPT_DIR/01-install-vcf-clis.sh"

# Fixtures use this host's OS/arch tokens (the installer derives them from uname). The
# vendor filename scheme is linux-only, so skip honestly on a non-linux/amd64 host.
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64|Linux/amd64) os=linux; arch=amd64; ARCH=AMD64 ;;
  *) echo "SKIP: fixtures target linux/amd64; host is $(uname -s)/$(uname -m)"; exit 0 ;;
esac

# Effective pinned versions the installer will use (same resolution order as load_env:
# .env.example → .env → .env.kind) so fixture filenames never rot against the source of truth.
ev() {
  ( set -a
    # shellcheck disable=SC1090,SC1091
    . "$REPO_ROOT/.env.example"
    # shellcheck disable=SC1090,SC1091
    [ -f "$REPO_ROOT/.env" ]      && . "$REPO_ROOT/.env"
    # shellcheck disable=SC1090,SC1091
    [ -f "$REPO_ROOT/.env.kind" ] && . "$REPO_ROOT/.env.kind"
    set +a
    printf '%s' "${!1}" )
}
AV="$(ev ARGOCD_VCF_VERSION)"
VV="$(ev VCF_CLI_VERSION)"
PV="$(ev VCF_PLUGINS_VERSION)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3], got [$2])"; fi; }

# mkfake DEST MARKER — write an executable fake binary that echoes MARKER (for any args).
mkfake() { { printf '#!/usr/bin/env bash\n'; printf 'echo "%s"\n' "$2"; } > "$1"; chmod +x "$1"; }

# run_installer WHAT SRC BIN ERRFILE — drive the installer offline; returns its exit status.
run_installer() {
  VCF_CLI_SRC_DIR="$2" BIN_DIR="$3" DRY_RUN=1 bash "$INSTALLER" "$1" >/dev/null 2>"$4"
}

# Per-case scratch (reused; each case cleans up at the end). Registered for the exit trap too.
src=""; bin=""; d=""; fb=""; err=""
cleanup() { rm -rf "$src" "$bin" "$d" "$fb" "$err" 2>/dev/null || true; }
trap cleanup EXIT
fresh() { cleanup; src="$(mktemp -d)"; bin="$(mktemp -d)"; d="$(mktemp -d)"; fb="$(mktemp)"; err="$(mktemp)"; }

echo "== argocd: bare .gz-of-a-binary → gunzip branch (tar-vs-gz detects a NON-tar gzip) =="
fresh
mkfake "$fb" "ARGOCD-BARE-AMD64"
gzip -c "$fb" > "${src}/argocd-cli-${os}-${arch}-${AV}.gz"      # exact vendor name, .gz of the binary
if run_installer argocd "$src" "$bin" "$err"; then
  eq "installs the argocd binary from a bare .gz" "$("$bin/argocd" 2>/dev/null || true)" "ARGOCD-BARE-AMD64"
else
  bad "argocd bare .gz: installer exited non-zero"; sed 's/^/      /' "$err"
fi

echo "== argocd: .tar.gz bundle (glob resolve) → tar branch (find argocd inside) =="
fresh
mkfake "$d/argocd" "ARGOCD-BUNDLE"
# No exact-name .gz present → resolve_archive must use the version glob; a .tar.gz matches it.
tar -C "$d" -czf "${src}/argocd-cli-${os}-${arch}-${AV}-Binaries.tar.gz" argocd
if run_installer argocd "$src" "$bin" "$err"; then
  eq "resolves via glob + extracts argocd from the bundle" "$("$bin/argocd" 2>/dev/null || true)" "ARGOCD-BUNDLE"
else
  bad "argocd bundle: installer exited non-zero"; sed 's/^/      /' "$err"
fi

echo "== vcf: flat .tar.gz (exact vendor name) → binary at archive root =="
fresh
mkfake "$d/vcf-cli-${os}_${arch}" "VCF-FLAT-AMD64"
tar -C "$d" -czf "${src}/VCF-Consumption-CLI-Linux_${ARCH}-${VV}.tar.gz" "vcf-cli-${os}_${arch}"
if run_installer vcf "$src" "$bin" "$err"; then
  eq "installs vcf from a flat tarball" "$("$bin/vcf" 2>/dev/null || true)" "VCF-FLAT-AMD64"
else
  bad "vcf flat tarball: installer exited non-zero"; sed 's/^/      /' "$err"
fi

echo "== vcf: nested multi-arch bundle → picks THIS arch at depth (discriminates amd64 vs arm64) =="
fresh
mkdir -p "$d/linux/amd64/v9" "$d/linux/arm64/v9"
mkfake "$d/linux/amd64/v9/vcf-cli-${os}_amd64" "VCF-NESTED-AMD64"
mkfake "$d/linux/arm64/v9/vcf-cli-${os}_arm64" "VCF-NESTED-ARM64"
# No exact-name file → glob matches the multi-arch "…-Binaries…" bundle.
tar -C "$d" -czf "${src}/VCF-Consumption-CLI-Binaries-${VV}.tar.gz" linux
if run_installer vcf "$src" "$bin" "$err"; then
  eq "picks the ${arch} binary from the nested bundle (NOT arm64)" "$("$bin/vcf" 2>/dev/null || true)" "VCF-NESTED-AMD64"
else
  bad "vcf nested bundle: installer exited non-zero"; sed 's/^/      /' "$err"
fi

echo "== NEGATIVE: wrong-arch-only bundle → resolve extracts but the ${arch} binary is absent (die) =="
fresh
mkfake "$d/vcf-cli-${os}_arm64" "VCF-ARM64-ONLY"                # NO amd64 binary in the archive
tar -C "$d" -czf "${src}/VCF-Consumption-CLI-Linux_${ARCH}-${VV}.tar.gz" "vcf-cli-${os}_arm64"
if run_installer vcf "$src" "$bin" "$err"; then
  bad "wrong-arch-only bundle: installer should FAIL (no ${arch} binary) but succeeded"
elif grep -q "not found inside the archive" "$err"; then
  ok "fails cleanly when the archive holds no ${arch} binary (proves arch discrimination)"
else
  bad "wrong-arch-only bundle: failed but with an unexpected error"; sed 's/^/      /' "$err"
fi

echo "== NEGATIVE: empty VCF_CLI_SRC_DIR → resolve_archive dies (no artifact) =="
fresh
if run_installer vcf "$src" "$bin" "$err"; then          # src is an empty dir
  bad "empty source dir: installer should FAIL but succeeded"
elif grep -q "no vcf artifact" "$err"; then
  ok "resolve_archive dies with an actionable 'no vcf artifact' message"
else
  bad "empty source dir: failed but with an unexpected error"; sed 's/^/      /' "$err"
fi

echo "== plugins: correct-arch bundle → resolves, arch-asserts, installs (plugin install stubbed) =="
fresh
mkfake "$bin/vcf" "VCF-STUB"                                     # install_vcf_plugins needs vcf present
mkdir -p "$d/cluster/v3.7.0"
mkfake "$d/cluster/v3.7.0/vcf-cluster-linux_${arch}" "PLUGIN-${ARCH}"
tar -C "$d" -czf "${src}/VCF-Consumption-CLI-PluginBundle-Linux_${ARCH}-${PV}.tar.gz" cluster
if run_installer plugins "$src" "$bin" "$err"; then
  ok "installs from the correct-arch (Linux_${ARCH}) plugin bundle"
else
  bad "correct-arch plugin bundle: installer exited non-zero"; sed 's/^/      /' "$err"
fi

echo "== NEGATIVE plugins: only the WRONG-arch bundle present → arch-bound glob refuses it (die) =="
fresh
mkfake "$bin/vcf" "VCF-STUB"
mkdir -p "$d/cluster/v3.7.0"
mkfake "$d/cluster/v3.7.0/vcf-cluster-linux_arm64" "PLUGIN-ARM64"
# ONLY the ARM64-named bundle present; the exact AMD64 name is absent → resolve falls to the glob,
# which (arch-bound) must NOT match the ARM64 file. Without the fix an arch-blind glob would pick it.
tar -C "$d" -czf "${src}/VCF-Consumption-CLI-PluginBundle-Linux_ARM64-${PV}.tar.gz" cluster
if run_installer plugins "$src" "$bin" "$err"; then
  bad "wrong-arch-only plugin folder: installer should FAIL (no ${arch} bundle) but succeeded"
elif grep -q "no plugins artifact" "$err"; then
  ok "arch-bound glob refuses the wrong-arch plugin bundle (fails safe, no mis-install)"
else
  bad "wrong-arch-only plugin folder: failed but with an unexpected error"; sed 's/^/      /' "$err"
fi

echo "== NEGATIVE plugins: correct-arch FILENAME but wrong-arch CONTENTS → pre-install arch assertion (die) =="
fresh
mkfake "$bin/vcf" "VCF-STUB"
mkdir -p "$d/cluster/v3.7.0"
mkfake "$d/cluster/v3.7.0/vcf-cluster-linux_arm64" "PLUGIN-MISLABELED"   # arm64 contents…
# …inside an AMD64-named bundle: exact-name matches so resolve SUCCEEDS; only the arch assertion catches it.
tar -C "$d" -czf "${src}/VCF-Consumption-CLI-PluginBundle-Linux_${ARCH}-${PV}.tar.gz" cluster
if run_installer plugins "$src" "$bin" "$err"; then
  bad "mislabeled plugin bundle: installer should FAIL (no ${arch} contents) but succeeded"
elif grep -q "no linux_${arch} binaries" "$err"; then
  ok "pre-install arch assertion catches a mislabeled (wrong-content) plugin bundle"
else
  bad "mislabeled plugin bundle: failed but with an unexpected error"; sed 's/^/      /' "$err"
fi

echo
printf 'test-vcf-cli-resolve: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
