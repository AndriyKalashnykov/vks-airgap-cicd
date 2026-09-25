#!/usr/bin/env bash
# 18-engine-check.sh — READ-ONLY: does THIS box have what its chosen container engine needs, and what
# will that engine COST you? Changes nothing, contacts no registry, needs no cluster.
#
# This exists because the honest answer to "is docker supported?" is not a boolean — it is a table of
# PRECONDITIONS, and the one that matters to an operator is WHETHER THEY NEED ROOT:
#
#   podman            daemonless -> CA per COMMAND (--cert-dir)                    -> sudo-free, always
#   docker ROOTLESS   daemon reads ~/.config/docker/certs.d/<host>/ca.crt          -> sudo-free
#   docker ROOTFUL    daemon reads /etc/docker/certs.d/<host>/ca.crt  (root-owned) -> A SUDO PER REGISTRY
#
# The `docker` group grants access to the SOCKET. It does not grant write access to /etc. So the sudo on
# the rootful path cannot be engineered away — only disclosed, BEFORE the operator commits to an engine
# and discovers the cost on the lab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/engine.sh
. "${SCRIPT_DIR}/lib/engine.sh"
# shellcheck source=scripts/lib/rosetta.sh
. "${SCRIPT_DIR}/lib/rosetta.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

ENGINE="$(container_engine)"
printf '\n'
printf 'container engine : %s (%s)\n' "$ENGINE" "$(command -v "$ENGINE" 2>/dev/null || echo 'NOT INSTALLED')"
printf 'OS               : %s (%s)\n' "$(os_id)" "$(pkg_mgr)"

problems=0
note()  { printf '  %s\n' "$*"; }
prob()  { printf '  PROBLEM: %s\n' "$*"; problems=$((problems + 1)); }

