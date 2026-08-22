#!/usr/bin/env bash
# Offline RED/GREEN for 09-harbor-auth-check.sh (B209). The gate is a thin wrapper over
# harbor_auth_report, which test-harbor-auth-report.sh already proves against a live TLS oracle —
# so this proves the WRAPPER: does a reporter failure become a non-zero exit that NAMES THE FIX,
# and does a clean report stay green? Stubs the libs in a throwaway dir; touches no real Harbor
# (a deliberate bad-password probe against a live registry is not a thing to fire off casually).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lib"
cp "$SCRIPT_DIR/09-harbor-auth-check.sh" "$T/"
cat > "$T/lib/os.sh" <<'STUB'
log_info(){ printf 'INFO %s\n' "$*"; }
log_error(){ printf 'ERROR %s\n' "$*" >&2; }
load_env(){ :; }
harbor_settle_note(){ printf '%smake harbor-admin-password\n' "${1:-}" >&2; }
STUB
cat > "$T/lib/harbor.sh" <<'STUB'
harbor_auth_report(){ return "${STUB_RC:-0}"; }
STUB

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"; else f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; fi; }

# GREEN: reporter clean -> exit 0
rc=0; STUB_RC=0 bash "$T/09-harbor-auth-check.sh" >/dev/null 2>&1 || rc=$?
ck "clean report -> exit 0" "$rc" "0"

# RED: reporter fails -> non-zero AND names the fix
rc=0; out=$(STUB_RC=1 bash "$T/09-harbor-auth-check.sh" 2>&1) || rc=$?
ck "failing report -> non-zero"            "$rc" "1"
ck "RED names harbor-admin-password"       "$(printf '%s' "$out" | grep -c 'make harbor-admin-password')" "1"
ck "RED says why it refused (20-minute)"   "$(printf '%s' "$out" | grep -ci 'refusing')" "1"

# the sneakernet invariant, asserted in the Makefile itself
ck "mirror IS gated"       "$(grep -cE '^mirror: harbor-auth-check ' "$SCRIPT_DIR/../Makefile")" "1"
ck "mirror-pull NOT gated" "$(grep -cE '^mirror-pull:.*harbor-auth-check' "$SCRIPT_DIR/../Makefile")" "0"

printf '\n  %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
