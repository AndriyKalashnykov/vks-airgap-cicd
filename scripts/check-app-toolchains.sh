#!/usr/bin/env bash
# check-app-toolchains.sh — every app's language toolchain MUST be pinned in .mise.toml.
#
# WHY: `make app-test` and `make trivy-fs` build/test/scan EVERY app. CI gets its toolchain from
# .mise.toml (mise-action) and NOTHING else. So a language whose tools are not pinned there:
#   - cannot be tested on a clean runner (the tests silently never run, or the job dies), and
#   - cannot be SCANNED (a Go binary's stdlib CVEs are only visible in the built artifact),
# while passing on any dev box that happens to have the toolchain installed.
#
# That is exactly what happened: a Go app was added, `go` was never pinned, CI's static-check went
# RED — and it turned out CI had been compiling the binary with an OLD toolchain pulled from the
# go.mod directive, carrying a stdlib CVE. Adding a LANGUAGE means adding its toolchain. This gate
# makes that mechanical instead of remembered.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

MISE="${REPO_ROOT}/.mise.toml"
[ -f "$MISE" ] || die ".mise.toml missing — it IS the CI toolchain (mise-action reads it)"

rc=0
checked=0
while read -r app; do
  [ -n "$app" ] || continue
  for tool in $(app_toolchain "$app"); do
    checked=$((checked + 1))
    if grep -qE "^${tool}[[:space:]]*=" "$MISE"; then
      log_info "toolchain OK: ${app} (lang=$(app_lang "$app")) needs '${tool}' -> pinned in .mise.toml"
    else
      log_error "app '${app}' (lang=$(app_lang "$app")) needs '${tool}', but it is NOT pinned in .mise.toml"
      log_error "    => CI (mise-action) has no '${tool}', so this app is NEITHER TESTED NOR SCANNED there."
      log_error "    => it will still pass on any dev box that happens to have '${tool}' installed."
      rc=1
    fi
  done
done <<EOF
$(app_names)
EOF

if [ "$rc" -eq 0 ]; then
  [ "$checked" -gt 0 ] || die "check-app-toolchains: checked 0 toolchain(s) — apps/registry.tsv is empty or app_names is broken. The gate has gone BLIND."
  log_info "check-app-toolchains: OK — every app's toolchain (${checked} tool(s)) is pinned in .mise.toml, so CI can actually test and scan it."
else
  log_error "check-app-toolchains: pin the missing tool(s) in .mise.toml (and align the version with the image the pipeline builds with — check-toolchain-alignment)."
fi
exit "$rc"
