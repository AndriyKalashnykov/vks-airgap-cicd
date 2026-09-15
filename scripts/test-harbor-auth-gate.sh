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

# B728: the clean-report SUMMARY must not RE-ASSURE about a state it never probed. harbor_auth_report
# returns 0 for "nothing was probed" too (no URL / placeholder password / no CA / inconclusive), so the
# success line must DEFER to the line above and never claim "you have it" / "silent above". Positive
# control: replacing these two log_info lines with the old `Checked: ... (silent above = you have it)`
# drives 3 of these RED (reassure + silent-above + defer); merely ADDING it alongside drives 2.
out0=$(STUB_RC=0 bash "$T/09-harbor-auth-check.sh" 2>&1)
ck "clean summary does NOT reassure ('you have it')" "$(printf '%s' "$out0" | grep -c 'you have it')" "0"
ck "clean summary drops 'silent above'"              "$(printf '%s' "$out0" | grep -c 'silent above')" "0"
ck "clean summary defers to the line above"          "$(printf '%s' "$out0" | grep -c 'ONLY what the line above says')" "1"
ck "clean summary keeps the push hedge"              "$(printf '%s' "$out0" | grep -c 'proves push')" "1"

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
