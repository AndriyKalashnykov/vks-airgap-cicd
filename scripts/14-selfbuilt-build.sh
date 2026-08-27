#!/usr/bin/env bash
# 14-selfbuilt-build.sh — INTERNET BOX. Build the images that have no free published build, from
# source, at a pinned git tag, and save them into the bundle.
#
# WHY THIS EXISTS. `k8s/tekton/tasks/kaniko-build.yaml` runs kaniko. Upstream
# GoogleContainerTools/kaniko is ARCHIVED (`archived: true`, last push 2025-06-03) and v1.24.0 is the
# final release that will ever exist, so its CVE count only rises, forever, and no fix will ever come.
# That trajectory — not any single CVE — is the reason this file exists. The maintained fork
# (chainguard-forks/kaniko) publishes NO free image: its CI carries `push: false`, and
# `cgr.dev/chainguard/kaniko` is commercial (MEASURED: `crane ls` returns rc=0 with an EMPTY list,
# whereas a nonexistent repo returns rc=1 + an error — it exists, we just cannot pull it).
#
# MEASURED 2026-08-26, `trivy image --severity HIGH,CRITICAL --ignore-unfixed`:
#     archived v1.24.0-debug : 197 fixable, 7 CRITICAL, 82 non-stdlib, Go v1.24.3
#     self-built v1.25.18    :  42 fixable, 0 CRITICAL,  2 non-stdlib, Go v1.26.5
# Do NOT lead with 197->42: an adversary round correctly noted it is inflated by stdlib DoS CVEs a
# build tool does not reach. The numbers that survive that attack are 7 CRITICAL -> 0 and the
# non-stdlib 82 -> 2 (containerd/docker/x-net/x-crypto — the code kaniko actually executes).
#
# THIS IS THE SIBLING OF 14-builder-build.sh, deliberately: same box, same bundle, same
# `<engine> save` -> carry -> `crane push` shape, so the air-gap box still needs NO container engine.
# It is SEPARATE because that one is per-APP by construction (app_has_builder() keys on
# `<app_src>/Dockerfile.builder`, and 40 files consume app_names/for_each_app), and an infra image
# has no app source, no deploy dir, no Gitea repo pair and no `make verify` marker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/selfbuilt.sh
. "${SCRIPT_DIR}/lib/selfbuilt.sh"
load_env

: "${BUNDLE_DIR:?BUNDLE_DIR must be set (see .env.example)}"

selfbuilt_validate || die "images/selfbuilt.tsv is not usable — fix the rows above."

NAMES="$(selfbuilt_names | tr '\n' ' ')"
if [ -z "${NAMES// /}" ]; then
  log_info "images/selfbuilt.tsv lists nothing — no image needs building from source."
  exit 0
fi

require_cmd git "install git"
ENGINE="$(container_engine)"
OUT_DIR="${BUNDLE_DIR}/selfbuilt"
mkdir -p "$OUT_DIR"
LOCK="${OUT_DIR}/selfbuilt.lock"
: > "${LOCK}.tmp"

log_info "engine=${ENGINE} · building from source: ${NAMES}"

