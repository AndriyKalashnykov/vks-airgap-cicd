#!/usr/bin/env bash
# scripts/test-vcf-cli-darwin.sh — OFFLINE: 01-install-vcf-clis.sh on a macOS jump box (B735).
#
# test-vcf-cli-resolve.sh fixes its OS from the real host and SKIPS off linux/amd64, so it never
# exercises the Darwin archive names. This one fakes `uname` for BOTH -s and -m, so every case runs
# on any host. The fixture names and inner layout copy the real 9.1.1 downloads (MEASURED):
#   VCF-Consumption-CLI-Darwin_ARM64-<ver>.tar.gz              -> vcf-cli-darwin_arm64 at the root
#   VCF-Consumption-CLI-PluginBundle-Darwin_ARM64-<ver>.tar.gz -> <plugin>/<ver>/vcf-<plugin>-darwin_arm64
#   argocd-cli-darwin-amd64-<ver>.gz                            -> amd64 only; Broadcom ships no arm64
# A Linux archive sits beside each Darwin one, so a case passes only if the installer picks by OS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$SCRIPT_DIR/01-install-vcf-clis.sh"

# Pinned versions exactly as the installer sees them (SKIP_DOTENV=1: see test-vcf-cli-resolve.sh).
ev() {
  ( set -a; SKIP_DOTENV=1
    # shellcheck disable=SC1090,SC1091
    . "$REPO_ROOT/scripts/lib/os.sh" >/dev/null 2>&1; load_env >/dev/null 2>&1; set +a
    printf '%s' "${!1}" )
}
AV="$(ev ARGOCD_VCF_VERSION)"; VV="$(ev VCF_CLI_VERSION)"; PV="$(ev VCF_PLUGINS_VERSION)"
[ -n "$AV" ] && [ -n "$VV" ] && [ -n "$PV" ] || { echo "FATAL: could not read the pinned versions"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; }
mkfake() { { printf '#!/usr/bin/env bash\n'; printf 'echo "%s"\n' "$2"; } > "$1"; chmod +x "$1"; }

T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
# fake_uname <kernel> <machine> -> a dir whose `uname` answers like that box
fake_uname() {
  local dir="$T/uname-$1-$2"; mkdir -p "$dir"
  # shellcheck disable=SC2016  # $1 belongs to the generated script
  printf '#!/bin/sh\ncase "$1" in -m) echo %s ;; *) echo %s ;; esac\n' "$2" "$1" > "$dir/uname"
  chmod +x "$dir/uname"; printf '%s' "$dir"
}
# run_as <kernel> <machine> <what> <src> <bin> <errfile>
run_as() {
  local u; u="$(fake_uname "$1" "$2")"
  # shellcheck disable=SC2031  # os.sh assigns PATH on macOS only; this per-command PATH is intended
  PATH="$u:$PATH" SKIP_DOTENV=1 VCF_CLI_SRC_DIR="$4" BIN_DIR="$5" DRY_RUN=1 \
    bash "$INSTALLER" "$3" >/dev/null 2>"$6"
}
n=0
fresh() { n=$((n+1)); src="$T/src$n"; bin="$T/bin$n"; d="$T/d$n"; err="$T/err$n"; mkdir -p "$src" "$bin" "$d"; }
# pack <archive> <relative-binary-path> <marker> — a tar.gz holding one fake binary
pack() {
  local w="$T/w$RANDOM$RANDOM"; mkdir -p "$w/$(dirname "$2")"
  mkfake "$w/$2" "$3"; tar -C "$w" -czf "$1" "${2%%/*}"; rm -rf "$w"
}

echo "== vcf on darwin/arm64: picks the Darwin archive over a Linux one of the same version"
fresh
pack "$src/VCF-Consumption-CLI-Darwin_ARM64-${VV}.tar.gz" "vcf-cli-darwin_arm64" "VCF-DARWIN-ARM64"
pack "$src/VCF-Consumption-CLI-Linux_ARM64-${VV}.tar.gz"  "vcf-cli-linux_arm64"  "VCF-LINUX-ARM64"
if run_as Darwin arm64 vcf "$src" "$bin" "$err"; then
  got="$("$bin/vcf" 2>/dev/null || true)"
  if [ "$got" = VCF-DARWIN-ARM64 ]; then ok "installs the Darwin_ARM64 CLI"; else bad "installed [$got], want VCF-DARWIN-ARM64"; fi
else bad "vcf darwin: installer exited non-zero"; sed 's/^/      /' "$err"; fi

echo "== vcf on darwin/arm64: only a Linux archive present -> refused, naming what it looked for"
fresh
pack "$src/VCF-Consumption-CLI-Linux_ARM64-${VV}.tar.gz" "vcf-cli-linux_arm64" "VCF-LINUX-ARM64"
# The arch-blind FALLBACK glob (kept for a hypothetical agnostic bundle) DOES match this file, so
# resolve succeeds and the inner-name assertion is what refuses it. Either refusal is correct.
if run_as Darwin arm64 vcf "$src" "$bin" "$err"; then bad "installed a Linux CLI on darwin"
elif grep -qE 'vcf-cli-darwin_arm64 not found|no vcf artifact' "$err"; then ok "refuses the Linux archive on darwin"
else bad "failed with an unexpected error"; sed 's/^/      /' "$err"; fi

