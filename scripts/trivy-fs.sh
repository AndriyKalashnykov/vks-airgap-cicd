#!/usr/bin/env bash
# trivy-fs.sh — scan EVERY app's BUILT ARTIFACT for fixable HIGH/CRITICAL CVEs.
#
# Not the source tree: the built artifact is what actually ships, and it is what carries the
# dependency set. Scanning `pom.xml` would make trivy resolve the BOM over the network (flaky, and
# it 429s on shared CI runners); scanning the artifact is offline and deterministic.
#
#   java -> the fat jar         (trivy sees BOOT-INF/lib/*.jar — every resolved dependency)
#   go   -> the compiled binary (trivy sees Type: gobinary — including the Go STDLIB version, which
#           is where Go-stdlib CVEs surface; scanning go.mod would miss them entirely, and it
#           misses them EVEN NOW that gowebapp has a dependency -- the stdlib is not a module)
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
# CAPTURE FIRST -- do NOT inline `$(app_names)` into the heredoc below. MEASURED 2026-08-22:
# `done <<EOF` + `$(app_names)` SWALLOWS a die inside the substitution, so a missing registry
# printed `FATAL: app registry not found`, then `OK - 0 app artifact(s) scanned`, and exited 0.
# A CVE SCANNER CERTIFYING CLEAN HAVING SCANNED NOTHING. An assignment propagates the failure
# under `set -e`; the heredoc does not. Same class PR #944 fixed in validate.sh and for_each_app.
_apps="$(app_names)"
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
    nodejs)
      # SCAN THE LOCKFILE DIRECTORY, not a built artifact. An interpreted app has no binary carrying
      # its dependencies, so the thing that describes what SHIPS is package-lock.json -- which trivy
      # reads directly, needing no node_modules and no network.
      [ -f "${src}/package-lock.json" ] || die "app '${app}': no package-lock.json under $(app_src "$app") -- trivy would scan nothing, and an empty scan is not a clean one."
      artifact="$src"
      ;;
    python)
      # Same reasoning as nodejs: an interpreted app has no binary carrying its dependencies, so the
      # thing describing what SHIPS is requirements.txt, which trivy reads directly -- offline, no venv.
      [ -f "${src}/requirements.txt" ] || die "app '${app}': no requirements.txt under $(app_src "$app") -- trivy would scan nothing, and an empty scan is not a clean one."
      artifact="$src"
      ;;
    rust)
      # Cargo.lock, NOT the built binary: a stripped release binary carries no crate metadata, so
      # scanning it finds nothing and reports clean. The lockfile is what names the shipped crates.
      [ -f "${src}/Cargo.lock" ] || die "app '${app}': no Cargo.lock under $(app_src "$app") -- trivy would scan nothing, and an empty scan is not a clean one."
      artifact="$src"
      ;;
    dotnet)
      # The .csproj, not a built DLL. This app declares no PackageReference (ASP.NET Core's shared
      # framework carries Kestrel and Razor), so the csproj plus its TargetFramework is what names the
      # shipped surface; trivy reads it offline. If PackageReferences are ever added, a packages.lock.json
      # would be the better target -- say so here rather than discovering it silently.
      # GLOB, never the app's own filename: check-app-hardcodes forbids a shared file naming an instance,
  # and a second .NET app would carry a differently-named .csproj. (It caught exactly that here.)
  _csproj=""; for _c in "${src}"/*.csproj; do [ -f "$_c" ] && { _csproj="$_c"; break; }; done
  [ -n "$_csproj" ] || die "app '${app}': no .csproj under $(app_src "$app") -- trivy would scan nothing, and an empty scan is not a clean one."
      artifact="$src"
      ;;
    *) die "app '${app}': add a branch to scripts/trivy-fs.sh" ;;
  esac

  log_info "trivy-fs: scanning ${app} -> ${artifact#"$REPO_ROOT"/}"
  trivy rootfs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --quiet "$artifact" || rc=1
  scanned=$((scanned + 1))
done <<EOF
${_apps}
EOF

# THE FLOOR. The denominator below is only meaningful if it is non-zero: "0 scanned" and "0
# vulnerabilities" are indistinguishable in the OK line, and the OK line is what a reader believes.
[ "$scanned" -gt 0 ] || die "trivy-fs: scanned 0 app artifact(s) - refusing to report a CLEAN scan over nothing. Either the app registry is unreadable or no app produced an artifact (did 'make app-build' run?)."

# Print the denominator: a scanner that cannot say how many artifacts it looked at cannot be trusted.
if [ "$rc" -eq 0 ]; then
  log_info "trivy-fs: OK — ${scanned} app artifact(s) scanned, no fixable HIGH/CRITICAL CVEs"
else
  log_error "trivy-fs: fixable HIGH/CRITICAL CVEs found (see above)"
fi
exit "$rc"
