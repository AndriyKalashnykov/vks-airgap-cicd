#!/usr/bin/env bash
# trivy-fs.sh — scan EVERY app's BUILT ARTIFACT for fixable HIGH/CRITICAL CVEs.
#
# Not the source tree: the built artifact is what actually ships, and it is what carries the
# dependency set. Scanning `pom.xml` would make trivy resolve the BOM over the network (flaky, and
# it 429s on shared CI runners); scanning the artifact is offline and deterministic.
#
#   java -> the fat jar         (trivy sees BOOT-INF/lib/*.jar — every resolved dependency)
#   go   -> the compiled binary (trivy sees Type: gobinary — including the Go STDLIB version, which
#           is where Go-stdlib CVEs surface; scanning go.mod would miss them entirely because a
#           stdlib-only app has no modules at all)
#
# Registry-driven: adding an app scans it, adding a language is one `case` branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

if ! require_gate_tool trivy; then
  log_warn "trivy not installed — run 'make deps' (mise) — skipping"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

rc=0
scanned=0
while read -r app; do
  [ -n "$app" ] || continue
  src="${REPO_ROOT}/$(app_src "$app")"

  case "$(app_lang "$app")" in
    java)
      # A glob + a case test, not `ls | grep` (SC2010): the -sources/-javadoc jars must be skipped,
      # and the fat jar is the one that carries BOOT-INF/lib/*.jar (i.e. the dependencies).
      artifact=""
      for j in "${src}"/target/*.jar; do
        [ -f "$j" ] || continue
        case "$j" in *-sources.jar|*-javadoc.jar) continue ;; esac
        artifact="$j"; break
      done
      [ -n "$artifact" ] || die "app '${app}': no built jar under $(app_src "$app")/target — did app-build run?"
      ;;
    go)
      # Build it here (cheap, no deps to fetch) so the scan sees the REAL binary + its stdlib.
      artifact="${TMP}/${app}"
      ( cd "$src" && CGO_ENABLED=0 go build -o "$artifact" . )
      ;;
    *) die "app '${app}': add a branch to scripts/trivy-fs.sh" ;;
  esac

  log_info "trivy-fs: scanning ${app} -> ${artifact#"$REPO_ROOT"/}"
  trivy rootfs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --quiet "$artifact" || rc=1
  scanned=$((scanned + 1))
done <<EOF
$(app_names)
EOF

# Print the denominator: a scanner that cannot say how many artifacts it looked at cannot be trusted.
if [ "$rc" -eq 0 ]; then
  log_info "trivy-fs: OK — ${scanned} app artifact(s) scanned, no fixable HIGH/CRITICAL CVEs"
else
  log_error "trivy-fs: fixable HIGH/CRITICAL CVEs found (see above)"
fi
exit "$rc"
