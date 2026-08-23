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


# build_in_builder <app> <out> <cmd> - produce ONE artefact inside the app's builder image.
#
# The artefact leaves on STDOUT, so the bind mount stays READ-ONLY and nothing is written to the
# operator's tree (rootful docker leaves ROOT-OWNED files on a writable mount; under rootless podman
# `--user` is backwards -- container uid 1000 maps to host 100999 and cannot write at all).
# MEASURED: a 23,581,942-byte jar came out this way; `file` says "Java archive data (JAR)", owner
# andriy:andriy, and `trivy rootfs` scanned it rc=0.
#
# Build chatter goes to STDERR (1>&2) so a stray log line cannot corrupt the artefact - a Go binary
# with a leading log line may still SCAN, reporting clean over a corrupted file.
build_in_builder() {
  local app="$1" out="$2" cmd="$3" img eng
  img="localhost/${app}-builder:${BUILDER_IMAGE_TAG:-0.3.0}"
  eng="$(container_engine)"
  # `image inspect`, not `image exists` - the latter is podman-only (docker: rc=1 "unknown command").
  "$eng" image inspect "$img" >/dev/null 2>&1 \
    || die "app '${app}': builder image ${img} not present - run 'make builder-build' (Harbor-free)"
  "$eng" run --rm --network=none --pull=never \
    -v "${REPO_ROOT}/$(app_src "$app"):/src:ro" --tmpfs "/work:exec,size=${BUILDER_TMPFS_SIZE:-2g}" -w /work \
    "$img" sh -c "cp -a /src/. /work/ 1>&2 && ${cmd}" > "$out"
  [ -s "$out" ] || die "app '${app}': the builder produced an EMPTY artefact - nothing to scan"
}

  case "$(app_lang "$app")" in
    java)
      # A glob + a case test, not `ls | grep` (SC2010): the -sources/-javadoc jars must be skipped,
      # and the fat jar is the one that carries BOOT-INF/lib/*.jar (i.e. the dependencies).
      # BUILT IN THE BUILDER IMAGE, not on the host. This arm was the ONLY consumer of `app-build`
      # in the repo -- and app-build was building all SIX apps to feed it one jar.
      artifact="${TMP}/${app}.jar"
      build_in_builder "$app" "$artifact" \
        './mvnw -B -q -o -DskipTests package 1>&2 && cat target/*.jar'
      ;;
    go)
      # Build it here (cheap, no deps to fetch) so the scan sees the REAL binary + its stdlib.
      artifact="${TMP}/${app}"
      build_in_builder "$app" "$artifact" \
        'CGO_ENABLED=0 go build -o /tmp/a . 1>&2 && cat /tmp/a'
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