for name in $NAMES; do
  url="$(selfbuilt_git_url "$name")"
  ref="$(selfbuilt_git_ref "$name")"
  dfile="$(selfbuilt_dockerfile "$name")"
  target="$(selfbuilt_target "$name")"
  repo="$(selfbuilt_repo_path "$name")"
  tag="$(selfbuilt_tag "$name")"
  local_ref="localhost/selfbuilt-${name}:${tag}"
  tarball="${OUT_DIR}/${name}.tar"

  src="$(mktemp -d "${TMPDIR:-/tmp}/selfbuilt-${name}.XXXXXX")"
  # shellcheck disable=SC2064  # $src is intentionally expanded NOW, not at trap time.
  trap "rm -rf '$src'" EXIT

  log_info "[${name}] cloning ${url} at ${ref}"
  # --depth 1 --branch <TAG>: git refuses a nonexistent ref loudly, which is the check we want.
  run git clone --quiet --depth 1 --branch "$ref" "$url" "$src"

  # An IMMUTABLE tag is the whole reproducibility contract, so prove the checkout is AT it rather
  # than trusting that clone honoured --branch.
  got="$(git -C "$src" describe --tags --exact-match 2>/dev/null || true)"
  [ "$got" = "$ref" ] || log_warn "[${name}] checkout describes as '${got:-<none>}', expected '${ref}' — continuing, but the pin is not confirmed"

  [ -f "${src}/${dfile}" ] || die "[${name}] ${url}@${ref} has no ${dfile}"

  # ---- OPTIONAL DEPENDENCY OVERRIDE (the `go_get` column) -------------------
  # This is the lever that MIRRORING CANNOT GIVE YOU, and it is not hypothetical: the fork's pinned
  # go-containerregistry REFUSES to push to a registry whose token realm is an IP LITERAL on a
  # private address, and the fix exists one patch release later. SCOPE, measured both ways: our KinD
  # Harbor (172.18.0.3) trips it; the VKS lab (harbor.env1.lab.test) does NOT, because the guard is
  # `net.ParseIP(host) != nil` and a hostname is not an IP. So it breaks an IP-ADDRESSED Harbor, not
  # every air-gapped one -- which is still our own e2e gate. See images/selfbuilt.tsv for the full
  # measurement and the upstream commit.
  gg="$(selfbuilt_go_get "$name")"
  if [ -n "$gg" ]; then
    command -v go >/dev/null 2>&1 || die "[${name}] images/selfbuilt.tsv requests a go_get override (${gg}) but 'go' is not on PATH.
  The override edits go.mod BEFORE the container build, so it needs a Go toolchain here (mise provides one)."
    log_info "[${name}] dependency override: go get ${gg}"
    # shellcheck disable=SC2086  # INTENTIONALLY unquoted: the column is space-separated and
    # may carry several module@version overrides. Quoting would pass them as ONE argument.
    ( cd "$src" && run go get $gg )
    # ⚠️ `go mod vendor`, NOT `go mod tidy`. MEASURED, and the two failures look identical:
    #   * a vendored module (this fork vendors) left un-revendored dies at the credential-helper
    #     step with `go: inconsistent vendoring` -- an error naming neither the module nor us.
    #   * `go mod tidy` PRUNES the tool dependency deploy/Dockerfile installs, failing the SAME
    #     step for a completely different reason.
    if [ -d "${src}/vendor" ]; then
      log_info "[${name}] re-vendoring (the upstream vendors its dependencies)"
      ( cd "$src" && run go mod vendor )
    fi
  fi

  build_args=(build -f "${src}/${dfile}" -t "$local_ref")
  [ -n "$target" ] && build_args+=(--target "$target")
  build_args+=("$src")

  log_info "[${name}] ${ENGINE} ${build_args[*]}"
  # NOTE the fork's deploy/Dockerfile uses BuildKit's `RUN --mount=from=<stage>` on a `FROM scratch`
  # base with NO `# syntax=` directive. docker/BuildKit handles it; buildah documents `--mount=from=`
  # resolving against a stage (man buildah-build, 1.33.7) but that is NOT measured here. If a podman
  # build fails on that line, it is this, not your tree.
  run "$ENGINE" "${build_args[@]}"

  log_info "[${name}] saving -> ${tarball}"
  # rm -f FIRST: `podman save -o <existing>` fails with "docker-archive doesn't support modifying
  # existing images" — a re-run-only bug a single green run cannot show. (Same reason as
  # 14-builder-build.sh:124.)
  rm -f "$tarball"
  run "$ENGINE" save -o "$tarball" "$local_ref"

  # THE REPRODUCIBILITY ANCHOR. The pin is the git tag; the anchor is what that tag PRODUCED here.
  # Recorded so the air-gap side can prove it pushed the same bytes it was handed.
  digest="$("$ENGINE" inspect --format '{{.Id}}' "$local_ref" 2>/dev/null || echo unknown)"
  printf '%s\t%s\t%s\t%s:%s\t%s\n' "$name" "$ref" "$digest" "$repo" "$tag" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOCK}.tmp"

  rm -rf "$src"; trap - EXIT
done

sort -u "${LOCK}.tmp" > "$LOCK"; rm -f "${LOCK}.tmp"
log_info "self-built images saved into the bundle: ${NAMES}"
log_info "next: make bundle   (bundle/selfbuilt/ is inside BUNDLE_DIR, so the existing tar carries it)"
log_info "then, on the air-gap box: make selfbuilt-push"
