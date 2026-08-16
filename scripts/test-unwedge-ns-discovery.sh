#!/usr/bin/env bash
# ============================================================================
# B112, THIRD SITE. `unwedge-supervisor-service.sh`'s namespace discovery must not conclude
# "already gone" from a question the cluster never answered.
#
# The backlog row named two sites (the confirm listing and the delete loop); both were fixed. This
# one is the same swallowed `kubectl … 2>/dev/null` read and its failure is the most REASSURING of
# the three: an empty array lands on `case 0` and EXITS 0 with "the workload is already gone ...
# re-issue the uninstall". A wedged operator whose token just expired is told the wedge cleared.
#
# The test extracts the real gate-2 block from the script (not a retyped copy) and runs it against
# a stub kubectl, both directions. The second direction is the one that matters as much as the RED:
# a WORKING kubectl with no matching namespace must still say "already gone" and exit 0, or the fix
# has simply broken the legitimate path.
# ============================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO_ROOT}/scripts/unwedge-supervisor-service.sh"
pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

{ echo 'set -euo pipefail'
  echo 'log_info(){ printf "INFO %s\n" "$*"; }; log_error(){ printf "ERROR %s\n" "$*" >&2; }'
  echo 'classify_kube_failure(){ grep -qi "i/o timeout|Unable to connect" -E "$1" && printf UNREACHABLE || printf UNKNOWN; }'
  echo 'SERVICE=harbor.tanzu.vmware.com'
  sed -n '/^prefix="svc-/,/^log_info "namespace/p' "$SRC"
} > "$T/gate2.sh"
if [ "$(grep -c . "$T/gate2.sh")" -lt 12 ]; then
  printf '  FAIL  could not extract gate 2 from %s — this test is not testing the product\n' "$SRC"
  exit 1
fi

chk() { # chk <label> <want-rc> <got-rc>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s (rc=%s)\n' "$1" "$3"
  else fail=$((fail+1)); printf '  FAIL  %s: want rc=%s got rc=%s\n' "$1" "$2" "$3"; fi
}

printf '#!/usr/bin/env bash\necho "Unable to connect to the server: dial tcp 10.0.0.9:443: i/o timeout" >&2\nexit 1\n' > "$T/bin/kubectl"
chmod +x "$T/bin/kubectl"
out="$(PATH="$T/bin:$PATH" bash "$T/gate2.sh" 2>&1)"; rc=$?
chk 'a FAILING kubectl must refuse, not report "already gone"' 1 "$rc"
printf '%s' "$out" | grep -q 'cannot LIST namespaces' \
  && { pass=$((pass+1)); printf '  ok    ...and it names the cause rather than the symptom\n'; } \
  || { fail=$((fail+1)); printf '  FAIL  refused, but not with the LIST diagnostic: %s\n' "$out"; }
# Anchor on the CLAIM, not the substring: the refusal itself says "refusing to conclude ... is
# already gone", so a bare `grep 'already gone'` flags the CORRECT message. Second time today I
# wrote a matcher that cannot tell a claim from its denial; the first was the supervisor reporter.
printf '%s' "$out" | grep -q 'the workload is already gone' \
  && { fail=$((fail+1)); printf '  FAIL  it STILL claimed the workload is already gone\n'; }

printf '#!/usr/bin/env bash\nprintf "namespace/default\\nnamespace/kube-system\\n"\n' > "$T/bin/kubectl"
out2="$(PATH="$T/bin:$PATH" bash "$T/gate2.sh" 2>&1)"; rc2=$?
chk 'a WORKING kubectl with no match must still say "already gone"' 0 "$rc2"
printf '%s' "$out2" | grep -q 'already gone' \
  && { pass=$((pass+1)); printf '  ok    ...and the legitimate path is unbroken\n'; } \
  || { fail=$((fail+1)); printf '  FAIL  the no-match path lost its message: %s\n' "$out2"; }

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
