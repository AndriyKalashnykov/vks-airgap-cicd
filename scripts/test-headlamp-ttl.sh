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
# MEASURED by the adversary round against the naive version: this payload ran `id`, wrote the file,
# and the script CONTINUED with rc=0, because the payload's own `echo 0` satisfied the digit guard
# that ran afterwards. In the tenant posture .env is supplied by a platform team.
canary=$(mktemp -u /tmp/hl-canary-XXXXXX)
reject "a[\$(touch $canary; echo 0)]h" "command substitution in an array subscript"
if [ -e "$canary" ]; then bad "INJECTION EXECUTED — $canary was created"; rm -f "$canary"
else ok "no command ran (canary absent)"; fi
# shellcheck disable=SC2016  # SINGLE QUOTES ARE THE POINT: the payload must reach the function
# UNEXPANDED, exactly as it would arrive from a .env line. Letting the shell expand it here would
# test a different string than the one an operator can actually supply.
reject 'a[$(echo 1)]s' "second injection shape"

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

echo
printf 'headlamp-ttl: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
