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
# engine_build_isolation lives in lib/engine.sh, NOT os.sh (which has container_engine/engine_choice).
# check-lib-sourcing.sh exists because this exact call was once added without this line and died
# `engine_build_isolation: command not found` at runtime — it caught the same omission here today.
# shellcheck source=scripts/lib/engine.sh
. "${SCRIPT_DIR}/lib/engine.sh"
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

# ⚠️ ONE trap, set ONCE, reading $src AT TRAP TIME. The first version did
#     trap "rm -rf '$src'" EXIT      # with SC2064 disabled
# which INTERPOLATES a TSV-derived value into a single-quoted shell string. MEASURED: a row
# named  x'; touch PWNED_MARKER; :'  created PWNED_MARKER, left the temp dir behind, and
# REPLACED the script's exit status with 127. selfbuilt.tsv is a committed file, so this is not
# a privilege boundary -- the real harm is that a stray apostrophe silently corrupts the exit
# code, which is a fake-green generator in a repo whose whole doctrine is exit-code honesty.
src=""
# ⚠️ `return 0` IS LOAD-BEARING. `[ -n "$x" ] && rm ...` as a function's TAIL returns 1 when the
# test is false, and as an EXIT trap that becomes THE SCRIPT'S exit status. `src` is emptied after
# every successful image (see the end of the loop) and is never set at all when every image is
# skipped — so this script exited 1 on a fully-successful run. It went unnoticed because nothing
# called it from a flow that checked: wiring it into install-all is what made it matter.
_selfbuilt_cleanup() { [ -n "${src:-}" ] && rm -rf -- "$src"; return 0; }
trap _selfbuilt_cleanup EXIT
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

  # ---- SKIP AN IMAGE ALREADY BUILT AT THIS EXACT PIN ------------------------
  # `install-all` runs this on EVERY invocation, and scenario-1 explicitly tells the operator to
  # "fix it and re-run install-all" -- so without a sentinel a from-source clone+build is paid every
  # time. Same shape as the mirror's `.mirror-ok`: the sentinel records what was built, and a
  # re-run skips only when the tarball exists AND the recorded ref matches the pin we want now.
  # SELFBUILT_FORCE=1 rebuilds regardless.
  #
  # Keyed on the full BUILD TAG, not the git ref. MEASURED 2026-08-27: a ref-keyed sentinel is
  # BLIND to a dependency-override change -- reverting go_get ggcr v0.21.6 -> v0.21.9 left the ref
  # at v1.25.18, so the stale v0.21.6 tarball was reused while WEARING the v0.21.9 tag, and the
  # e2e's kaniko step hung 8m16s on the v0.21.6 pullLimiter deadlock. check-selfbuilt.sh REQUIRES
  # the tag to encode every go_get override, so the tag IS the complete identity; the ref is not.
  # Deliberately NOT keyed on the tarball alone: a stale tarball from an earlier pin would then be
  # treated as current, which is the failure this is supposed to prevent.
  _sb_stamp="${OUT_DIR}/.${name}.built"
  if [ "${SELFBUILT_FORCE:-0}" != "1" ] \
     && [ -s "$tarball" ] \
     && [ "$(cat "$_sb_stamp" 2>/dev/null)" = "${tag}" ]; then
    log_info "[${name}] already built at ${tag} (${tarball}) — skipping. SELFBUILT_FORCE=1 to rebuild."
    continue
  fi

  src="$(mktemp -d "${TMPDIR:-/tmp}/selfbuilt-${name}.XXXXXX")"

  log_info "[${name}] cloning ${url} at ${ref}"
  # --depth 1 --branch <TAG>: git refuses a nonexistent ref loudly, which is the check we want.
  run git clone --quiet --depth 1 --branch "$ref" "$url" "$src"

  # ---- SOURCE PATCHES -------------------------------------------------------
  # Some defects cannot be fixed by choosing a version, because no release contains the fix.
  # MEASURED 2026-08-27: ggcr's realm exemption (which this build NEEDS to push to an IP-addressed
  # Harbor) and its pull limiter (which DEADLOCKS kaniko) both landed in v0.21.6, so no pin has one
  # without the other. The patch is applied to the CLONE, before the container build, so the
  # go mod vendor inside that build is unaffected.
  #
  # --check FIRST: a patch gone stale against a bumped git_ref must fail LOUDLY here, naming
  # itself, rather than silently not applying and leaving the defect in a build that succeeds.
  patch_rel="$(selfbuilt_patch "$name")"
  if [ -n "$patch_rel" ]; then
    patch_abs="${REPO_ROOT}/${patch_rel}"
    [ -f "$patch_abs" ] || die "[${name}] images/selfbuilt.tsv names patch ${patch_rel}, but ${patch_abs} does not exist."
    ( cd "$src" && git apply --check "$patch_abs" ) || die "[${name}] ${patch_rel} does NOT apply to ${url}@${ref}.
  The pin moved and the patch went stale. Re-cut it against ${ref}; do NOT drop it -- read its
  header for what it fixes and whether that is still needed."
    ( cd "$src" && run git apply "$patch_abs" )
    log_info "[${name}] applied source patch: ${patch_rel}"
  fi

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
    # ---- THE OVERRIDE GOES INSIDE THE BUILD, WHERE GO ALREADY LIVES ----------
    # It used to run `go get` + `go mod vendor` ON THIS BOX, before the container build. That made a
    # host Go toolchain a hard dependency of the whole flow -- and MEASURED 2026-08-27: `.mise.toml`
    # carries 0 `go` pins (removed 2026-08-23), `00-install-prereqs.sh` installs it 0 times, and
    # `03-check-tools.sh` checks it 0 times. So wiring this into `install-all` would have run the
    # ~10-minute mirror on every walkbox and THEN died on a missing binary. It only ever looked fine
    # here because this dev box carries a stale mise go/1.27.0 that a walkbox does not.
    #
    # MEASURED on the fork at the pinned tag: deploy/Dockerfile's builder stage is
    # `FROM golang:1.26 ... AS builder` with `WORKDIR /src` and `COPY . .`, and it VENDORS. So both
    # the toolchain and the source are already inside the build; the host needs no Go at all.
    # Upstream documents this exact `go get <tool>@<tag>` + `go mod vendor` pair in a comment above
    # its own `go install` steps -- it expects the results committed via PR, which is why there is no
    # ARG hook and why we insert a RUN instead.
    df="${src}/${dfile}"
    [ -f "$df" ] || die "[${name}] ${dfile} not found under ${src}"
    # The anchor is load-bearing: the RUN must land AFTER the source is COPYed in and BEFORE the
    # first `go install`, or it either has no go.mod to edit or runs too late to affect the tools.
    grep -qE '^COPY \. \.$' "$df" || die "[${name}] ${dfile} has no 'COPY . .' line to anchor the
  dependency override on. Upstream's layout changed; re-read deploy/Dockerfile before editing this."
    log_info "[${name}] dependency override (inside the build): go get ${gg}"
    tmp_df="${df}.selfbuilt"
    awk -v gg="$gg" '
      { print }
      /^COPY \. \.$/ && !done {
        print ""
        print "# --- injected by scripts/14-selfbuilt-build.sh from images/selfbuilt.tsv go_get ---"
        print "# go mod vendor, NOT go mod tidy: this fork VENDORS, and tidy PRUNES the tool"
        print "# dependencies the go install steps below need."
        print "RUN go get " gg " && go mod vendor"
        done = 1
      }
    ' "$df" > "$tmp_df"
    # Prove the injection landed rather than trusting awk exited 0.
    grep -qE '^RUN go get ' "$tmp_df" || die "[${name}] the dependency override was not injected into ${dfile}"
    mv "$tmp_df" "$df"
  fi

  # A cgroup-v1 box CANNOT build rootless at all — see engine_build_isolation() in lib/engine.sh for
  # the A/B measured on a Photon 5 walkbox 2026-08-16. That fix was applied to the BUILDER build
  # (14-builder-build.sh) and this file, added later by the self-built-kaniko work, did not inherit
  # it. MEASURED 2026-08-27, walk-matrix cut A: ubuntu row 1 PASSED while photon rows 2 and 5 both
  # died here at the first RUN step —
  #     crun ... open `/sys/fs/cgroup/devices/buildah-buildah2...`: exit status 1
  #     Error: building at STEP "RUN mkdir -p /kaniko/.docker"
  # — with podman itself warning "Using cgroups-v1". Ubuntu boots cgroup v2 and is unaffected, which
  # is precisely why a green ubuntu row said nothing about it, and why this shipped.
  # ANNOUNCED, not applied silently: it is a real isolation trade and the operator should see it.
  _iso="$(engine_build_isolation)"
  if [ -n "$_iso" ]; then
    export BUILDAH_ISOLATION="$_iso"
    log_warn "cgroup v1 detected — building with BUILDAH_ISOLATION=${_iso}: rootless podman cannot"
    log_warn "  create a container cgroup here. Weaker isolation, bounded — our Dockerfile, our base."
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
  #
  # ⚠️ THIS IS THE ENGINE'S IMAGE ID (a CONFIG digest), NOT the manifest digest a registry reports.
  # MEASURED 2026-08-26, they differ: engine id 1253e769..., pushed manifest 95106555... So this
  # column alone CANNOT verify what was pushed -- treating it as if it could made the lock
  # write-only decoration. 22-selfbuilt-push.sh appends the REGISTRY digest after a verified push,
  # which is the value a later run can actually compare.
  engine_id="$("$ENGINE" inspect --format '{{.Id}}' "$local_ref" 2>/dev/null || echo unknown)"
  # ---- PROVE THE OVERRIDE REACHED THE ARTIFACT -------------------------------
  # Injecting the RUN proves the DOCKERFILE TEXT changed; it does not prove the BINARY was built
  # with the override. Without this the chain is: text injected -> build exited 0 -> push verified
  # -> INFERRED that the dependency is what we asked for. A green push is equally consistent with a
  # cached layer or `go get` resolving to something else.
  #
  # ⚠️ NOT `go version -m`: this is a SCRATCH-based executor image with NO Go toolchain in it
  # (measured — `command -v go` inside the image returns nothing, while /kaniko/executor is there).
  # An earlier version of this check assumed one and degraded to a WARN on every build, which is a
  # proof that never runs. Go embeds its build info as PLAIN TEXT in the executable, so grep reads
  # it with no toolchain at all. The debug image ships /busybox/sh; a non-debug one would not, and
  # that case still warns rather than silently passing.
  if [ -n "$gg" ]; then
    for _mod in $gg; do
      _want_mod="${_mod%@*}"; _want_ver="${_mod##*@}"
      # The dep record is "<module><TAB><version>"; `.` matches the tab without needing to quote it.
      # Measured on a correct build: 2 hits. A wrong version: 0.
      # ⚠️ THE PROBE REPORTS ITS OWN STATUS IN-BAND (`HITS=<n>:RC=<n>`), AND THE CAUSE COMES FROM
      # THE EXIT CODE -- NEVER FROM MATCHING STDERR TEXT. Both were refuted by measurement:
      #
      #  * the OLD `grep -ac ... || echo 0` COLLAPSED TWO OPPOSITE EVENTS into the literal 0:
      #    grep RAN and found nothing (rc 1 -- the real finding, `die` is right) and grep FAILED TO
      #    RUN (rc 2 -- path moved, busybox built without -a). The second then died with a
      #    maximum-alarm supply-chain message for a tooling problem. `grep -c` already prints 0 on
      #    no-match, so `|| echo 0` only ever swallowed ERRORS. The sentinel keeps grep's three-way
      #    status, so RC=2 is a WARN and only HITS=0:RC=1 is fatal.
      #  * classifying on stderr TEXT cannot discriminate on a cgroup-v1 host. MEASURED in
      #    ~/walk-evidence: podman prints `Using cgroups-v1 which is deprecated` on EVERY
      #    invocation (12 occurrences in a row2-photon run that finished 0 FAILED), and it is
      #    emitted by `podman save` too -- so a "cgroup" matcher fires on the GENUINE no-shell
      #    case and would ship a NEW confidently-wrong cause. `no such file` is no better: it
      #    matches both the missing shell and crun's v1 devices-controller failure.
      #  * the exit code DOES discriminate, identically on both engines (measured docker 29.7.2,
      #    podman 4.9.3): 0 shell ran · 127 command not found (no shell) · 125 the engine could
      #    not start the container. chroot(1)/OCI convention, documented in `man podman-run`.
      #
      # ⚠️ `-w` IS LOAD-BEARING, AND ITS ABSENCE WAS A SILENT FALSE-VERIFY. The pattern is an
      # UNANCHORED SUBSTRING, so asking for v0.21.1 MATCHES an embedded v0.21.19 -- measured on the
      # real image: HITS=1:RC=0, i.e. `verified in the binary` for a version we did not ask for.
      # That needs no malformed TSV: `go get mod@X` plus Go's minimal-version-selection can resolve
      # HIGHER than the request, which is precisely the "we asked" vs "it happened" gap this probe
      # exists to close, so the probe was blind to its own subject. `-w` requires a non-word char
      # either side; the build info is TAB-separated, so the real match still lands (measured
      # HITS=2:RC=0 on the real artifact) while the v0.21.1-vs-v0.21.19 case becomes HITS=0:RC=1.
      # The inner `2>/dev/null` is also gone: stderr is unredirected outward now, so grep's own
      # message reaches the log and the RC=2 WARN can say WHICH failure it was.
      #
      # NO TEMP FILE AND NO NEW `trap ... EXIT`: a second EXIT trap REPLACES the one above, which is
      # the only thing that removes the kaniko `git clone` in $src. Stderr is deliberately NOT
      # redirected -- the runtime's own message belongs in the log the operator already reads.
      #
      # ⚠️ HONESTY: the runtime-failure arm below has NEVER FIRED. There are zero `<engine> run`
      # invocations anywhere in ~/walk-evidence, podman documents rootless-on-cgroup-v1 as
      # supported (it stops MANAGING cgroups rather than failing), and the known v1 breakage is
      # buildah's unconditional `mkdir /sys/fs/cgroup/devices/buildah-<n>` -- a BUILD path, not
      # this one. It is a correct label for a case we have not observed, not a fix for a known bug.
      # (rc 125 itself IS measured reachable on both engines -- `podman run --badoption` produces it.
      # What has never been observed is the engine failing to start THIS container on a v1 host.)
      #
      # ⚠️ On a cgroup-v1 host podman prints its deprecation WARNING immediately BEFORE the
      # `verified` line below, because stderr is deliberately unredirected. That is noise, not a
      # failure -- the verdict is the HITS=/RC= sentinel, never the surrounding text.
      _out="$("$ENGINE" run --rm --entrypoint /busybox/sh "$local_ref" \
                -c "n=\$(grep -acw '${_want_mod}.${_want_ver}' /kaniko/executor); r=\$?; printf 'HITS=%s:RC=%s' \"\$n\" \"\$r\"")" \
        && _rc=0 || _rc=$?
      case "$_out" in
        HITS=0:RC=1)
          die "[${name}] the go_get override did not reach the binary: '${_want_mod} ${_want_ver}'
  is not in /kaniko/executor's embedded build info. The Dockerfile text was injected and the build
  exited 0, so this is the difference between 'we asked' and 'it happened'." ;;
        HITS=*[1-9]*:RC=0)
          log_info "[${name}] verified in the binary: ${_want_mod} ${_want_ver} (${_out})" ;;
        HITS=*:RC=2)
          log_warn "[${name}] grep could not READ /kaniko/executor (moved path, or a busybox without -a) — the go_get override is UNVERIFIED. This is a TOOLING failure, not a finding about the binary." ;;
        *)
          case "$_rc" in
            125) log_warn "[${name}] the container RUNTIME could not start ${local_ref} — the go_get override is UNVERIFIED. This is the ENGINE, not the image: run 'make engine-check'." ;;
            126|127) log_warn "[${name}] no /busybox/sh in ${local_ref} — the go_get override is UNVERIFIED (a non-debug kaniko image legitimately has no shell)." ;;
            *) log_warn "[${name}] the verification probe was inconclusive (rc=${_rc}, out='${_out}') — the go_get override is UNVERIFIED." ;;
          esac ;;
      esac
    done
  fi

  printf '%s\t%s\t%s\t%s:%s\t%s\n' "$name" "$ref" "$engine_id" "$repo" "$tag" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOCK}.tmp"
  # Written ONLY here, i.e. after the save succeeded — a build that dies leaves no stamp, so the
  # next run rebuilds rather than trusting a partial artifact.
  printf '%s\n' "$tag" > "$_sb_stamp"

  rm -rf -- "$src"; src=""
done

sort -u "${LOCK}.tmp" > "$LOCK"; rm -f "${LOCK}.tmp"
log_info "self-built images saved into the bundle: ${NAMES}"
log_info "next: make bundle   (bundle/selfbuilt/ is inside BUNDLE_DIR, so the existing tar carries it)"
log_info "then, on the air-gap box: make selfbuilt-push"
