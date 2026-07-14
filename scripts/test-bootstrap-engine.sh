#!/usr/bin/env bash
# test-bootstrap-engine.sh — CLAIM 1: "our bootstrap can produce a docker jump box" (and, by default,
# a podman one with NO docker on it at all).
#
# THIS IS THE ONLY CLAIM THAT WAS EVER GENUINELY UNPROVEN. Docker on a jump box was not "untested" —
# it was UNSUPPORTED BY OUR OWN BOOTSTRAP: 00-install-prereqs.sh installed podman and nothing else, on
# both OSes, and a gate asserted that as an invariant. A "docker works" claim measured on the developer's
# laptop is scoped to the wrong machine entirely.
#
# WHY BARE IMAGES, AND WHY NOT dind
# ---------------------------------
# The obvious harness — a jump-box image with docker pre-installed, running a rootless daemon inside —
# CANNOT test this claim, and would produce a confident false green:
#
#   * If the image pre-installs the engine, `make deps`' engine path hits "already the newest version",
#     exits 0, and INSTALLS NOTHING. The docker-install path — the entire deliverable — is never executed
#     by the matrix that supposedly tests it. (This repo has already been burned by a fix that landed only
#     in the harness image while a real box stayed broken.)
#   * A daemon-in-a-container drags in failure modes that are properties of THE HARNESS, not of the jump
#     box: `--privileged` forces the AppArmor profile to `unconfined` (which is exactly what
#     apparmor_restrict_unprivileged_userns=1 denies), overlay-on-overlay storage, and uid-0 — at which
#     the sudo column is not merely wrong, it is UNMEASURABLE (see lib/engine.sh).
#
# So: run the REAL bootstrap on a LITERALLY BARE OS image and assert the ARTIFACTS it left behind. No
# daemon is started, and none needs to be — "can the box get a docker engine + its rootless prereqs from
# its own repos" is a question about PACKAGES, and packages are what we check.
#
# The engine's registry-TLS behaviour is a DIFFERENT claim, measured host-native by
# scripts/16-engine-trust-check.sh / 17-engine-rootless-docker-check.sh against the real Harbor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd docker   # docker-ok: this is a TEST HARNESS that builds/runs throwaway OS images; it is never on the operator path (which is podman + crane).
DF="${REPO_ROOT}/jumpbox/Dockerfile.bootstrap"

# 24.04 is in the matrix ON PURPOSE: it is the release where distro-only rootless docker does NOT exist,
# so it is the only leg that can prove we DISCLOSE that instead of silently adding a third-party apt repo.
OSES="${BOOTSTRAP_ENGINE_OSES:-photon:5.0 ubuntu:26.04 ubuntu:24.04}"

fails=0
img_tag() { printf 'vks-boot:%s' "$(printf '%s' "$1" | tr ':/.' '___')"; }

# probe <image> <engine-or-empty> — run the REAL 00-install-prereqs.sh on a bare box, then print the
# artifacts that ACTUALLY landed. We report what we measured; we do not assert from the script's log.
probe() {
  local tag="$1" engine="${2:-}" envarg=()
  [ -n "$engine" ] && envarg=(-e "CONTAINER_ENGINE=${engine}")
  docker run --rm "${envarg[@]}" -v "${REPO_ROOT}:/src:ro" "$tag" \
    bash -c '
      bash /src/scripts/00-install-prereqs.sh >/tmp/boot.log 2>&1; rc=$?
      # ARTIFACTS — what is actually on the box now. Presence, not prose.
      for c in podman dockerd docker dockerd-rootless.sh rootlesskit newuidmap crun fuse-overlayfs; do
        command -v "$c" >/dev/null 2>&1 && echo "HAVE:$c" || echo "MISS:$c"
      done
      # Did we DISCLOSE the rootful-only truth where rootless is unavailable?
      grep -qi "ROOTFUL-ONLY" /tmp/boot.log && echo "DISCLOSED:rootful-only"
      # Did we (wrongly) add a third-party apt repo to someone else'"'"'s jump box?
      grep -rqs "download.docker.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
        && echo "VIOLATION:third-party-repo-added"
      echo "RC:$rc"
    ' 2>/dev/null
}

