#!/usr/bin/env bash
# lib/rosetta.sh — put an Apple-silicon podman machine on ROSETTA, not QEMU (B735/B736).
#
# WHY: the images are linux/amd64 and an Apple-silicon podman machine is arm64, so the local builds
# run under emulation. Under QEMU the .NET builder's `dotnet restore` ABORTS (signal 6); under Rosetta
# it runs. MEASURED 2026-09-25, macOS 26.6.2, podman 6.1.2 (applehv):
#   - `podman machine init` with no config           -> .Rosetta = false   (QEMU; the default)
#   - a drop-in containers.conf.d/*.conf rosetta=true -> .Rosetta = true
#   - main containers.conf rosetta=false + that drop-in -> .Rosetta = true  (the drop-in WINS)
#   - there is no `--rosetta` flag on `podman machine init`
# And (podman source, pkg/machine/applehv/stubber.go) the setting is re-read on EVERY machine start,
# so writing it affects every existing machine at its next restart -- not only new ones.
#
# DESIGN (idea-round adversary, 2026-09-25):
#   * a DROP-IN file, never an edit of the operator's containers.conf: a second [machine] table
#     breaks every podman command, and legal TOML (`[ machine ]`, quoted keys, comments) defeats any
#     regex that tries to merge into it.
#   * only when NO machine exists at all (`podman machine list` empty) -- `podman machine inspect`
#     with no name checks only podman-machine-default, so it misses a machine with any other name.
#   * never when the operator already chose (an active `rosetta` key anywhere podman reads), and
#     never when CONTAINERS_CONF is set (podman then ignores the user files, so the write is dead).
#   * only on real Apple silicon: `sysctl hw.optional.arm64` = 1. The Rosetta probe alone succeeds
#     natively on an Intel Mac, and `uname -m` reports x86_64 under an x86 shell on Apple silicon.
#   * the caller VERIFIES `.Rosetta` after starting the machine -- a write is not a result.
# Bash 3.2-clean: 00-install-prereqs.sh sources it before Homebrew bash exists.

# The DEFAULT podman machine's name. MEASURED (podman 6.1.2): `podman machine list --format '{{.Name}}'`
# prints the default machine WITH a trailing `*` ("podman-machine-default*"), which `inspect` rejects --
# so strip it. Never `podman machine inspect` with no name: that reads podman-machine-default only.
rosetta_default_machine() {
  podman machine list --format '{{.Name}} {{.Default}}' 2>/dev/null \
    | awk '$2 == "true" { sub(/\*$/, "", $1); print $1; exit }'
}

# The drop-in this repo owns. One `rm` undoes it.
rosetta_dropin_path() {
  printf '%s/containers/containers.conf.d/50-vks-rosetta.conf' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# 0 when the operator has ALREADY set an active `rosetta` key in any file podman reads (so we must not
# override it); prints the file. Comments are skipped; a quoted key counts. Our own drop-in is ignored.
# $1 (optional) = the system config dir, default /etc/containers (tests pass a fixture).
rosetta_key_already_set() {
  local sysdir="${1:-/etc/containers}" user ours f
  user="${XDG_CONFIG_HOME:-$HOME/.config}/containers"
  ours="$(rosetta_dropin_path)"
  for f in "$user/containers.conf" "$user"/containers.conf.d/*.conf \
           "$sysdir/containers.conf" "$sysdir"/containers.conf.d/*.conf; do
    [ -f "$f" ] || continue
    [ "$f" = "$ours" ] && continue
    if grep -Eqs '^[[:space:]]*"?rosetta"?[[:space:]]*=' "$f"; then printf '%s' "$f"; return 0; fi
  done
  return 1
}

# 0 when this is Apple silicon WITH Rosetta 2 installed. ROSETTA_PROBE_BIN stands in for
# /usr/bin/arch in the offline tests (as it does in 18-engine-check.sh).
rosetta_host_capable() {
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || return 1
  "${ROSETTA_PROBE_BIN:-/usr/bin/arch}" -x86_64 /usr/bin/true 2>/dev/null
}

# Write the drop-in when every condition holds; print one line saying what it did and why.
# Returns 0 when it wrote (or the drop-in was already there), 1 when it deliberately did nothing.
# Call it ONLY when no podman machine exists yet.
rosetta_ensure_dropin() {
  local d f already
  if [ -n "${CONTAINERS_CONF:-}" ]; then
    printf 'rosetta: CONTAINERS_CONF is set, so podman ignores the user config files - not writing a drop-in\n'; return 1
  fi
  if ! rosetta_host_capable; then
    printf 'rosetta: not an Apple-silicon Mac with Rosetta 2 - leaving the podman machine on its default\n'; return 1
  fi
  if already="$(rosetta_key_already_set "${1:-}")"; then
    printf 'rosetta: %s already sets it - that is your choice, not overriding it\n' "$already"; return 1
  fi
  f="$(rosetta_dropin_path)"; d="${f%/*}"
  if [ -f "$f" ]; then printf 'rosetta: %s already present\n' "$f"; return 0; fi
  if ! { mkdir -p "$d" && printf '[machine]\nrosetta = true\n' > "$f"; }; then
    printf 'rosetta: could not write %s\n' "$f"; return 1
  fi
  printf 'rosetta: wrote %s so the new podman machine uses Rosetta, not QEMU (the .NET builder aborts under QEMU)\n' "$f"
  return 0
}
