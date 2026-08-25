#!/usr/bin/env bash
# The VKS-package version selection must sort by VERSION, not lexicographically (B476 F7).
#
# `vks-package.sh install` with no PKG_VERSION takes the NEWEST offered version -- so the default
# FLOATS, in a repo built on pinning, and a lexicographic sort floats it to the WRONG release. Both
# selection sites had the bug: `_versions` (feeds `tail -1`, the actual default) and `_list`'s
# LATEST column (what `make list-vks-packages` tells an operator is newest).
#
# It was invisible because today's six istio versions all share a two-digit minor and vmware.1, so
# lexicographic and version order AGREE. That is a property of one moment's package list, not of the
# code -- exactly the "measured at one operating point" trap. These cases pin the operating points
# where they DISAGREE, so a regression cannot hide behind a conveniently-shaped list.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# 1. The shell sort `_versions` uses. Two-digit minor: the case that breaks lexicographic.
got="$(printf '1.27.8+vmware.1-vks.1\n1.28.5+vmware.1-vks.1\n1.9.0+vmware.1-vks.1\n1.100.0+vmware.1-vks.1\n' | sort -V | tail -1)"
if [ "$got" = '1.100.0+vmware.1-vks.1' ]; then ok "sort -V picks 1.100.0 over 1.9.0"
else bad "sort -V minor" "picked '$got'"; fi

# 2. The vendor BUILD suffix, which lexicographic also gets wrong: vmware.10 > vmware.2.
got="$(printf '1.28.5+vmware.1-vks.1\n1.28.5+vmware.2-vks.1\n1.28.5+vmware.10-vks.1\n' | sort -V | tail -1)"
if [ "$got" = '1.28.5+vmware.10-vks.1' ]; then ok "sort -V picks vmware.10 over vmware.2"
else bad "sort -V build" "picked '$got'"; fi

# 3. THE CONTROL. Lexicographic must genuinely disagree, or cases 1-2 prove nothing about the fix --
#    they would pass against the OLD code too, and the suite would be vacuous.
got="$(printf '1.27.8+vmware.1-vks.1\n1.28.5+vmware.1-vks.1\n1.9.0+vmware.1-vks.1\n1.100.0+vmware.1-vks.1\n' | sort | tail -1)"
if [ "$got" = '1.9.0+vmware.1-vks.1' ]; then ok "control: lexicographic really does pick 1.9.0 (the bug is real)"
else bad "control" "lexicographic picked '$got' — these cases may not discriminate"; fi

# 4. `_versions` must not have regressed to jq's lexicographic sort.
if grep -q 'sort -V' "$ROOT/scripts/vks-package.sh"; then ok "_versions uses sort -V"
else bad "_versions" "no 'sort -V' in vks-package.sh"; fi
if grep -qE "spec\.version\]\|sort\|" "$ROOT/scripts/vks-package.sh"; then
  bad "_versions regressed" "jq 'sort' is back on the version list"
else ok "_versions does not jq-sort the version list"; fi

# 5. The LATEST column's jq expression, executed -- not merely grepped for.
if command -v jq >/dev/null 2>&1; then
  got="$(printf '[{"r":"x","v":"1.9.0+vmware.1-vks.1"},{"r":"x","v":"1.100.0+vmware.1-vks.1"}]' \
    | jq -r '[.[]]|group_by(.r)|map({latest:(map(.v)|sort_by(split(".")|map(gsub("[^0-9].*$";"")|tonumber? // 0))|last)})|.[]|.latest' 2>/dev/null)"
  if [ "$got" = '1.100.0+vmware.1-vks.1' ]; then ok "the LATEST jq expression picks 1.100.0"
  else bad "LATEST jq" "picked '$got'"; fi
  # ...and its own control, for the same reason as case 3.
  got="$(printf '[{"r":"x","v":"1.9.0+vmware.1-vks.1"},{"r":"x","v":"1.100.0+vmware.1-vks.1"}]' \
    | jq -r '[.[]]|group_by(.r)|map({latest:(map(.v)|sort|last)})|.[]|.latest' 2>/dev/null)"
  if [ "$got" = '1.9.0+vmware.1-vks.1' ]; then ok "control: the OLD LATEST expression picks 1.9.0"
  else bad "LATEST control" "old expression picked '$got'"; fi
else bad "jq missing" "cannot execute the LATEST expression"; fi

printf '\n  vks-package version sort: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