for base in $OSES; do
  tag="$(img_tag "$base")"
  log_info "=== BARE ${base}: building the bare image (nothing pre-installed) ==="
  docker build -q -f "$DF" --build-arg BASE="$base" -t "$tag" "$REPO_ROOT" >/dev/null \
    || { log_error "  build failed for $base"; fails=$((fails+1)); continue; }

  # ---- LEG A: the DEFAULT jump box. podman, and NOT ONE docker artifact. -----------------------
  log_info "--- ${base} · CONTAINER_ENGINE unset (the default jump box) ---"
  out="$(probe "$tag" "")"
  if printf '%s' "$out" | grep -q 'HAVE:podman'; then
    log_info "  ok   podman installed"
  else
    log_error "  FAIL podman NOT installed on the default path"; fails=$((fails+1))
  fi
  if printf '%s' "$out" | grep -qE 'HAVE:(dockerd|docker)$'; then
    log_error "  FAIL the DEFAULT bootstrap put DOCKER on the box — docker must ONLY appear when the operator asks"
    fails=$((fails+1))
  else
    log_info "  ok   NO docker on the box (the air-gap flow is podman + crane; it does not want a daemon)"
  fi
  printf '%s' "$out" | grep -q 'HAVE:newuidmap' || { log_error "  FAIL newuidmap missing — rootless podman cannot map uids"; fails=$((fails+1)); }

  # ---- LEG B: the operator ASKED for docker. -------------------------------------------------
  log_info "--- ${base} · CONTAINER_ENGINE=docker (the operator asked) ---"
  out="$(probe "$tag" docker)"
  if printf '%s' "$out" | grep -q 'HAVE:dockerd'; then
    log_info "  ok   docker engine installed"
  else
    log_error "  FAIL CONTAINER_ENGINE=docker did NOT install a docker engine"; fails=$((fails+1))
  fi
  if printf '%s' "$out" | grep -q 'HAVE:podman'; then
    log_error "  FAIL podman is ALSO installed — container_engine() prefers podman, so this box would"
    log_error "       silently run PODMAN while the operator believes they chose docker"
    fails=$((fails+1))
  else
    log_info "  ok   podman NOT installed (one engine, the one that was asked for)"
  fi
  # ROOTLESS: available from the distro on Photon (dockerd-rootless.sh in /usr/bin) and Ubuntu 26.04
  # (hidden in /usr/share/docker.io/contrib -> we symlink it onto PATH). NOT available on 24.04.
  if printf '%s' "$out" | grep -q 'HAVE:dockerd-rootless.sh'; then
    log_info "  ok   rootless docker is available (dockerd-rootless.sh on PATH) -> sudo-free, like podman"
    printf '%s' "$out" | grep -q 'HAVE:rootlesskit' \
      || { log_error "  FAIL dockerd-rootless.sh present but rootlesskit is MISSING — the daemon cannot start"; fails=$((fails+1)); }
  else
    # The ONLY acceptable outcome here is that we TOLD THE TRUTH about it.
    if printf '%s' "$out" | grep -q 'DISCLOSED:rootful-only'; then
      log_info "  ok   no distro rootless helper here, and we SAID SO (rootful-only => a sudo per registry)"
    else
      log_error "  FAIL no rootless helper AND no disclosure — the operator would discover the sudo cost on the lab"
      fails=$((fails+1))
    fi
  fi
  # THE LINE WE MUST NOT CROSS: never add a third-party apt repo to someone else's jump box.
  if printf '%s' "$out" | grep -q 'VIOLATION:third-party-repo-added'; then
    log_error "  FAIL the bootstrap added download.docker.com to the apt sources — that is a proxy-allowlist /"
    log_error "       security-review item on a real jump box, and it is not ours to decide"
    fails=$((fails+1))
  else
    log_info "  ok   no third-party apt repo was added"
  fi
done

[ "$fails" -eq 0 ] || die "$fails bootstrap-engine case(s) FAILED"
log_info "SUCCESS — the bootstrap produces a PODMAN jump box by default (zero docker), and a DOCKER one"
log_info "          when asked, on: ${OSES}"
