#!/usr/bin/env bash
# test-engine-check-macos.sh — B735/B736: 18-engine-check.sh on an Apple-silicon podman machine.
#
# Offline. A faked uname answers Darwin/arm64, a stub podman plays the machine, ROSETTA_PROBE_BIN
# stands in for /usr/bin/arch. What each case pins (all from review findings, 2026-09-24):
#   engine unreachable     -> the PROBLEM text prints (it used to die at the `$(...)` under set -e)
#   inspect fails          -> a note, NOT a blocking PROBLEM (it used to read as "Rosetta off")
#   Rosetta on             -> OK, naming the machine behind the DEFAULT connection
#   Rosetta off            -> PROBLEM whose printed command, EXECUTED, writes a valid DROP-IN
#                             (containers.conf.d/50-vks-rosetta.conf) and leaves the operator's
#                             containers.conf BYTE-IDENTICAL -- absent, no trailing newline, or already
#                             holding a [machine] table. MEASURED on the Mac: a malformed
#                             containers.conf makes every podman command fail; a drop-in wins over it.
#   no Rosetta 2 on host   -> PROBLEM naming softwareupdate (the registry enrolls a .NET app)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); printf '  ok    %s\n' "$1"; }
bad() { n=$((n+1)); fail=1; printf '  FAIL  %s\n' "$1"; }

mkdir -p "$T/bin"
# shellcheck disable=SC2016  # the generated scripts own their $1/$2
printf '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n' > "$T/bin/uname"
# shellcheck disable=SC2016
cat > "$T/bin/podman" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "info --format") [ -n "${FAKE_INFO_FAIL:-}" ] && exit 125; echo aarch64 ;;
  "info ")         echo "Error: unable to connect to Podman socket: connection refused" >&2; exit 125 ;;
  "system connection") printf 'mymachine true\nmymachine-root false\n' ;;
  "machine inspect")
    [ "$3" = mymachine ] || { echo "Error: $3: VM does not exist" >&2; exit 125; }
    [ "$FAKE_ROS" = fail ] && { echo "Error: boom" >&2; exit 125; }
    echo "$FAKE_ROS" ;;
  *) exit 0 ;;
esac
EOF
# shellcheck disable=SC2016  # the generated probe owns its $FAKE_HOST_ROS
printf '#!/bin/sh\nexit "${FAKE_HOST_ROS:-0}"\n' > "$T/probe"
chmod +x "$T/bin/uname" "$T/bin/podman" "$T/probe"

# run_ec [ENV=VAL ...] — engine-check with the stubs; output in $T/out, rc in $rc
run_ec() {
  # shellcheck disable=SC2031  # os.sh assigns PATH on macOS only; this per-command PATH is intended
  env PATH="$T/bin:$PATH" SKIP_DOTENV=1 CONTAINER_ENGINE=podman ROSETTA_PROBE_BIN="$T/probe" \
      XDG_CONFIG_HOME="$T/cfg" FAKE_ROS=true "$@" bash "$SCRIPT_DIR/18-engine-check.sh" > "$T/out" 2>&1
  rc=$?
}
has() { grep -q -- "$1" "$T/out"; }
# valid_toml <file> — parse with Python's tomllib (podman's parser rejects the same two shapes)
valid_toml() { python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$1" 2>/dev/null; }
# run_remedy — execute the printed `mkdir … && printf … >> …` line exactly as printed
run_remedy() { local l; l="$(grep -E "^[[:space:]]+mkdir -p .* && printf '" "$T/out" | sed 's/^[[:space:]]*//')"; [ -n "$l" ] && bash -c "$l"; }

echo "== engine unreachable: the message prints (not a bare rc)"
run_ec FAKE_INFO_FAIL=1
if [ "$rc" -ne 0 ] && has 'podman cannot reach its machine' && has 'connection refused'; then ok "PROBLEM with podman's own error"
else bad "want the PROBLEM text, got rc=$rc: $(tail -2 "$T/out" | tr '\n' ' ')"; fi

echo "== inspect fails: a note, not a PROBLEM"
run_ec FAKE_ROS=fail
if [ "$rc" -eq 0 ] && has 'cannot read the Rosetta setting' && ! has 'PROBLEM'; then ok "non-blocking note"
else bad "want rc 0 + note, got rc=$rc"; fi

echo "== Rosetta on: OK, naming the default connection's machine"
run_ec FAKE_ROS=true
if [ "$rc" -eq 0 ] && has 'Rosetta (on, machine mymachine)'; then ok "OK, machine mymachine"
else bad "got rc=$rc: $(grep -i rosetta "$T/out" | tr '\n' ' ')"; fi

DROPIN="$T/cfg/containers/containers.conf.d/50-vks-rosetta.conf"
MAIN="$T/cfg/containers/containers.conf"
echo "== Rosetta off, no containers.conf: the printed command writes a valid DROP-IN, no main file"
rm -rf "$T/cfg"
run_ec FAKE_ROS=false
if [ "$rc" -ne 0 ] && has 'podman machine stop mymachine' && run_remedy && valid_toml "$DROPIN" \
   && grep -qx 'rosetta = true' "$DROPIN" && [ ! -e "$MAIN" ]; then ok "PROBLEM; remedy creates a valid drop-in and no main file"
else bad "rc=$rc; drop-in: $(cat "$DROPIN" 2>&1 | tr '\n' '|'); main exists: $([ -e "$MAIN" ] && echo yes || echo no)"; fi

echo "== Rosetta off, main file with NO trailing newline: the remedy leaves it BYTE-IDENTICAL"
rm -rf "$T/cfg"; mkdir -p "$T/cfg/containers"; printf '[engine]\ncgroup_manager = "systemd"' > "$MAIN"; cp "$MAIN" "$T/main.before"
run_ec FAKE_ROS=false
if run_remedy && cmp -s "$MAIN" "$T/main.before" && valid_toml "$DROPIN"; then ok "main file untouched; drop-in valid"
else bad "main changed or drop-in invalid: $(tr '\n' '|' < "$MAIN")"; fi

echo "== Rosetta off, [machine] already in the main file: still a drop-in, never a second [machine] there"
rm -rf "$T/cfg"; mkdir -p "$T/cfg/containers"; printf '[machine]\ncpus = 4\n' > "$MAIN"; cp "$MAIN" "$T/main.before"
run_ec FAKE_ROS=false
if [ "$rc" -ne 0 ] && run_remedy && cmp -s "$MAIN" "$T/main.before" && valid_toml "$MAIN" && valid_toml "$DROPIN" \
   && [ "$(grep -c '^\[machine\]' "$MAIN")" = 1 ]; then ok "drop-in only; the existing [machine] table is untouched"
else bad "got rc=$rc: $(grep -iE 'machine|printf' "$T/out" | tr '\n' ' ')"; fi

echo "== no Rosetta 2 on the host: softwareupdate"
run_ec FAKE_ROS=false FAKE_HOST_ROS=1
if [ "$rc" -ne 0 ] && has 'softwareupdate --install-rosetta'; then ok "PROBLEM names softwareupdate"
else bad "got rc=$rc"; fi

echo "test-engine-check-macos: ${n} checks"
[ "$fail" -eq 0 ] && { echo "test-engine-check-macos: OK"; exit 0; }
echo "test-engine-check-macos: FAILED"; exit 1