# rosetta_check — Apple-silicon podman machine, amd64 target (B736). MEASURED on the Mac, podman 6.1.2:
#   QEMU aborts the .NET builder's `dotnet restore` (signal 6); Rosetta runs it. The Go, Node, Python
#   and Rust builders worked under QEMU. So QEMU is a PROBLEM only when a .NET app is enrolled.
#   `podman machine inspect` with no name reads podman-machine-default, not the machine behind the
#   default connection; the connection is named after its machine (a `-root` twin for rootful).
#   A malformed containers.conf (a second [machine] table, or a table glued to a line with no
#   trailing newline) makes EVERY podman command fail (measured), so the remedy is built for the
#   file's actual state instead of a blind append.
rosetta_check() {
  local m ros f have_dotnet=0 a
  m="$(podman system connection list --format '{{.Name}} {{.Default}}' 2>/dev/null \
       | awk '$2 == "true" { print $1; exit }' || true)"
  m="${m%-root}"
  ros="$(podman machine inspect ${m:+"$m"} --format '{{.Rosetta}}' 2>/dev/null || true)"
  while read -r a; do
    [ -n "$a" ] && [ "$(app_lang "$a")" = dotnet ] && have_dotnet=1
  done <<EOF_APPS
$(app_names)
EOF_APPS
  # /usr/bin/arch by full path: on a Mac coreutils' GNU `arch` is first on PATH and has no -x86_64.
  # ROSETTA_PROBE_BIN exists only so the offline test can stand in for it.
  if ! "${ROSETTA_PROBE_BIN:-/usr/bin/arch}" -x86_64 /usr/bin/true 2>/dev/null; then
    [ "$ros" != true ] || note "  Rosetta is enabled for the machine but NOT installed on this Mac"
    if [ "$have_dotnet" = 1 ]; then
      prob "no Rosetta 2 on this Mac, so amd64 builds use QEMU, which ABORTS the .NET builder. Install it:
             softwareupdate --install-rosetta --agree-to-license
           then enable it for the machine (run engine-check again for the exact lines)"
    else
      note "  emulation: QEMU (no Rosetta 2 on this Mac; no .NET app enrolled, so builds should work)"
    fi
    return 0
  fi
  case "$ros" in
    true) note "  emulation: Rosetta (on, machine ${m:-default}) — amd64 builds, .NET included, run under it" ;;
    false)
      [ "$have_dotnet" = 1 ] || { note "  emulation: QEMU (machine ${m:-default}); no .NET app enrolled, so builds should work"; return 0; }
      # A DROP-IN, never an edit of containers.conf: a second [machine] table breaks every podman
      # command, and legal TOML (`[ machine ]`, quoted keys) defeats a regex merge. MEASURED on the
      # Mac: a drop-in rosetta=true wins even over rosetta=false in the main file. lib/rosetta.sh.
      f="$(rosetta_dropin_path)"
      # Do not print a fix that cannot work (review, 2026-09-25): with CONTAINERS_CONF set podman ignores
      # the user files, and a LATER drop-in (e.g. 99-mine.conf) setting rosetta=false outranks ours.
      # Name the real cause instead; the operator's own key is theirs to change.
      local chosen=""
      if [ -n "${CONTAINERS_CONF:-}" ]; then
        prob "the machine ${m:-default} emulates amd64 with QEMU, which ABORTS the .NET builder, and CONTAINERS_CONF=${CONTAINERS_CONF} is set -- podman then ignores ~/.config/containers, so a drop-in there cannot help. Set  rosetta = true  in the [machine] table of ${CONTAINERS_CONF}, then:
             podman machine stop ${m} && podman machine start ${m}"
        return 0
      fi
      if chosen="$(rosetta_key_already_set)" && [ "$chosen" != "$f" ]; then
        prob "the machine ${m:-default} emulates amd64 with QEMU, which ABORTS the .NET builder, and ${chosen} already sets rosetta -- change it there to  rosetta = true  (a drop-in from us would not override a later one), then:
             podman machine stop ${m} && podman machine start ${m}"
        return 0
      fi
      prob "the machine ${m:-default} emulates amd64 with QEMU, which ABORTS the .NET builder. Use Rosetta:
             mkdir -p ${f%/*} && printf '[machine]\\nrosetta = true\\n' > ${f}
             podman machine stop ${m} && podman machine start ${m}" ;;
    *) note "  cannot read the Rosetta setting of machine ${m:-default}; if a .NET builder aborts under QEMU, enable Rosetta" ;;
  esac
}

if [ "$(os_id)" = macos ]; then
  # macOS (B735): the engine runs in a Linux VM (podman machine, colima, Docker Desktop). Every
  # host check below (newuidmap, /etc/subuid, cgroups, crun) is about the machine the containers
  # run on, and on a Mac that is the VM, not this box. MEASURED on the Mac: the Linux checks
  # reported 2 PROBLEMs for a podman machine that builds and runs fine.
  have "$ENGINE" || prob "${ENGINE} is not installed — run 'make deps'"
  if [ "$problems" -eq 0 ]; then
    vm_arch="$(engine_arch "$ENGINE")"
    if [ -z "$vm_arch" ]; then
      # Print the engine's OWN error: "not running" is the common cause, not the only one (a default
      # connection pointing at a removed machine, a stale DOCKER_HOST or docker context, ...).
      # `|| true`: this branch runs BECAUSE info failed, so without it `set -e` kills the script at this
      # assignment and the operator gets a bare rc, not the message below (found by review, RED-tested).
      _why="$("$ENGINE" info 2>&1 >/dev/null | tail -1 || true)"   # docker-ok: the operator's chosen engine
      if [ "$ENGINE" = podman ]; then
        prob "podman cannot reach its machine: ${_why:-no error text}
             not running?  podman machine init (first time) && podman machine start
             otherwise:    podman system connection list   # is the default the machine you started?"
      else
        prob "docker cannot reach its daemon: ${_why:-no error text}
             not running?  colima start, or open Docker Desktop
             otherwise:    docker context ls               # is the active context the VM you started?"
      fi
    else
      printf 'engine VM        : running, %s\n' "$vm_arch"
      if [ "$vm_arch" != "$(target_arch)" ]; then
        note "images are pushed as linux/$(target_arch), but this VM is ${vm_arch}: the two local builds"
        note "  (selfbuilt-image, builder-image) run under emulation and refuse to start without:"
        note "    BUILD_EMULATE=1 make install-all        # slow; see B736"
        # MEASURED on the Mac (podman 6.1.2, applehv): under QEMU the .NET builder's `dotnet restore`
        # aborts ("qemu: uncaught target signal 6"); with Rosetta the same image restores fine.
        if [ "$ENGINE" = podman ] && [ "$vm_arch" = arm64 ]; then rosetta_check; fi
      fi
    fi
  fi
  # MEASURED on the Mac (podman 6.1.2 remote): login and build take --cert-dir, pull and push do NOT.
  printf 'registry TLS     : crane (every push to Harbor) uses SSL_CERT_FILE -- nothing installed.\n'
  printf '                   The engine itself (%s pull/push) trusts inside its VM, which this repo\n' "$ENGINE"
  printf '                   does not configure on macOS: engine-trust-check / trust-harbor are Linux-only.\n'
  printf 'sudo required    : NO\n'
elif [ "$ENGINE" = podman ]; then
  have podman || prob "podman is not installed — run 'make deps'"
  have crun   || note "crun not found — rootless podman builds may fail (make deps installs it)"
  have newuidmap || prob "newuidmap missing (pkg 'uidmap') — rootless podman cannot map uids. Run 'make deps'."
  # ⚠️ THE CONTAINER MATRIX CANNOT SEE EITHER OF THE NEXT TWO CHECKS. `kernel.*` sysctls are not
  # namespaced, so `docker run photon:5.0 cat /proc/sys/kernel/unprivileged_userns_clone` reports the
  # HOST's value (measured: 1 on this Ubuntu host) and never Photon's own default. And
  # jumpbox/Dockerfile.photon:23-24 pre-writes /etc/subuid at image build. So `make jumpbox
  # JUMPBOX_OS=photon` is structurally blind to both, and a green 4/4 matrix says nothing about them.
  # They are observable only on a real VM — `make walkbox WALKBOX_OS=photon` or `make labbox`.
  #
  # MEASURED on a fresh Photon OS 5.0 VM 2026-08-11: unprivileged_userns_clone=0 and /etc/subuid
  # ABSENT. Rootless podman — this repo's DEFAULT engine — therefore could not build at all, and the
  # failure surfaced ~20 minutes into `make install-all` at `builder-image`:
  #     user namespaces are not enabled in /proc/sys/kernel/unprivileged_userns_clone
  #     Error: cannot re-exec process
  # CGROUP VERSION — the condition that actually killed two walk-matrix rows, and which this
  # preflight never mentioned (measured: 0 occurrences of "cgroup" before this). A rootless podman
  # build on a cgroup-v1 host dies at its FIRST RUN step with
  #     crun ... open `/sys/fs/cgroup/devices/buildah-...`: exit status 1
  # an error naming neither podman, nor cgroups, nor the user. It is HANDLED —
  # engine_build_isolation switches the build to chroot — so this is a NOTE, not a problem. The
  # point is that a preflight whose job is "can this box build rootless?" should say it up front
  # instead of letting it surface mid-build. Adversary-found 2026-08-27.
  if [ "$(container_engine)" = podman ]; then
    _cg="$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)"
    if [ "$_cg" = cgroup2fs ]; then
      note "cgroup v2 - rootless builds run with normal isolation"
    else
      note "cgroup v1 (${_cg}) - rootless podman cannot create a container cgroup here."
      note "  BUILDS are handled: engine_build_isolation switches them to BUILDAH_ISOLATION=chroot"
      note "  (weaker, bounded: our Dockerfile, our base)."
      note "  '<engine> run' DOES NOT WORK AT ALL here — crun cannot create the container cgroup"
      note "  under the root-owned v1 devices controller, and podman reports rc 127, the SAME code"
      note "  as a missing command. Nothing in the operator flow depends on it (measured)."
      # ⚠️ DO NOT PRINT A REMEDY HERE. This note used to say "systemd.unified_cgroup_hierarchy=1
      # gives v2", echoing Broadcom KB 380364. MEASURED 2026-08-28 on the stock Photon 5 GCE image
      # we build walkboxes from: that remedy is INERT. /boot/systemd.cfg ALREADY contains
      # `systemd.unified_cgroup_hierarchy=yes`, and /boot/grub2/grub.cfg expands $systemd_cmdline
      # exactly ZERO times -- it loads the env block and discards it, and the menuentry's `linux`
      # line is hardcoded (it matches /proc/cmdline byte for byte). grub2-editenv, grub2-mkconfig,
      # update-grub and /etc/default/grub are ALL ABSENT, and there is exactly ONE menuentry with no
      # fallback, so the only edit that could work is a hand edit of a static grub.cfg on a box we
      # were LENT -- with recovery only from a VM console a tenant may not have. An operator who
      # followed the old hint would edit a file that already says yes, reboot someone else's jump
      # box, still get v1, and have the KB's own verification fail with no diagnosis. So: report
      # what we MEASURED, and let the operator decide. The one command that decides whether the KB
      # applies to a given image is printed below.
      note "  Enabling v2 is NOT prescribed here: on the stock Photon 5 image /boot/systemd.cfg"
      note "  already sets it and grub discards it. To check YOUR image:"
      note "    grep -c '\\\$systemd_cmdline' /boot/grub2/grub.cfg   # 0 = the documented fix is inert"
    fi
  fi
  
  if [ -e /proc/sys/kernel/unprivileged_userns_clone ] \
     && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 1)" = 0 ]; then
    prob "kernel.unprivileged_userns_clone=0 — rootless podman cannot create a user namespace, so
           every build fails with 'cannot re-exec process'. Photon ships this OFF; Ubuntu ships it ON.
           This is a SYSTEM-WIDE hardening default, so we do not change it for you. To enable it:
             echo kernel.unprivileged_userns_clone=1 | sudo tee /etc/sysctl.d/99-vks-userns.conf
             sudo sysctl --system        # NOT 'sysctl -p' — with no argument that reads only /etc/sysctl.conf
             cat /proc/sys/kernel/unprivileged_userns_clone     # must print 1"
  fi
  # -s as well as 2>/dev/null: on a fresh Photon box the file does not EXIST, and -s is what
  # suppresses grep's own message. The `|| prob` keeps it safe under `set -e`.
  # DISTINGUISH "no entry" from "cannot read it". MEASURED 2026-08-11: `sudo tee` creates
  # /etc/subuid 0600, podman runs as the operator and gets "permission denied", then silently uses a
  # single-id map — so a bare grep reports "no entry" and sends you to add one that is already there.
  if [ -f /etc/subuid ] && [ ! -r /etc/subuid ]; then
    prob "/etc/subuid exists but is NOT READABLE by $(id -un) — podman falls back to a single-id map
           and every build that chowns fails. These files are public id-allocation metadata:
             sudo chmod 0644 /etc/subuid /etc/subgid"
  fi
  grep -qs "^$(id -un):" /etc/subuid 2>/dev/null \
    || prob "no /etc/subuid entry for $(id -un) — rootless podman cannot map uids, and a build dies
           with 'potentially insufficient UIDs or GIDs available in user namespace'. NOTE: 'usermod'
           does not exist on a bare Photon box (the podman package set is 'podman crun'), so use:
             printf '%s:100000:65536\\n' \"$(id -un)\" | sudo tee -a /etc/subuid /etc/subgid
             podman system migrate       # clears the pause process that pins the OLD mapping
           Check first that 100000-165535 does not overlap an existing entry, and prefer
           'getsubids \"$(id -un)\"' where it exists — it consults NSS, which grep cannot see."
  printf 'registry TLS     : --cert-dir, PER COMMAND (nothing installed, no daemon)\n'
  printf 'sudo required    : NO  — podman is daemonless. This is why it is the default.\n'
else
  # DOCKER. Classify the daemon; engine_mode FAILS CLOSED, so an unreachable daemon says so rather than
  # being silently assumed rootful (which would make us sudo-write a CA into the operator's /etc).
  if ! docker info >/dev/null 2>&1; then   # docker-ok: only reached when the operator CHOSE docker (container_engine() returned it), so the binary exists by construction
    prob "the docker daemon is not reachable. Start it (rootful: 'sudo systemctl start docker' · rootless:
           'systemctl --user start docker'), or use podman — the default, no daemon, no sudo:
           unset CONTAINER_ENGINE"
    printf '\nengine-check: %d problem(s)\n\n' "$problems"
    exit 1
  fi
  MODE="$(engine_mode docker)"
  printf 'docker mode      : %s\n' "$MODE"
  if [ "$MODE" = docker-rootless ]; then
    printf 'registry TLS     : %s/.config/docker/certs.d/<registry>/ca.crt  (your HOME)\n' "$HOME"
    printf 'sudo required    : NO  — rootless docker matches podman ergonomics exactly.\n'
    have dockerd-rootless.sh || note "dockerd-rootless.sh not on PATH (the daemon is already up, so this is cosmetic)"
  else
    printf 'registry TLS     : /etc/docker/certs.d/<registry>/ca.crt  (ROOT-OWNED)\n'
    printf 'sudo required    : YES — ONE PER REGISTRY. The docker group grants SOCKET access, not write\n'
    printf '                   access to /etc, so this cannot be engineered away.\n'
    if have dockerd-rootless.sh; then
      note "this box CAN run rootless docker (dockerd-rootless.sh is present) — that mode needs no sudo:"
      note "  dockerd-rootless-setuptool.sh install   # then: export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/docker.sock"
    elif [ "$(pkg_mgr)" = apt-get ]; then
      note "no rootless helper on this Ubuntu: 24.04's docker.io ships none (26.04+ does). Getting it means"
      note "  adding download.docker.com — a third-party repo we will NOT add to your jump box. So on THIS"
      note "  box docker is rootful-only. podman needs no sudo at all: unset CONTAINER_ENGINE"
    fi
  fi
  # A CA file that does not exist is NOT proof docker will fail: docker MERGES certs.d with the host
  # SYSTEM STORE, so an operator who ran update-ca-certificates already works. Never gate on the file.
  note "(a missing ca.crt does NOT mean docker will fail — docker merges certs.d with the system trust"
  note " store. The only honest test of trust is a handshake: 'make trust-harbor'.)"
fi

printf '\n'
if [ "$problems" -eq 0 ]; then
  log_info "engine-check: OK — ${ENGINE} has what it needs on this box"
else
  die "engine-check: ${problems} problem(s) above"
fi
