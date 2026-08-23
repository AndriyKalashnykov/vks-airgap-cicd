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
  # SUBJECT CHANGED 2026-08-23. This used to assert "the app's host toolchain is pinned in
  # .mise.toml". Every consumer of a host app-toolchain is now containerised — app-test,
  # check-ui-contract, trivy-fs and app-run all run inside the app's own builder image, and all
  # four were MEASURED rc=0 with java/go/cargo/dotnet/node stripped from PATH entirely. So that
  # assertion had no subject left, and this gate's own floor correctly fired:
  #   'checked 0 toolchain(s) — the gate has gone BLIND'.
  #
  # The invariant did not vanish, it MOVED. What CI needs now is a BUILDER IMAGE per app, and its
  # base tag is already asserted against images/images.txt by check-image-alignment.sh:239-244,
  # which EXECUTES app_builder_base() per app. What that cannot see is an app enrolled with no
  # Dockerfile.builder at all — which is what this gate now catches.
  checked=$((checked + 1))
  if app_has_builder "$app"; then
    log_info "builder OK: ${app} (lang=$(app_lang "$app")) ships $(app_src "$app")/Dockerfile.builder"
  else
    log_error "app '${app}' (lang=$(app_lang "$app")) has NO Dockerfile.builder"
    log_error "    => app-test / check-ui-contract / trivy-fs / app-run ALL run in that image now,"
    log_error "    => so this app cannot be tested, rendered, scanned or run — anywhere."
    rc=1
  fi
done <<EOF
$(app_names)
EOF

if [ "$rc" -eq 0 ]; then
  [ "$checked" -gt 0 ] || die "check-app-toolchains: checked 0 toolchain(s) — apps/registry.tsv is empty or app_names is broken. The gate has gone BLIND."
  log_info "check-app-toolchains: OK — all ${checked} enrolled app(s) ship a Dockerfile.builder, so CI can actually test and scan it."
else
  log_error "check-app-toolchains: pin the missing tool(s) in .mise.toml (and align the version with the image the pipeline builds with — check-toolchain-alignment)."
fi
exit "$rc"
