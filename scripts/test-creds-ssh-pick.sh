#!/usr/bin/env bash
# ci-tier: fast
# test-creds-ssh-pick.sh — offline cases for creds.sh's _ssh_pick.
#
# WHY THIS FILE EXISTS (B530). scripts/test-creds-show.sh sets CREDS_NO_PROBE=1 for every rendered
# case, and creds.sh short-circuits the whole SSH block on that flag — so that gate could not
# execute ONE line of the selection logic. Its green was evidence about a subset that EXCLUDED the
# change, and adding the selection code did not move its denominator by a single case, which is the
# exact signal gates.md names as "blind to it".
#
# _ssh_pick is PURE (no kubectl, no globals, no side effects), so every branch is testable here with
# no cluster at all. It is EXTRACTED from creds.sh by name — never copy-pasted — so a change to the
# real function is what these cases measure. If the extraction ever yields nothing, that is a hard
# failure, not a skip: a test that silently tests an empty function is worse than no test.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Extract by function name up to its closing brace at column 0 — deliberately NOT a line range,
# which rots on the first edit above it (the pattern scripts/test-mirror-verify-class.sh uses).
_fn="$(awk '/^_ssh_pick\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "${REPO_ROOT}/scripts/creds.sh")"
case "$_fn" in
  *"_ssh_pick() {"*) : ;;
  *) echo "FATAL: could not extract _ssh_pick from scripts/creds.sh — the function was renamed or"
     echo "       reshaped. Fix the extraction; do NOT let this test pass over an empty function."
     exit 1 ;;
esac
eval "$_fn"

pass=0; fail=0
ok()  { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
want() {  # <label> <expected> <candidates> <cluster>
  local got; got="$(_ssh_pick "$3" "$4")"
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 — wanted [$2], got [$got]"; fi
}

TWO=$'cicd-gc1-ssh-password\ncicd-gc2-ssh-password'

want "exact match wins over a sibling"                 "cicd-gc2-ssh-password" "$TWO" "cicd-gc2"
want "exact match wins when it sorts LAST"             "cicd-gc2-ssh-password" "$TWO" "cicd-gc2"
want "exact match wins when it sorts FIRST"            "cicd-gc1-ssh-password" "$TWO" "cicd-gc1"

# THE CASE THIS WHOLE CHANGE EXISTS FOR. Before the fix, `head -1` returned the alphabetically
# first candidate — a DELETED cluster's password presented as live. It must now REFUSE.
want "2 candidates, NO match -> REFUSE (never guess)"  ""                      "$TWO" "cicd-gc9"

# The sole-candidate fallback: the recorded lab where .env said cicd-gc1 while the live secret was
# cicd-gc0819222721-ssh-password. Constructing the name from VKS_CLUSTER_NAME would break it, which
# is why the list is DISCOVERED and this arm exists.
want "sole candidate is used even when it does NOT match" \
     "cicd-gc0819222721-ssh-password" "cicd-gc0819222721-ssh-password" "cicd-gc1"
want "sole candidate is used when the cluster name is EMPTY" \
     "cicd-gc0819222721-ssh-password" "cicd-gc0819222721-ssh-password" ""
want "no candidates -> empty"                          ""                      ""     "cicd-gc2"
want "2 candidates and an EMPTY cluster name -> REFUSE" ""                     "$TWO" ""

# A name carrying a regex metacharacter must not ALTERNATE into a sibling entry. grep -Fx (fixed
# string, whole line) is what prevents it; a bare grep would match here (rules/shell).
want "a regex metachar in the name cannot alternate"   ""  "$TWO" 'cicd-gc1|cicd-gc2'
# ...and a PREFIX must not match a longer sibling (whole-line, not substring).
# ⚠️ THIS NEEDS >=2 CANDIDATES. My first version passed ONE (`cicd-gc22-ssh-password`) and expected
# a refusal — but with one candidate the SOLE-CANDIDATE arm fires by design and returns it, so the
# case failed on a wrong EXPECTATION, not a bug. A prefix test must isolate the matching from the
# fallback, or it measures the wrong arm.
want "a prefix does not match a longer sibling"        "" \
     "$(printf 'cicd-gc22-ssh-password\ncicd-gc1-ssh-password')" "cicd-gc2"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
