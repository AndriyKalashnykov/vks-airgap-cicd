#!/usr/bin/env bash
# http_get_retry's die must NAME THE STATUS (B181 C2), and _http_fail_hint must map it to the one
# sentence that says whose problem it is.
#
# WHY THIS EXISTS. Every die in http_get_retry named only the URL, the elapsed time and the budget,
# so four materially different faults produced the same message: a filtering proxy (403), a moved
# artifact (404), an upstream outage (502), and a box with no route at all (000). Three of those are
# somebody else's problem and one is the operator's, and nothing told them which. It matters most at
# the two call sites that never call require_internet — 00-install-prereqs.sh and
# 07-install-argocd.sh — where this die is the ONLY signal the operator gets.
#
# HERMETIC BY CONSTRUCTION: no network, no server, no python3. The bare air-gap Photon floor has no
# python3 (recorded in version-discipline), so a test that spun up an HTTP server would be unrunnable
# on a target this project actually supports. The status buckets are exercised against the PURE
# function; the end-to-end arm uses a refused port and file:// URLs, both of which need nothing.
#
# ⚠️ THE CASE THAT GUARDS THE REGRESSION MY OWN FIX COULD HAVE INTRODUCED. MEASURED 2026-08-18,
# curl 8.5.0: a SUCCESSFUL file:// transfer reports http_code=000 with rc=0.
#     file:// SUCCESS -> rc=0   http_code='000'   dest=hello
#     file:// MISSING -> rc=37  http_code='000'
# So success MUST be decided on curl's EXIT STATUS, never on the status code — keying on the code
# would have made every file:// fetch look like a total failure. That is what "file:// success
# returns 0" pins, and it is green on the pre-C2 code by design (it is a no-regression case).
#
# shellcheck disable=SC2016
# ^ DELIBERATE, file-scoped. `ck` takes its condition as a STRING and `eval`s it, so every
# condition below is single-quoted ON PURPOSE — expansion must happen at eval time, inside the
# assertion, not when the argument is built. Double-quoting them would expand $T and $( ) at
# call time and, for the cases that assert on a die, would run the command before ck sees it.
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC1091
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source os.sh"; exit 1; }
pass=0; fail=0
ck(){ if eval "$2"; then printf '  PASS  %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

echo "--- the PURE hint function: each bucket must say WHOSE problem it is ---"
ck "none  -> names the budget, not a status"      '[ -n "$(_http_fail_hint none none)" ] && grep -q "budget" <<< "$(_http_fail_hint none none)"'
ck "000   -> says NO response at all"             'grep -q "NO response at all" <<< "$(_http_fail_hint 000 7)"'
ck "000   -> blames THIS BOX (actionable)"        'grep -q "THIS BOX" <<< "$(_http_fail_hint 000 7)"'
ck "403   -> says the server ANSWERED"            'grep -q "ANSWERED and refused" <<< "$(_http_fail_hint 403 22)"'
ck "403   -> says retrying will not help"         'grep -q "retrying will not help" <<< "$(_http_fail_hint 403 22)"'
ck "404   -> same 4xx bucket as 403"              '[ "$(_http_fail_hint 404 22)" = "$(_http_fail_hint 403 22 | sed s/403/404/)" ]'
ck "502   -> Upstream, usually transient"         'grep -q "Upstream" <<< "$(_http_fail_hint 502 22)"'
ck "301   -> falls through, still names the code" 'grep -q "HTTP 301" <<< "$(_http_fail_hint 301 0)"'
ck "every bucket carries the curl rc"             'grep -q "curl rc 22" <<< "$(_http_fail_hint 404 22)"'

echo "--- the DISCRIMINATOR: 000 and 4xx must not produce the same sentence ---"
ck "000 != 403 (they are different actions)"      '[ "$(_http_fail_hint 000 7)" != "$(_http_fail_hint 403 22)" ]'
ck "4xx != 5xx (theirs vs upstream)"              '[ "$(_http_fail_hint 404 22)" != "$(_http_fail_hint 504 22)" ]'

echo "--- end-to-end through http_get_retry: the die must carry the status ---"
# One attempt, no sleep, unlimited budget (0) -> lands on the final die immediately.
FAST='HTTP_GET_RETRIES=1 HTTP_GET_RETRY_DELAY_SECONDS=0 HTTP_GET_MAX_TIME_SECONDS=5 HTTP_GET_TOTAL_BUDGET_SECONDS=0 HTTP_CONNECT_TIMEOUT_SECONDS=2'
( eval "$FAST" 'http_get_retry http://127.0.0.1:9/x "$T/refused"' ) >"$T/out.log" 2>&1 && rc=0 || rc=$?
ck "a refused connection DIES"                    '[ "'"$rc"'" -ne 0 ]'
ck "...and the die names HTTP 000"                'grep -q "HTTP 000" "$T/out.log"'
ck "...and the die blames THIS BOX"               'grep -q "THIS BOX" "$T/out.log"'
ck "...and the die still names the URL"           'grep -q "127.0.0.1:9/x" "$T/out.log"'
ck "...and the die is not zero bytes"             '[ -s "$T/out.log" ]'

printf 'hello\n' > "$T/src"
( eval "$FAST" 'http_get_retry "file://$T/src" "$T/dst"' ) >"$T/ok.log" 2>&1 && rc=0 || rc=$?
ck "file:// SUCCESS returns 0 despite http_code 000" '[ "'"$rc"'" -eq 0 ]'
ck "file:// SUCCESS actually wrote the body"      'grep -q hello "$T/dst"'

( eval "$FAST" 'http_get_retry "file://$T/absent" "$T/dst2"' ) >"$T/miss.log" 2>&1 && rc=0 || rc=$?
ck "file:// MISSING dies"                         '[ "'"$rc"'" -ne 0 ]'
ck "...naming a status rather than nothing"       'grep -qE "HTTP (000|[0-9]{3})" "$T/miss.log"'

echo "--- the WIRING: a real status must reach the die (HIGH-1 from the implementation round) ---"
# ⚠️ WHY THIS SECTION EXISTS. Every end-to-end case above has a TRUE status of 000 (a refused port,
# two file:// URLs), so the 4xx/5xx buckets were exercised only against the PURE function — which is
# trivially correct. MEASURED by the round: with `-w %{http_code}` DELETED FROM CURL ENTIRELY, and
# again with `last_code` hardcoded to 000, this suite scored 20/20 GREEN. The whole feature could be
# removed and the gate certified it. These cases pin the CAPTURE, using the `curl()` shell-function
# stub idiom the sibling test-require-internet.sh:69 already uses — hermetic, so the header's
# "no python3 on the bare Photon floor" reason for avoiding a server does not apply here either.
for _c in 403 404 502 418; do
  ( eval "$FAST"
    # shellcheck disable=SC2317  # invoked indirectly, by http_get_retry
    # The stub HONOURS -w the way real curl does: no -w, no status on stdout. Without this the
    # stub prints the code regardless of argv, so DELETING `-w '%{http_code}'` from the real
    # invocation is undetectable — measured: that mutation scored 0 RED until this case matched
    # on the flag. The stub must model the thing under test, not just its happy output.
    curl() { case "$*" in *'%{http_code}'*) printf '%s' "$_c" ;; esac; return 22; }
    http_get_retry "http://stub.invalid/x" "$T/stub" ) >"$T/stub.log" 2>&1 || true
  ck "a real HTTP $_c reaches the die (not just the pure function)" \
     'grep -q "HTTP '"$_c"'" "$T/stub.log"'
done
# And the bucket must follow the captured code, not a constant.
( eval "$FAST"
  # shellcheck disable=SC2317
  curl() { case "$*" in *'%{http_code}'*) printf '502' ;; esac; return 22; }
  http_get_retry "http://stub.invalid/x" "$T/stub" ) >"$T/b5.log" 2>&1 || true
ck "...and a 5xx is bucketed as UPSTREAM, not as the operator's box" 'grep -q "Upstream" "$T/b5.log"'
ck "...and is NOT bucketed as THIS BOX"                              '! grep -q "THIS BOX" "$T/b5.log"'

printf '\n  %s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
