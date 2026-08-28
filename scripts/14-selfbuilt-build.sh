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
     && [ "$(head -1 "$_sb_stamp" 2>/dev/null)" = "${tag}" ]; then
    log_info "[${name}] already built at ${tag} (${tarball}) — skipping. SELFBUILT_FORCE=1 to rebuild."
    # ⚠️ RE-EMIT THIS IMAGE'S LOCK RECORD. Without this the lock SELF-ERASES on every warm run, and
    # the skip is the COMMON path: line 70 truncates ${LOCK}.tmp, this `continue` jumps past the
    # append below, and the tail then overwrites $LOCK with the empty tmp. MEASURED on a real box --
    # kaniko.tar 113 MB at 19:22, selfbuilt.lock 0 BYTES at 20:02, i.e. emptied by a later warm run.
    # Nothing reads the lock today, so this has cost nothing yet; that is not a reason to keep
    # writing an empty provenance journal, and it IS a reason not to build anything on top of one.
    # `head -1` above, not `cat`: the stamp now carries the tag on line 1 and the lock record on
    # line 2, so an OLD one-line stamp still compares equal and simply has no record to re-emit.
    _sb_rec="$(sed -n '2p' "$_sb_stamp" 2>/dev/null || true)"
    # ⚠️ MIGRATION: an OLD one-line stamp has no line 2, and that is the state EVERY existing box is
    # in — so without this the erasure survives the fix for exactly the boxes it was written for.
    # MEASURED: valid 74-byte lock + old stamp + one warm run -> 0 bytes, identical to pre-fix.
    # The record is recoverable from the PREVIOUS $LOCK, which is not read until the final sort, so
    # at skip time it still holds the last run's rows. Keyed on field 1 (the image name).
    if [ -z "$_sb_rec" ]; then
      _sb_rec="$(awk -F'\t' -v n="$name" '$1==n{print;exit}' "$LOCK" 2>/dev/null || true)"
    fi
    # ⚠️ A RECOVERED RECORD IS UNTRUSTED UNTIL IT DESCRIBES *THIS* BUILD. Field 4 is `<repo>:<tag>`;
    # if it names a different push target the record is stale, and re-emitting it would assert a
    # ref/digest/tag we did not build here -- silently, and self-perpetuating (the re-emit becomes
    # next run's recovery source, so it never re-validates). Not script-reachable today (a pin bump
    # takes the rebuild path, and a script-written stamp's line 2 is written in the same iteration
    # as line 1, so it always agrees) -- it needs a restored, hand-edited, or foreign lock. Applied
    # to BOTH sources anyway: it cannot false-fire on a record this script wrote, and the file's
    # only purpose is provenance, which a wrong record silently destroys.
    if [ -n "$_sb_rec" ]; then
      _sb_f4="$(printf '%s' "$_sb_rec" | cut -f4 || true)"
      if [ "$_sb_f4" != "${repo}:${tag}" ]; then
        log_warn "[${name}] the surviving lock record names '${_sb_f4}' but this build targets '${repo}:${tag}' -- refusing to re-emit a record for a different push target. That image's row will be MISSING from ${LOCK}; SELFBUILT_FORCE=1 rebuilds and restores it."
        _sb_rec=""
      fi
    fi
    if [ -n "$_sb_rec" ]; then
      printf '%s\n' "$_sb_rec" >> "${LOCK}.tmp"
    else
      log_warn "[${name}] skipped, its stamp predates the lock-record fix, AND no record for it survives in ${LOCK} — so that file is being written EMPTY for this image. With a single-image registry that means the whole lock is truncated. SELFBUILT_FORCE=1 rebuilds and restores it."
    fi
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
      # ⚠️ NO CONTAINER IS CREATED OR STARTED. We grep the TARBALL this script already wrote at
      # `"$ENGINE" save -o "$tarball"` a few lines up. That is not a micro-optimisation -- it is the
      # whole fix, and it was arrived at by refuting two designs that came before it:
      #
      #  * `<engine> run --entrypoint /busybox/sh` (the original) CANNOT RUN on a cgroup-v1 host.
      #    MEASURED on a Photon 5 walkbox (podman 5.8.5, crun 1.29, rootless uid 1000):
      #        Error: crun: open `/sys/fs/cgroup/devices/<ctr-id>`: No such file or directory
      #    crun cannot create the container cgroup under the root-owned v1 `devices` controller --
      #    v1 has no delegation model (v2 introduced it). podman maps it to rc 127, the SAME code as
      #    a genuinely missing shell, so no exit-code classification can separate them. It fired in
      #    production: matrix row2 (photon, v1) logged "no shell in <ref> ... UNVERIFIED" while row1
      #    (ubuntu, v2) logged "verified in the binary (2 hits)" -- same commit, same tag. The image
      #    was later pulled by digest and is FINE (/busybox/sh present; the probe returns HITS=2:RC=0
      #    against it on a v2 host). Photon 5 boots v1 BY DEFAULT and Photon is a jump-box OS we are
      #    handed, so v1 is the NORM here, not an edge case.
      #  * `<engine> create` + `<engine> cp` + host grep (the obvious next idea) is REFUTED:
      #    `docker cp` and `podman cp` have OPPOSITE symlink semantics (docker copies a 4-byte broken
      #    link, podman follows it) and `podman cp -L` does not exist -- so if /kaniko/executor ever
      #    became a symlink, docker would report 0 hits and this code would `die` accusing the supply
      #    chain, on ONE engine only. `create` on an absent image also makes a NETWORK call with
      #    retries, which is exactly wrong on an air-gap box.
      #
      # The tarball has none of those problems: no cgroups, no engine call, no symlink divergence,
      # no temp copy, nothing to leak, and grep's three-way status stays intact. MEASURED on the real
      # artifact, and identical for a docker-saved and a podman-saved tar:
      #     correct v0.21.9 -> HITS=4 RC=0   |   v0.21.1 (substring) -> HITS=0 RC=1   |   absent -> 0/1
      # (FOUR hits, not the two the in-image grep saw: the tar carries the layer plus its blob.)
      _hits="$(grep -acw "${_want_mod}.${_want_ver}" "$tarball")" && _grc=0 || _grc=$?

      # VACUITY GUARD. The tar also carries manifest.json and the image config, and the config's
      # history records the very `RUN go get <mod>@<ver>` line THIS SCRIPT injects. Today the go_get
      # runs in a discarded BUILDER stage, so the metadata contributes ZERO hits (measured) and the
      # count is all binary. If the override is ever moved into the final stage, the metadata alone
      # would satisfy the check and it would verify itself -- the purest vacuous green. So count the
      # JSON members separately and refuse to report VERIFIED if they contribute anything.
      # Portable on purpose: `tar -tf` + `tar -xOf <member>` are POSIX; `--wildcards` is GNU-only and
      # Photon's tar is toybox.
      # ⚠️ SELECT METADATA BY CONTENT, NEVER BY FILENAME. An earlier version of this loop matched
      # `*.json` and was VACUOUS ON DOCKER: `docker save` emits an OCI layout whose members are all
      # `blobs/sha256/<digest>` with NO EXTENSION, so the name filter saw only index.json and
      # manifest.json and MISSED THE CONFIG BLOB -- which is exactly where the `created_by` history
      # (our injected `RUN go get`) lives. `podman save` emits docker-archive v1 instead, where the
      # config IS `<sha>.json` but 12 further `<layer>/json` members are also missed. Both engines,
      # different blind spots, same class. Matching `blobs/sha256/*` by name is ALSO wrong -- on
      # docker that includes the LAYERS, one of which legitimately contains the binary we are trying
      # to find, so the guard would fire on the real hit.
      # `$1 !~ /^d/` SKIPS DIRECTORY MEMBERS, and that is not cosmetic: `tar -xOf <dir>` dumps
      # EVERYTHING BENEATH IT, so a directory re-yields its children's bytes and the same metadata
      # is counted once per ancestor. Measured on a 3-member fixture: 3 hits for 1 real match ->
      # an inflated _json_hits can raise a FALSE vacuity warning and refuse a good build.
      # Size bound is a COST bound, not the correctness gate: config/manifest/index are KB-scale and
      # layers are MB-scale, so we only pay to inspect small members; the `{` content check is what
      # actually decides. `tar -tvf`/`tar -xOf` are POSIX (Photon's tar is toybox; no --wildcards).
      _json_hits=0
      while read -r _jsz _jm; do
        case "$_jsz" in ''|*[!0-9]*) continue ;; esac
        [ "$_jsz" -le 1048576 ] || continue            # a layer is never the metadata we mean
        case "$(tar -xOf "$tarball" "$_jm" 2>/dev/null | head -c 1)" in '{') ;; *) continue ;; esac
        _jh="$(tar -xOf "$tarball" "$_jm" 2>/dev/null | grep -acw "${_want_mod}.${_want_ver}" || true)"
        case "$_jh" in ''|*[!0-9]*) _jh=0 ;; esac
        _json_hits=$((_json_hits + _jh))
      done <<EOF
