#!/usr/bin/env bash
# ci-tier: fast — offline; dry-walks a fixture document under mktemp. No network, no cluster.
# test-walk-doc-os-blocks.sh — walk-doc.sh must run each OS-specific block ONLY on its own OS.
#
# The scenario docs carry per-OS twins: an apt block (Ubuntu), a tdnf block (Photon), a brew block
# (macOS), and a `make deps` / `gmake deps` pair (Linux / macOS). A walk that runs the WRONG twin dies
# on the first command — `gmake` is absent on Linux (127), and Apple's make 3.81 refuses the Makefile
# on a Mac (rc=2, measured 2026-09-25). None of these rules had a test; the brew rule's own comment
# records it being found by review after every Linux row died 127.
#
# ORDER is load-bearing: "gmake deps" also contains "make deps", so a case arm for the Linux block
# placed first would skip the macOS twin on the Mac too. The mixed case below pins that.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
W=scripts/walk-doc.sh
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

cat > "$T/doc.md" <<'EOF'
# fixture

## A. ubuntu

```bash
sudo apt-get install -y git
```

## B. photon

```bash
sudo tdnf install -y git
```

## C. macos brew

```bash
brew install git
```

## D. linux deps

```bash
make deps
make shell-init
```

## E. macos deps

```bash
gmake deps
gmake shell-init
```
EOF

walk() { WALK_DOC="$T/doc.md" WALK_OS="$1" WALK_EXISTS=1 WALK_ROBOT_EXISTS=1 WALK_ISTIO=existing \
           WALK_MIN_BLOCKS=1 WALK_DRY=1 bash "$W" 2>&1; }
# the SECTION letters of every SKIPPED block, e.g. "A B E"
skipped() { printf '%s\n' "$1" | grep -E 'SKIPPED' | grep -oE '\] [A-E]\.' | tr -d '] .' | sort | tr '\n' ' ' | sed 's/ $//'; }

for row in "ubuntu:B C E" "photon:A C E" "macos:A B D"; do
  os="${row%%:*}"; want="${row#*:}"
  out="$(walk "$os")"; rc=$?
  got="$(skipped "$out")"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "$os row skips exactly [$want]"
  else bad "$os row: rc=$rc skipped [$got], want [$want]"; printf '%s\n' "$out" | tail -15 | sed 's/^/        | /'; fi
done

printf 'test-walk-doc-os-blocks: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
