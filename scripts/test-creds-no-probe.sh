#!/usr/bin/env bash
# `CREDS_NO_PROBE=1` must actually stop the probes — and a `.env` must never be able to RE-ARM them.
#
# WHY THIS EXISTS. `.env.example` documents CREDS_NO_PROBE, so an operator sets it in `.env`. But the
# snapshot is taken at creds.sh:52, BEFORE load_env — deliberately, so a `.env` line cannot turn
# probing back ON while two offline fixtures carry REAL lab IPs. That guard is right. It was also
# SYMMETRIC, and only one direction is a safety property.
#
# MEASURED 2026-09-07, `CREDS_NO_PROBE=1` in `.env`: the report made FIVE live cluster calls,
# including `kubectl -n headlamp create token headlamp-viewer --duration=24h` — it MINTED A
# CREDENTIAL — while its own banner read the LIVE variable and announced "nothing was probed".
# The operator's documented lever did nothing, and the report lied in the reassuring direction.
#
# ⚠️ THE CONTROL (arm 3) IS NOT OPTIONAL. Guarding probes is one `if` away from disabling them
# entirely, and that failure is invisible: a report with no probes still prints. Measured while
# writing this — an early version showed 0/0/0 and looked like a triumph; the control was 0 too,
# i.e. the fix had killed probing outright. Then a SECOND instrument failure: reusing one sandbox
# across arms made the control read 0 because arms 1-2 left state. One sandbox PER ARM, always.
#
# ⚠️ ONE `kubectl` SURVIVES under no-probe, deliberately: `config view --minify` reads the local
# kubeconfig FILE and contacts nothing. MEASURED against a black-holed server: 24 ms, vs 6005 ms
# for a real cluster call on the same file. So the banner's "reporting configuration only" is
# literally true, and the assertion below counts CLUSTER calls, not `kubectl` invocations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

SRC="${REPO_ROOT}"
pass=0; fail=0

# A sandbox with argv-logging shims. `exit 1` so nothing downstream believes a call succeeded.
_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/bin"; : > "$d/kc"
  local c
  for c in kubectl curl getent; do
    # shellcheck disable=SC2016  # the single quotes are the POINT: $* and $CALLS must reach
    # the SHIM at run time, not be expanded here into the shim's source.
    printf '#!/usr/bin/env bash\ncase "$*" in *"config view"*) : ;; *) echo "%s $*" >> "$CALLS" ;; esac\nexit 1\n' "$c" \
      > "$d/bin/$c"
    chmod +x "$d/bin/$c"
  done
  cp -r --preserve=mode "$SRC/scripts" "$d/scripts"
  cp "$SRC/.env.example" "$d/.env.example"
  printf '%s' "$d"
}

# calls <label> <want: 0 | positive> [dotenv-line] [env-assignment]
calls() {
  local label="$1" want="$2" dotenv="${3:-}" envset="${4:-}" d n
  d="$(_sandbox)"; export CALLS="$d/calls.log"; : > "$CALLS"
  [ -n "$dotenv" ] && printf '%s\n' "$dotenv" > "$d/.env"
  ( cd "$d" && env REPO_ROOT="$d" KUBECONFIG="$d/kc" ${envset:+"$envset"} PATH="$d/bin:$PATH" \
      timeout 120 bash scripts/creds.sh >/dev/null 2>&1 ) || true
  n="$(wc -l < "$CALLS" | tr -d ' ')"
  rm -rf "$d"
  case "$want" in
    0)        if [ "$n" -eq 0 ]; then printf '  ok   %-52s %s cluster call(s)\n' "$label" "$n"; pass=$((pass+1));
              else printf '  FAIL %-52s %s cluster call(s), want 0\n' "$label" "$n"; fail=$((fail+1)); fi ;;
    positive) if [ "$n" -gt 0 ]; then printf '  ok   %-52s %s cluster call(s)\n' "$label" "$n"; pass=$((pass+1));
              else printf '  FAIL %-52s %s — the guard DISABLED probing outright\n' "$label" "$n"; fail=$((fail+1)); fi ;;
  esac
}

echo "== creds.sh CREDS_NO_PROBE — RED-proof =="
calls "1 CREDS_NO_PROBE=1 in .env stops every probe" 0        'CREDS_NO_PROBE=1'
calls "2 SAFETY: a .env may NOT re-arm probing"      0        'CREDS_NO_PROBE=0' 'CREDS_NO_PROBE=1'
calls "3 CONTROL: unset -> probing still happens"    positive
calls "4 CREDS_NO_PROBE=1 in the ENVIRONMENT"        0        ''                'CREDS_NO_PROBE=1'

echo
if [ "$fail" -ne 0 ]; then echo "creds no-probe: ${fail} FAILED, ${pass} passed"; exit 1; fi
echo "creds no-probe: ALL ${pass} passed"