$(tar -tvf "$tarball" 2>/dev/null | awk '$1 !~ /^d/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i, $NF; break } }')
EOF

      if [ "$_json_hits" -gt 0 ]; then
        log_warn "[${name}] the image METADATA in ${tarball} contains '${_want_mod} ${_want_ver}' (${_json_hits} hit(s)) — this check cannot tell metadata from binary, so the go_get override is UNVERIFIED. The go_get must run in a DISCARDED build stage, not the final one."
      else
        case "$_grc" in
          0) case "$_hits" in
               ''|0|*[!0-9]*) log_warn "[${name}] the probe returned rc=0 with a non-positive count ('${_hits}') — the go_get override is UNVERIFIED (this should not happen; suspect the archive)." ;;
               *) log_info "[${name}] verified in the binary: ${_want_mod} ${_want_ver} (${_hits} build-info hit(s) in the saved image)" ;;
             esac ;;
          # NOT "not in /kaniko/executor" -- a grep of the saved image cannot localise to a path.
          # What it proves is absence from the whole saved image; the vacuity guard above is what
          # separates binary from metadata.
          1) die "[${name}] the go_get override did not reach the artifact: '${_want_mod} ${_want_ver}'
  is not present anywhere in the saved image (${tarball}). The Dockerfile text was injected and the
  build exited 0, so this is the difference between 'we asked' and 'it happened'." ;;
          *) log_warn "[${name}] could not read ${tarball} (grep rc=${_grc}) — the go_get override is UNVERIFIED. This is a TOOLING failure, not a finding about the binary." ;;
        esac
      fi
    done
  fi

  # Built once and reused for the stamp, so a warm run re-emits the SAME bytes rather than a
  # reconstruction with a fresh timestamp (which would make the lock churn on every skip).
  _sb_rec="$(printf '%s\t%s\t%s\t%s:%s\t%s' "$name" "$ref" "$engine_id" "$repo" "$tag" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  printf '%s\n' "$_sb_rec" >> "${LOCK}.tmp"
  # Written ONLY here, i.e. after the save succeeded — a build that dies leaves no stamp, so the
  # next run rebuilds rather than trusting a partial artifact.
  # LINE 1 = the tag (what the skip comparison reads, via head -1 -- so an old one-line stamp is
  # still valid). LINE 2 = this image's lock record, so a skipped image can re-emit it.
  printf '%s\n%s\n' "$tag" "$_sb_rec" > "$_sb_stamp"

  rm -rf -- "$src"; src=""
done

# ⚠️ WRITE VIA A TEMP AND RENAME. `sort -u ... > "$LOCK"` truncates $LOCK BEFORE sort runs, so ANY
# sort failure (unreadable tmp, ENOSPC, an interrupt) leaves it at zero — a second erasure path
# inside the very statement this change exists to fix. MEASURED: unreadable tmp -> lock 0 bytes.
# The `if` (not `A && B || C`) so a sort/mv failure is REPORTED rather than swallowed: preserving
# the previous rows beats truncating to zero, but a just-built image's record would then be silently
# missing from a file whose only job is provenance. Truncation was at least loud.
if sort -u "${LOCK}.tmp" > "${LOCK}.new" && mv -f "${LOCK}.new" "$LOCK"; then :; else
  log_warn "could not rewrite ${LOCK} -- it still holds the PREVIOUS run's rows, so this run's records are missing from it."
fi
rm -f "${LOCK}.tmp" "${LOCK}.new"
log_info "self-built images saved into the bundle: ${NAMES}"
log_info "next: make bundle   (bundle/selfbuilt/ is inside BUNDLE_DIR, so the existing tar carries it)"
log_info "then, on the air-gap box: make selfbuilt-push"