echo "== plugins on darwin/arm64: the Darwin bundle resolves and passes the OS+arch assertion"
fresh
mkfake "$bin/vcf" "VCF-STUB"
pack "$src/VCF-Consumption-CLI-PluginBundle-Darwin_ARM64-${PV}.tar.gz" "cluster/v3.7.1/vcf-cluster-darwin_arm64" "PLUGIN-DARWIN"
pack "$src/VCF-Consumption-CLI-PluginBundle-Linux_ARM64-${PV}.tar.gz"  "cluster/v3.7.1/vcf-cluster-linux_arm64"  "PLUGIN-LINUX"
if run_as Darwin arm64 plugins "$src" "$bin" "$err"; then ok "installs from the Darwin_ARM64 plugin bundle"
else bad "plugins darwin: installer exited non-zero"; sed 's/^/      /' "$err"; fi

echo "== plugins on darwin/arm64: a Darwin-NAMED bundle holding LINUX binaries -> refused"
fresh
mkfake "$bin/vcf" "VCF-STUB"
pack "$src/VCF-Consumption-CLI-PluginBundle-Darwin_ARM64-${PV}.tar.gz" "cluster/v3.7.1/vcf-cluster-linux_arm64" "PLUGIN-MISLABELED"
if run_as Darwin arm64 plugins "$src" "$bin" "$err"; then bad "installed a mislabeled bundle"
elif grep -q 'no darwin_arm64 binaries' "$err"; then ok "the OS+arch content assertion catches it"
else bad "failed with an unexpected error"; sed 's/^/      /' "$err"; fi

echo "== all on darwin/arm64 with no arm64 argocd: SKIPS argocd with a warning, installs vcf + plugins"
fresh
cp /dev/null "$src/argocd-cli-darwin-amd64-${AV}.gz"   # only the amd64 argocd, as Broadcom ships it
pack "$src/VCF-Consumption-CLI-Darwin_ARM64-${VV}.tar.gz" "vcf-cli-darwin_arm64" "VCF-DARWIN-ARM64"
pack "$src/VCF-Consumption-CLI-PluginBundle-Darwin_ARM64-${PV}.tar.gz" "cluster/v3.7.1/vcf-cluster-darwin_arm64" "PLUGIN-DARWIN"
if run_as Darwin arm64 all "$src" "$bin" "$err"; then
  if grep -q 'SKIPPING the VCF-flavored argocd' "$err" && [ ! -e "$bin/argocd" ] && [ "$("$bin/vcf" 2>/dev/null || true)" = VCF-DARWIN-ARM64 ]; then
    ok "argocd skipped (warned, not installed), vcf installed"
  else bad "all: rc 0 but skip/install state wrong"; sed 's/^/      /' "$err"; fi
else bad "all on darwin/arm64: installer exited non-zero"; sed 's/^/      /' "$err"; fi

echo "== argocd ALONE on darwin/arm64 still dies (an explicit request is not silently skipped)"
fresh
if run_as Darwin arm64 argocd "$src" "$bin" "$err"; then bad "argocd alone succeeded with no arm64 build"
elif grep -q 'amd64-only' "$err"; then ok "dies naming amd64-only"
else bad "failed with an unexpected error"; sed 's/^/      /' "$err"; fi

echo "== vcf on darwin/x86_64 (Intel Mac): picks Darwin_AMD64"
fresh
pack "$src/VCF-Consumption-CLI-Darwin_AMD64-${VV}.tar.gz" "vcf-cli-darwin_amd64" "VCF-DARWIN-AMD64"
pack "$src/VCF-Consumption-CLI-Darwin_ARM64-${VV}.tar.gz" "vcf-cli-darwin_arm64" "VCF-DARWIN-ARM64"
if run_as Darwin x86_64 vcf "$src" "$bin" "$err"; then
  got="$("$bin/vcf" 2>/dev/null || true)"
  if [ "$got" = VCF-DARWIN-AMD64 ]; then ok "installs the Darwin_AMD64 CLI"; else bad "installed [$got], want VCF-DARWIN-AMD64"; fi
else bad "vcf darwin amd64: installer exited non-zero"; sed 's/^/      /' "$err"; fi

echo "== vcf that cannot RUN -> a hard failure, not a warning"
fresh
w="$T/wbad"; mkdir -p "$w"; printf '#!/bin/sh\nexit 1\n' > "$w/vcf-cli-darwin_arm64"; chmod +x "$w/vcf-cli-darwin_arm64"
tar -C "$w" -czf "$src/VCF-Consumption-CLI-Darwin_ARM64-${VV}.tar.gz" vcf-cli-darwin_arm64
if run_as Darwin arm64 vcf "$src" "$bin" "$err"; then bad "a vcf that exits 1 was accepted"
elif grep -q 'does not run' "$err"; then ok "dies when the installed vcf does not run"
else bad "failed with an unexpected error"; sed 's/^/      /' "$err"; fi

echo "== an unsupported kernel is refused by name"
fresh
if run_as FreeBSD amd64 vcf "$src" "$bin" "$err"; then bad "FreeBSD accepted"
elif grep -q 'unsupported OS: FreeBSD' "$err"; then ok "dies naming the OS"
else bad "failed with an unexpected error"; sed 's/^/      /' "$err"; fi

echo
printf 'test-vcf-cli-darwin: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
