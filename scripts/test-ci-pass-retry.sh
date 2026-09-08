#!/usr/bin/env bash
# The ci-pass step's RETRY logic, extracted from ci.yml and run under GitHub's own shell posture.
#
# B564. The jobs API LAGS the `needs` context, so a single read can refuse a fully green run --
# MEASURED 4 times on 2026-09-08 (5.2-7.3s stale, always the job that finished LAST). Stage 1 is:
# read, verdict, and if it REFUSED, sleep and re-read, using the second verdict.
#
# ⚠️ WHY THIS FILE EXISTS AT ALL. scripts/test-ci-pass-verdict.sh (23 cases) tests
# ci-pass-verdict.sh, a pure TSV -> rc function -- and this change is to the FETCH, not the verdict.
# An idea round measured that the existing suite goes GREEN over any retry bug, and that its case
# "a DECLARED job still running fails CLOSED" keeps passing either way. Inline workflow YAML was the
# one place this repo had no harness, so a defect here had nothing to catch it.
#
# ⚠️ IT RUNS THE REAL BLOCK, extracted from ci.yml, NOT a hand-copied replica. A replica would keep
# asserting the old shape after someone edited the workflow -- the failure mode this repo calls
# enumerated-list rot. The only substitutions are the `${{ }}` expressions, which are GitHub's, not
# shell.
#
# ⚠️ AND IT RUNS UNDER `bash -e`, deliberately. GitHub invokes a run: block as `/usr/bin/bash -e {0}`
# and the block's own `set -uo pipefail` does NOT clear that `-e`. Every trap in this area comes from
# that: a bare `rc=$?` after a failing command never executes, and `n=$(grep -c …)` with zero matches
# exits 1 and kills the step ON THE HAPPY PATH.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

WF='.github/workflows/ci.yml'
# Extract the run: block of the "Verify required jobs" step -- the body indented under `run: |`.
BLOCK="$(awk '
  /^        run: \|$/ { if (seen) { f=1; next } }
  /Verify required jobs/ { seen=1 }
  f && /^          / { sub(/^          /, ""); print; next }
  f && /^[[:space:]]*$/ { print ""; next }
  f { exit }
' "$WF")"

if [ -z "$BLOCK" ]; then
  echo "  FAIL  could not extract the ci-pass run: block from $WF — the extractor is broken, not the workflow"
  echo "test-ci-pass-retry.sh: 0 passed, 1 failed"; exit 1
fi
# Sanity: the extraction must contain the things this test is about, or it is measuring a fragment.
for _needle in 'fetch_jobs' 'ci-pass-verdict.sh' 'sleep 15'; do
  case "$BLOCK" in
    *"$_needle"*) ;;
    *) echo "  FAIL  the extracted block does not contain '$_needle' — extraction is partial"; fail=$((fail+1)) ;;
  esac
done

# ── the harness ──────────────────────────────────────────────────────────────────────────────────
# $1 = verdict rc sequence, space-separated (one per read). $2 = fetch rc sequence.
run_block() {
  local verdicts="$1" fetches="$2" d
  d="$(mktemp -d)"
  # A stub `sleep` keeps the test fast AND records that the retry path was taken.
  printf '#!/usr/bin/env bash\necho "SLEPT $*" >> "%s/trace"\n' "$d" > "$d/sleep"
  # Stub gh: pops the next fetch rc; writes a plausible TSV on success.
  # shellcheck disable=SC2016  # single quotes REQUIRED: these are the STUB's own $vars, which must
  # reach the generated file literally rather than expanding in this harness.
  printf '#!/usr/bin/env bash\nn=$(cat "%s/fetchn" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "%s/fetchn"\nrc=$(echo "%s" | cut -d" " -f"$n"); [ -n "$rc" ] || rc=0\necho "FETCH $n rc=$rc" >> "%s/trace"\n[ "$rc" = 0 ] || exit "$rc"\nprintf "changes\\tsuccess\\t3\\n" > /tmp/ci-jobs.tsv\n' "$d" "$d" "$fetches" "$d" > "$d/gh"
  mkdir -p "$d/scripts"
  # shellcheck disable=SC2016  # ditto — the stub's own $vars
  printf '#!/usr/bin/env bash\nn=$(cat "%s/vn" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "%s/vn"\nrc=$(echo "%s" | cut -d" " -f"$n"); [ -n "$rc" ] || rc=0\necho "VERDICT $n rc=$rc" >> "%s/trace"\nexit "$rc"\n' "$d" "$d" "$verdicts" "$d" > "$d/scripts/ci-pass-verdict.sh"
  chmod +x "$d/sleep" "$d/gh" "$d/scripts/ci-pass-verdict.sh"
  # Substitute GitHub's ${{ }} expressions -- they are not shell, and the block cannot run with them.
  printf '%s\n' "$BLOCK" | sed -e 's/\${{ github.repository }}/o\/r/g' -e 's/\${{ github.run_id }}/1/g' > "$d/step.sh"
  ( cd "$d" && PATH="$d:$PATH" bash -e step.sh > "$d/out" 2>&1 )
  _RC=$?
  _TRACE="$(cat "$d/trace" 2>/dev/null | tr '\n' ';')"
  _OUT="$(cat "$d/out" 2>/dev/null)"
  rm -rf "$d"
}

# ── cases ────────────────────────────────────────────────────────────────────────────────────────
run_block "0" "0"
if [ "$_RC" = 0 ] && [ "${_TRACE#*SLEPT}" = "$_TRACE" ]; then
  ok "first read PASSES -> exit 0, and the retry path is NOT taken (no sleep on the happy path)"
else
  bad "happy path: rc=$_RC trace=[$_TRACE] — wanted rc=0 with no SLEPT"
fi

# THE FIX ITSELF: a lag-refused first read, a good second one.
run_block "1 0" "0 0"
if [ "$_RC" = 0 ] && [ "${_TRACE#*SLEPT}" != "$_TRACE" ]; then
  ok "first read REFUSES, second PASSES -> exit 0 (the lag case this change exists for)"
else
  bad "retry-rescues: rc=$_RC trace=[$_TRACE] — wanted rc=0 with a SLEPT"
fi

# FAIL-CLOSED MUST SURVIVE. This is the founding incident's property: a genuinely failed gate job
# refuses on both reads, and the retry must not convert that into a pass.
run_block "1 1" "0 0"
if [ "$_RC" != 0 ]; then
  ok "both reads REFUSE -> still refuses (a retry must never rescue a REAL failure)"
else
  bad "FAIL-OPEN: rc=$_RC trace=[$_TRACE] — a real failure was rescued by the retry"
fi

# An API outage on BOTH reads must refuse, naming the cause rather than dying bare.
run_block "0 0" "1 1"
if [ "$_RC" != 0 ] && [ "${_OUT#*produced nothing}" != "$_OUT" ]; then
  ok "the jobs API failing on both reads refuses AND names the cause"
else
  bad "api-outage: rc=$_RC out=[${_OUT}] — wanted non-zero naming 'produced nothing'"
fi

# An outage on the FIRST read only must still reach the second and honour it.
run_block "0" "1 0"
if [ "$_RC" = 0 ]; then
  ok "an outage on the FIRST read alone still reaches the second read and honours it"
else
  bad "first-read outage: rc=$_RC trace=[$_TRACE] — wanted rc=0"
fi

printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
