#!/usr/bin/env bash
# RED-proof for scripts/lib/headlamp.sh. Offline; no cluster.
#
# EVERY case here has an incident behind it -- two adversary rounds on 2026-09-06 REFUTED the first
# version of this fix, and each finding is pinned below so the naive form cannot come back.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/headlamp.sh
. scripts/lib/headlamp.sh

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

want() {  # want <duration> <expected-seconds>
  local got rc
  got="$(headlamp_ttl_seconds "$1")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$got" = "$2" ]; then ok "'$1' -> $2"
  else bad "'$1' -> expected $2 (rc0), got '$got' (rc=$rc)"; fi
}
reject() {  # reject <duration> <why>
  local got rc
  got="$(headlamp_ttl_seconds "$1")"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$got" ]; then ok "REJECTS '$1' — $2"
  else bad "ACCEPTED '$1' as '$got' (rc=$rc) — $2"; fi
}

echo "== accepted forms =="
want 24h 86400
want 8h 28800
want 1h 3600
want 30m 1800
want 600s 600
want 8760h 31536000          # the chart schema's maximum, exactly
want 1s 1                    # the chart schema's minimum, exactly

echo
echo "== 10# forces base 10 (without it, 010h is OCTAL and silently means 8h) =="
want 010h 36000
want 08h 28800
want 09m 540

echo
echo "== rejected, each a MEASURED failure of the naive version =="
reject ''       "empty: the naive form derived 0 and helm failed with a schema error naming nothing"
reject 1h30m    "compound: kubectl accepts it, this derivation cannot -- refuse rather than mis-derive"
reject 1.5h     "fractional: the naive form died 'invalid arithmetic operator' BEFORE its own guard"
reject 24H      "uppercase unit"
reject 86400    "bare seconds: kubectl create token --duration=86400 fails 'missing unit in duration'"
reject 0h       "below the chart schema minimum of 1"
reject 8761h    "above the chart schema maximum of 31536000"
reject -1h      "negative"
reject abc      "not a duration"
reject 'h'      "unit with no number"

echo
echo "== INJECTION: bash arithmetic EXECUTES commands via an array subscript =="
# ⚠️ THE PAYLOAD IS DIGIT-LEADING AND RUNS UNDER `set +u`, BOTH DELIBERATELY. The first version of
# this case was VACUOUS IN ITS OWN HARNESS and a confirming adversary round measured it: under this
# file's `set -u`, `a[$(...)]` dies as "unbound variable" BEFORE the subscript evaluates, and the
# leading `a` is rejected by the `[0-9]*h` case ANCHOR anyway -- so it exercised NEITHER guard it
# sits beside, and passed identically against the naive version it names. A refactor deleting both
# guards would have passed all 28 cases while being exploitable for any caller not using `set -u`.
# `1+a[...]` reaches the arithmetic; `set +u` removes the accidental protection so the test measures
# THIS FILE'S guards rather than the harness's.
canary=$(mktemp -u /tmp/hl-canary-XXXXXX)
inj_rc=$( set +u; headlamp_ttl_seconds "1+a[\$(touch $canary)]h" >/dev/null 2>&1; echo $? )
if [ "$inj_rc" -ne 0 ]; then ok "REJECTS a digit-leading array-subscript payload (rc=$inj_rc)"
else bad "ACCEPTED the injection payload (rc=$inj_rc)"; fi
if [ -e "$canary" ]; then bad "INJECTION EXECUTED — $canary was created"; rm -f "$canary"
else ok "no command ran (canary absent)"; fi
# shellcheck disable=SC2016  # SINGLE QUOTES ARE THE POINT: the payload must reach the function
# UNEXPANDED, exactly as it would arrive from a .env line.
reject '1+a[$(echo 1)]s' "second injection shape, digit-leading"

