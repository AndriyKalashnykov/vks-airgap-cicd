#!/usr/bin/env bash
# scripts/test-uninstall-honesty.sh — 98-uninstall-all.sh must never ASSERT ABSENCE FROM A FAILED READ.
#
# WHY THIS EXISTS. kubectl exits 1 for a genuine NotFound, for an unreachable API, AND for a
# forbidden read. 98-uninstall-all.sh used a bare `if ! k get X >/dev/null 2>&1; then "- absent"`, which
# collapses all three into the same sentence — in a TEARDOWN, where the wrong direction to be wrong
# in is reporting an object gone when the truth is that we could not look. Nothing offline covered
# this script at all (test-kind-down-safety covers the REVERSIBLE KinD teardown; the irreversible
# lab one had no test), so the defect was invisible to every gate.
#
# These cases drive read_state/absent_or_unknown — the real helpers, extracted from the shipping
# script, never a copy — and assert the THREE STATES PRODUCE THREE DIFFERENT STRINGS. A test that
# only checked "it printed something" would pass on the bug.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable so the RED-proof can point at a deliberately-broken copy.
TARGET="${UNINSTALL_SCRIPT:-${SCRIPT_DIR}/98-uninstall-all.sh}"
[ -f "$TARGET" ] || { echo "FAIL: $TARGET missing"; exit 1; }

# Extract the two helpers. If extraction ever yields nothing, FAIL LOUDLY rather than proving
# nothing about an empty function.
FN="$(sed -n '/^read_state()/,/^}/p;/^absent_or_unknown()/,/^}/p' "$TARGET")"
case "$FN" in
  *"read_state()"*) : ;;
  *) echo "FAIL: could not extract read_state from $TARGET (renamed?)"; exit 1 ;;
esac
case "$FN" in
  *"absent_or_unknown()"*) : ;;
  *) echo "FAIL: could not extract absent_or_unknown from $TARGET (renamed?)"; exit 1 ;;
esac

pass=0; fail=0
check() { # check <name> <expect-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1"; echo "        wanted: $2"; echo "        got:    $3"; fail=$((fail+1)); fi
}
refute() { # refute <name> <forbidden-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "  FAIL  $1"; echo "        must NOT contain: $2"; echo "        got: $3"; fail=$((fail+1))
  else echo "  PASS  $1"; pass=$((pass+1)); fi
}

# Drive the real helpers with a stubbed `k`. The stub models kubectl's ACTUAL behaviour: it writes
# the diagnosis to STDERR and exits non-zero — which is exactly what the bare `2>&1`-discarding
# form threw away.
run_case() { # run_case <stub-stderr> <stub-rc>
  ( set +e
    _SE="$1"; _RC="$2"
    # shellcheck disable=SC2329  # invoked indirectly by the extracted read_state
    k() { [ -n "$_SE" ] && printf '%s\n' "$_SE" >&2; return "$_RC"; }
    # shellcheck disable=SC2329  # invoked indirectly by the extracted absent_or_unknown
    note() { printf '%s\n' "$*"; }
    # shellcheck disable=SC2329  # invoked indirectly by the extracted absent_or_unknown
    left() { printf 'LEFT:%s\n' "$*"; }
    eval "$FN"
    if ! read_state get application demo; then absent_or_unknown demo; else echo "EXISTS"; fi
  ) 2>&1
}

echo "uninstall-all honesty — three states must not collapse"

# 1. the object genuinely does not exist
out="$(run_case 'Error from server (NotFound): applications.argoproj.io "demo" not found' 1)"
check  "NotFound  => absent"                 "demo: absent" "$out"
refute "NotFound  => not reported unknown"   "CANNOT READ"  "$out"

# 2. the API could not be reached — THE CASE THIS TEST EXISTS FOR
out="$(run_case 'Unable to connect to the server: dial tcp 192.0.2.1:6443: i/o timeout' 1)"
check  "unreachable => CANNOT READ"          "CANNOT READ"  "$out"
refute "unreachable => NEVER says absent"    "demo: absent" "$out"
check  "unreachable => counted as NOT done"  "LEFT:"        "$out"

# 3. the read was refused — a restricted tenant cannot verify, and must not be told it is clean
out="$(run_case 'Error from server (Forbidden): applications.argoproj.io is forbidden' 1)"
check  "forbidden => CANNOT READ"            "CANNOT READ"  "$out"
refute "forbidden => NEVER says absent"      "demo: absent" "$out"
check  "forbidden => counted as NOT done"    "LEFT:"        "$out"

# 4. the object exists — the helper must not swallow the positive case
out="$(run_case '' 0)"
check  "exists => reported as existing"      "EXISTS"       "$out"

# 5. rc != 0 with EMPTY stderr. There is no legitimate case where this means "gone": `k` sends
#    stdout to /dev/null, so a genuine NotFound ALWAYS lands on stderr. Empty means a Ctrl-C, a
#    kill, or an error we failed to capture. This case FAILED before the helper was rewritten.
out="$(run_case '' 1)"
refute "empty stderr => NEVER says absent"   "demo: absent" "$out"
check  "empty stderr => CANNOT READ"         "CANNOT READ"  "$out"

# 6. a killed process (rc 137), no stderr — the same trap wearing a different exit code.
out="$(run_case '' 137)"
refute "rc=137 => NEVER says absent"         "demo: absent" "$out"

# 7. a BLANK first line with the real diagnosis on line 2. kubectl does this
#    ("Error in configuration:" / "* unable to read client-cert …"), and a head -1 capture then
#    looks exactly like empty stderr. This case FAILED before the capture kept all of stderr.
out="$(run_case '
Unable to connect to the server: dial tcp 192.0.2.1:6443: i/o timeout' 1)"
refute "blank first line => NEVER says absent" "demo: absent" "$out"
check  "blank first line => keeps the real cause" "i/o timeout" "$out"

echo
echo "uninstall-all honesty: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
