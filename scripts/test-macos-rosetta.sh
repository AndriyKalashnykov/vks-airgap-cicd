#!/usr/bin/env bash
# ci-tier: fast — offline; stub sysctl/podman/arch on a private PATH, throwaway XDG dirs. No VM.
# test-rosetta.sh — lib/rosetta.sh, the drop-in that puts a NEW Apple-silicon podman
# machine on Rosetta (under QEMU the .NET builder aborts; measured on the Mac 2026-09-25).
#
# Each case is one condition of the design an adversary round prescribed:
#   Apple silicon + Rosetta 2, nothing configured  -> writes the drop-in, valid TOML
#   run twice                                       -> idempotent (same bytes, "already present")
#   Intel (hw.optional.arm64 != 1)                  -> writes nothing (the Rosetta probe alone passes there)
#   no Rosetta 2                                    -> writes nothing
#   CONTAINERS_CONF set                             -> writes nothing (podman would ignore the user files)
#   operator set `rosetta` in their containers.conf -> writes nothing, even `rosetta = false`
#   a QUOTED key / a key in a user drop-in / in the system dir -> all count as "already set"
#   a COMMENTED key                                 -> does NOT count (still writes)
#   rosetta_default_machine                         -> strips the trailing `*` podman prints (measured)
# shellcheck disable=SC2016  # single quotes are the point: bash -c bodies and stub scripts
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
valid_toml() { python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$1" 2>/dev/null; }

mkdir -p "$T/bin"
printf '#!/bin/sh\necho "${FAKE_ARM64:-1}"\n' > "$T/bin/sysctl"
printf '#!/bin/sh\n[ "${FAKE_ROSETTA:-1}" = 1 ]\n' > "$T/bin/archprobe"
printf '#!/bin/sh\nprintf "other-vm false\\npodman-machine-default* true\\n"\n' > "$T/bin/podman"
chmod +x "$T/bin/"*

# run <case-dir> [VAR=val ...] -- one fresh config tree per case; prints the function's line, rc on the last
run() {
  local c="$1"; shift
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/$c/home" XDG_CONFIG_HOME="$T/$c/xdg" \
      ROSETTA_PROBE_BIN="$T/bin/archprobe" "$@" \
      bash -c '. scripts/lib/rosetta.sh; rosetta_ensure_dropin "$0"; echo "rc=$?"' "$T/$c/etc"
}
dropin() { printf '%s' "$T/$1/xdg/containers/containers.conf.d/50-vks-rosetta.conf"; }
mk() { mkdir -p "$(dirname "$1")"; printf '%b' "$2" > "$1"; }

o="$(run fresh)"
if printf '%s' "$o" | grep -q 'rc=0' && valid_toml "$(dropin fresh)" && grep -qx 'rosetta = true' "$(dropin fresh)"; then
  ok "Apple silicon + Rosetta 2, nothing set: writes a valid drop-in"
else bad "fresh: $o"; fi

cp "$(dropin fresh)" "$T/before"
o="$(run fresh)"
if printf '%s' "$o" | grep -q 'already present' && cmp -s "$(dropin fresh)" "$T/before"; then ok "second run is idempotent"
else bad "second run: $o"; fi

for spec in "intel:FAKE_ARM64=0:not an Apple-silicon" "norosetta:FAKE_ROSETTA=0:not an Apple-silicon" \
            "cc:CONTAINERS_CONF=/x.conf:CONTAINERS_CONF is set"; do
  c="${spec%%:*}"; rest="${spec#*:}"; var="${rest%%:*}"; want="${rest#*:}"
  o="$(run "$c" "$var")"
  if printf '%s' "$o" | grep -q "$want" && printf '%s' "$o" | grep -q 'rc=1' && [ ! -e "$(dropin "$c")" ]; then
    ok "$c: writes nothing ($want)"
  else bad "$c: $o"; fi
done

# the operator already chose -- every place podman reads, and every spelling of the key
mk "$T/userfalse/xdg/containers/containers.conf" '[machine]\nrosetta = false\n'
mk "$T/quoted/xdg/containers/containers.conf" '[machine]\n"rosetta" = true\n'
mk "$T/userdrop/xdg/containers/containers.conf.d/10-mine.conf" '[machine]\nrosetta=false\n'
mk "$T/sysdir/etc/containers.conf" '[machine]\n  rosetta = true\n'
for c in userfalse quoted userdrop sysdir; do
  o="$(run "$c")"
  if printf '%s' "$o" | grep -q 'your choice' && [ ! -e "$(dropin "$c")" ]; then ok "$c: an existing key is respected, no drop-in"
  else bad "$c: $o"; fi
done

mk "$T/commented/xdg/containers/containers.conf" '[machine]\n# rosetta = false\ncpus = 4\n'
o="$(run commented)"
if printf '%s' "$o" | grep -q 'rc=0' && [ -e "$(dropin commented)" ]; then ok "a COMMENTED key does not count: drop-in written"
else bad "commented: $o"; fi

got="$(env -i PATH="$T/bin:/usr/bin:/bin" bash -c '. scripts/lib/rosetta.sh; rosetta_default_machine')"
if [ "$got" = podman-machine-default ]; then ok "rosetta_default_machine strips podman's trailing '*'"
else bad "rosetta_default_machine returned [$got]"; fi

printf 'test-macos-rosetta: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