echo
echo "== NON-ASCII DIGITS: a bash [0-9] RANGE is COLLATION-based and accepts them in UTF-8 =="
# MEASURED before the fix, same function, same input, only the locale changed:
#   LC_ALL=en_US.UTF-8 -> PASSED both guards -> `10#: invalid integer constant`
#   LC_ALL=C           -> rejected cleanly
# That error is a FATAL SHELL EXPANSION error, so the `|| true` at both call sites cannot absorb it
# and the whole credentials table dies. Locale-dependent, so invisible on a C-locale CI runner.
# These cases only mean anything in a UTF-8 locale; force one so CI cannot pass them vacuously.
# ⚠️ NO SUBSHELL. `( ... )` here would swallow the pass/fail counters -- a global assigned inside a
# subshell is LOST -- so a FAILING unicode case would print FAIL and the suite would still exit 0.
# Caught by the denominator: the count read 29 instead of 33.
_saved_lc="${LC_ALL:-}"
export LC_ALL=en_US.UTF-8
reject '１２h' "fullwidth digits (U+FF11 U+FF12)"
reject '١٢h'  "arabic-indic digits (U+0661 U+0662)"
reject '１h'   "single fullwidth digit"
if [ -n "$_saved_lc" ]; then export LC_ALL="$_saved_lc"; else unset LC_ALL; fi

echo
echo "== OVERFLOW: the range check runs AFTER the multiply, so a 64-bit wrap can land inside it =="
reject 1152921504606847000h "2^60+24 hours wrapped back to a plausible 86400 before the digit-count bound"

echo
echo "== headlamp_deployed_ttl can NEVER fail (creds.sh must not die) =="
# creds.sh's own header: the report "MUST NOT HANG OR DIE ... every failure degrades to a marker".
# A CRITICAL in both rounds: the unguarded read-back killed the WHOLE credentials table.
stub=$(mktemp -d); trap 'rm -rf "$stub"' EXIT
mk_kubectl() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$stub/kubectl"; chmod +x "$stub/kubectl"; }
# Emit "<value>|<rc>" on ONE line. An earlier version echoed the rc on its own line and then
# pattern-matched the two-line blob, which false-FAILED the `=` case -- the harness was wrong, not
# the lib. Distrust the instrument before the product.
run_deployed_ttl() { PATH="$stub:$PATH" bash -c '. scripts/lib/headlamp.sh; v="$(headlamp_deployed_ttl hl)"; printf "%s|%s" "$v" "$?"'; }

mk_kubectl 'echo "Error from server (NotFound)" >&2; exit 1'
out="$(run_deployed_ttl)"
case "$out" in "|0") ok "NotFound -> rc=0, empty" ;; *) bad "NotFound -> $out" ;; esac

mk_kubectl 'echo "Error from server (Forbidden)" >&2; exit 1'
out="$(run_deployed_ttl)"
case "$out" in "|0") ok "Forbidden (tenant posture) -> rc=0, empty" ;; *) bad "Forbidden -> $out" ;; esac

mk_kubectl 'exit 124'
out="$(run_deployed_ttl)"
case "$out" in "|0") ok "timeout kill (124) -> rc=0, empty" ;; *) bad "timeout -> $out" ;; esac

mk_kubectl 'echo "[\"-in-cluster\",\"-session-ttl=28800\",\"-plugins-dir=/x\"]"'
out="$(run_deployed_ttl)"
case "$out" in "28800|0") ok "reads the = form -> 28800" ;; *) bad "= form -> $out" ;; esac

mk_kubectl 'echo "[\"-in-cluster\",\"-session-ttl 28800\"]"'
out="$(run_deployed_ttl)"
case "$out" in "28800|0") ok "reads the SPACE form too (rot surface on a chart bump)" ;; *) bad "space form -> $out" ;; esac

# The k8s-CANONICAL rendering: flag and value as SEPARATE argv elements. This returned EMPTY before
# `paste -sd' '` was added, which silently disabled BOTH consumers together -- the installer's
# assert stops asserting and creds.sh skips the comparison, neither saying a word.
mk_kubectl 'echo "[\"-in-cluster\",\"-session-ttl\",\"28800\"]"'
out="$(run_deployed_ttl)"
case "$out" in "28800|0") ok "reads the TWO-ELEMENT form (flag and value as separate argv entries)" ;; *) bad "two-element form -> $out" ;; esac

echo
printf 'headlamp-ttl: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
