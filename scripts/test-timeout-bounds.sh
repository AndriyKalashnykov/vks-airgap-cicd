#!/usr/bin/env bash
# ci-tier: fast — OFFLINE, no listener, nothing dialled. Two cases wait out a 1 s bound.
#
# test-timeout-bounds.sh — every `timeout` under scripts/ takes its bound through ONE clamp
# (lib/os.sh: duration_seconds, bound_seconds) and ONE pair of runners (run_bounded,
# run_bounded_group), and a value that cannot be used is reported ONCE, where it can be seen.
#
# THE DEFECTS, in the order they were found.
#   * `timeout 0 <cmd>` is NO time limit. Twenty-odd sites handed an operator-settable variable
#     straight to `timeout`, so a 0 in .env switched the bound off.
#   * The first clamp swapped in a default silently. MEASURED: CA_VERIFY_TIMEOUT=2s, which
#     `timeout` itself accepts, became 15 s with no word.
#   * The second version warned from INSIDE the runner. Nearly every real call site redirects
#     stderr, so the warning was never seen (`2>/dev/null`) while "once" was spent on it, or it
#     landed in the capture file (`2>"$file"`) and was read back as the command's own error. It
#     also kept its "once" in a marker file under TMPDIR, whose write followed a planted symlink.
#
# WHAT IS PINNED:
#   1. duration_seconds: what timeout accepts for a positive duration, as plain seconds — no
#      exponent, no leading zeros, at least 1, at most one day
#   2. bound_seconds and both runners print NOTHING, whatever they are given
#   3. bounds_normalize, in the main shell: unset stays unset, usable becomes seconds, unusable
#      becomes the default with ONE line on stderr; once across calls and across child scripts
#   4. THE PRODUCTION SHAPE: a runner with stderr redirected, then one with it open — exactly one
#      warning, on the script's stderr, none in the capture file — through the real load_env,
#      for every variable that is handed to a runner at a site that captures stderr
#   5. run_bounded passes `--foreground` when this timeout has it; run_bounded_group never does
#   6. THE GATE: no line under scripts/ (tests aside) hands a variable to `timeout` outside the
#      three runner lines; every variable named at a runner is one bounds_normalize knows; and no
#      marker-file path is left in the tree. Derived by grep, with a planted control and floors.
#
# DOES NOT PROVE: that a bound is the right LENGTH for any command; that `--foreground` is safe
# for a command nobody has listed as child-free (the rule is in the runners' header in lib/os.sh);
# or anything under a decimal-comma locale (no such locale is installed here: the `LC_ALL=C` on
# the awk call is pinned as text only).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$REPO_ROOT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
command -v timeout >/dev/null 2>&1 || { echo "test-timeout-bounds: INCONCLUSIVE — timeout is not installed (nothing was asserted)"; exit 1; }
REAL_TIMEOUT="$(command -v timeout)"
# A sandbox .env is this file's fixture in section 4; a caller's SKIP_DOTENV would hide it.
unset SKIP_DOTENV _VKS_BOUNDS_REPORTED

LIB_OS="${REPO}/scripts/lib/os.sh"
LIB_TLS="${REPO}/scripts/lib/tls.sh"
# shellcheck source=scripts/lib/os.sh
. "$LIB_OS"
# shellcheck source=scripts/lib/tls.sh
. "$LIB_TLS"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"
has() { command grep -qF -- "$2" <<< "$1"; }

# ══ 1. duration_seconds ══════════════════════════════════════════════════════════════════════
while IFS='|' read -r in want; do
  [ -n "$want" ] || continue
  if got="$(duration_seconds "$in")"; then :; else got=REFUSED; fi
  if [ "$got" = "$want" ]; then ok "duration_seconds: '${in}' -> ${want}"
  else bad "duration_seconds: '${in}'" "wanted '${want}', got '${got}'"; fi
done <<'ROWS'
2|2
2.5|2.5
2.50|2.5
1.25|1.25
2.|2
30s|30
2m|120
1.5m|90
1h|3600
1d|86400
86400|86400
007|7
0010s|10
.5|1
0.0001|1
0.5s|1
86401|REFUSED
2d|REFUSED
99999999999d|REFUSED
99999999999999999999|REFUSED
0|REFUSED
0.0|REFUSED
0s|REFUSED
-1|REFUSED
abc|REFUSED
2x|REFUSED
1e3|REFUSED
2 |REFUSED
 2|REFUSED
2s3|REFUSED
|REFUSED
ROWS
# Whatever is accepted is digits with at most a fraction: never an exponent, a sign or a blank.
shape_bad=""
for v in 2 2.5 .5 0.0001 007 30s 1.5m 1h 1d 86400 12345 3.14159s 0.25m; do
  o="$(duration_seconds "$v" || true)"
  [[ "$o" =~ ^[1-9][0-9]*(\.[0-9]{1,3})?$ ]] || shape_bad="${shape_bad} [${v}->${o}]"
done
if [ -z "$shape_bad" ]; then ok "duration_seconds: every accepted value comes out as plain digits with at most three decimals (no exponent, no leading zero)"
else bad "duration_seconds: an accepted value is not plain seconds" "$shape_bad"; fi
if command grep -qE 'LC_ALL=C awk' "$LIB_OS"; then ok "duration_seconds: its awk runs under LC_ALL=C (a decimal-comma locale must not print 2,5)"
else bad "duration_seconds: the awk call no longer forces LC_ALL=C"; fi

# ══ 2. the clamp and the runners are SILENT ══════════════════════════════════════════════════
# fresh <script> : a new bash with both libs; stdout is printed, stderr goes to $T/err.
fresh() {
  # The child expands its own "$1"/"$2" (SC2016 is deliberate, here and for every `fresh` below).
  # shellcheck disable=SC2016
  bash -c '. "$1"; . "$2"; shift 2; eval "$1"' _ "$LIB_OS" "$LIB_TLS" "$@" 2> "$T/err"
}
# shellcheck disable=SC2016
got="$(fresh 'bound_seconds "" 7; printf "|"; bound_seconds 3 7; printf "|"; bound_seconds 2m 7; printf "|"; bound_seconds 0 7; printf "|"; bound_seconds abc 7')"
if [ "$got" = '7|3|120|7|7' ] && [ ! -s "$T/err" ]; then ok "bound_seconds: a usable value as seconds, anything else the default, and NOTHING on stderr either way"
else bad "bound_seconds: wrong value, or it printed something" "printed '${got}', stderr: $(head -1 "$T/err" | cut -c1-120)"; fi
# shellcheck disable=SC2016
got="$(CA_VERIFY_TIMEOUT='"3"' fresh 'tls_timeout_bound; printf "|"; tls_timeout_bound 1m; printf "|"; CA_VERIFY_TIMEOUT=2s tls_timeout_bound 0')"
if [ "$got" = '15|60|2' ] && [ ! -s "$T/err" ]; then ok "tls_timeout_bound: an unusable CA_VERIFY_TIMEOUT is 15, an argument of 1m is 60, CA_VERIFY_TIMEOUT=2s is 2; silent"
else bad "tls_timeout_bound: wrong value, or it printed something" "printed '${got}', stderr: $(head -1 "$T/err" | cut -c1-120)"; fi

# ══ 3. bounds_normalize: the ONE place that speaks ═══════════════════════════════════════════
# shellcheck disable=SC2016
got="$(fresh 'A_T=2m; B_T=0; unset C_T; D_T=007; bounds_normalize A_T 9 B_T 4 C_T 3 D_T 5; printf "%s|%s|%s|%s" "$A_T" "$B_T" "${C_T-UNSET}" "$D_T"')"
if [ "$got" = '120|4|UNSET|7' ]; then ok "bounds_normalize: usable -> seconds (2m -> 120, 007 -> 7), unusable -> its default, unset stays unset"
else bad "bounds_normalize: the variables are not rewritten as stated" "got '${got}'"; fi
warn="$(cat "$T/err")"
if [ "$(command grep -c . "$T/err")" = 1 ] && has "$warn" "B_T='0' is not a usable time limit, so 4 s is used instead." \
   && has "$warn" 'from 1 to 86400 (one day)' && has "$warn" 'Less than a second counts as 1.' && has "$warn" 'level=WARN'; then
  ok "bounds_normalize: ONE line, for the one unusable variable: its name, its value, the bound used, and the range a value must be in"
else bad "bounds_normalize: the report is missing, repeated, or does not say the range" "$(command grep -c . "$T/err") line(s): $(head -1 "$T/err" | cut -c1-200)"; fi
# shellcheck disable=SC2016
got="$(fresh 'B_T=0; bounds_normalize B_T 4; B_T=0; bounds_normalize B_T 4; B_T=abc; bounds_normalize B_T 4; printf "%s" "$B_T"')"
if [ "$got" = 4 ] && [ "$(command grep -c 'B_T=' "$T/err")" = 1 ]; then ok "bounds_normalize: called three times for the same variable, it reports once and normalises every time"
else bad "bounds_normalize: not once per variable" "$(command grep -c 'B_T=' "$T/err") line(s)"; fi
# A script this one starts re-reads the raw value. It must normalise it again and say nothing:
# its stderr is often a capture file the parent reads back.
# The child and the parent expand their own variables (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '. "$1"\nbounds_normalize B_T 4\nprintf "%%s" "$B_T"\n' > "$T/child.sh"
# shellcheck disable=SC2016
got="$(LIB="$LIB_OS" CHILD="$T/child.sh" CERR="$T/child.err" fresh 'export B_T=0; bounds_normalize B_T 4; export B_T=0; bash "$CHILD" "$LIB" 2>"$CERR"')"
if [ "$got" = 4 ] && [ "$(command grep -c 'B_T=' "$T/err")" = 1 ] && [ ! -s "$T/child.err" ]; then
  ok "bounds_normalize: a child script normalises the same raw value again and prints nothing (the parent already said it)"
else bad "bounds_normalize: the child repeated the warning, or did not normalise" "child printed '${got}', child stderr: $(head -1 "$T/child.err" 2>/dev/null | cut -c1-100)"; fi
# With no arguments it takes the registry: every operator-settable limit, each to its own default.
# shellcheck disable=SC2016
got="$(CA_VERIFY_TIMEOUT=0 CREDS_PROBE_TIMEOUT_SECONDS=1m CREDS_K8S_TIMEOUT=never fresh 'bounds_normalize; printf "%s|%s|%s|%s" "$CA_VERIFY_TIMEOUT" "$CREDS_PROBE_TIMEOUT_SECONDS" "$CREDS_K8S_TIMEOUT" "${CREDS_KUBE_TIMEOUT_SECONDS-UNSET}"')"
if [ "$got" = '15|60|10|UNSET' ] && [ "$(command grep -c 'is not a usable time limit' "$T/err")" = 2 ]; then
  ok "bounds_normalize: with no arguments it checks the registry (CA_VERIFY_TIMEOUT=0 -> 15, CREDS_K8S_TIMEOUT=never -> 10, each reported; 1m -> 60 quietly)"
else bad "bounds_normalize: the registry form" "got '${got}', $(command grep -c 'usable time limit' "$T/err") line(s)"; fi

# ══ 4. THE PRODUCTION SHAPE ══════════════════════════════════════════════════════════════════
# What a real script does: load_env, then a bounded command whose stderr is thrown away or kept
# in a file to be classified, then another with stderr open. The report must be on the SCRIPT's
# stderr, once, and the capture must hold the command's own words and nothing else.
LE="$T/le"; mkdir -p "$LE"
cp "${REPO}/.env.example" "$LE/.env.example"
# The variables that reach a runner at a site which CAPTURES stderr, derived from the scripts:
# continuation lines joined, then every runner call that carries `2>"…"` or `2>>"…"`.
# The awk program's own `$0` is written literally (SC2016 is deliberate).
# shellcheck disable=SC2016
cap_vars="$(find "${REPO}/scripts" -name '*.sh' ! -name 'test-*.sh' -print0 | xargs -0 awk '
              { line = line $0 }
              /\\$/ { sub(/\\$/, " ", line); next }
              { print line; line = "" }' \
            | command grep -E 'run_bounded(_group)?[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]' | command grep -E '2>>?"' \
            | sed -E 's/.*run_bounded(_group)?[[:space:]]+([A-Z][A-Z0-9_]*)[[:space:]].*/\2/' | sort -u)"
n_cap="$(command grep -c . <<< "$cap_vars" || true)"
if [ "${n_cap:-0}" -ge 2 ] && has "$cap_vars" CREDS_K8S_TIMEOUT && has "$cap_vars" ARGOCD_REFRESH_TIMEOUT_SECONDS; then
  ok "production shape: found the capture-file sites by grep (${n_cap} variables: $(tr '\n' ' ' <<< "$cap_vars"))"
else bad "production shape: the scan for capture-file sites found too little" "found: $(tr '\n' ' ' <<< "$cap_vars")"; fi
while IFS= read -r var; do
  [ -n "$var" ] || continue
  printf '%s=0\n' "$var" > "$LE/.env"
  # shellcheck disable=SC2016
  out="$(env -u "$var" -u KUBECONFIG -u VKS_STATE_FILE REPO_ROOT="$LE" VKS_STATE_FILE="$LE/.env.state" CAP="$T/cap" VAR="$var" \
           bash -c '. "$1"; load_env
                    run_bounded_group "$VAR" 33 sh -c "echo the-command-said-this >&2; exit 3" 2>"$CAP"; a=$?
                    run_bounded_group "$VAR" 33 sh -c "exit 0" 2>/dev/null; b=$?
                    run_bounded "$VAR" 33 sh -c "exit 0"; c=$?
                    printf "rc=%s,%s,%s value=%s" "$a" "$b" "$c" "${!VAR}"' _ "$LIB_OS" 2>"$T/script.err")"
  n_warn="$(command grep -c "${var}='0' is not a usable time limit" "$T/script.err" || true)"
  if [ "$n_warn" = 1 ] && [ "$(cat "$T/cap")" = 'the-command-said-this' ] && has "$out" 'rc=3,0,0' && ! has "$out" 'value=0'; then
    ok "production shape, ${var}=0 in .env: one warning on the script's stderr, the capture file holds only the command's own stderr (${out})"
  else
    bad "production shape, ${var}=0: the warning is missing, repeated, or inside the capture file" "warnings on stderr: ${n_warn}; capture: '$(head -2 "$T/cap" | cut -c1-120)'; ${out}"
  fi
done <<< "$cap_vars"
# A script that never normalised (no load_env, and it forgot): the runner still never passes 0
# on, and still writes nothing into the capture.
# shellcheck disable=SC2016
got="$(MY_TIMEOUT=0 CAP="$T/cap" fresh 'run_bounded_group MY_TIMEOUT 9 sh -c "echo only-this >&2" 2>"$CAP"; run_bounded MY_TIMEOUT 9 true; echo "rc=$?"')"
if [ "$got" = 'rc=0' ] && [ "$(cat "$T/cap")" = 'only-this' ] && [ ! -s "$T/err" ]; then
  ok "runners: given a raw 0 they use the default and write nothing, to the capture or to stderr"
else bad "runners: something was written by the runner itself" "capture: '$(head -2 "$T/cap")'; stderr: '$(head -1 "$T/err" | cut -c1-100)'"; fi

# ══ 5. the two runners ═══════════════════════════════════════════════════════════════════════
mkdir -p "$T/rec"
# The stub's own "$*"/"$1" are written literally into the generated script (SC2016 is deliberate).
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ "$1" = "--foreground" ] && shift\nexec %s "$@"\n' "$T/rec.log" "$REAL_TIMEOUT" > "$T/rec/timeout"
chmod +x "$T/rec/timeout"
rec() {  # <script> ; runs it in a fresh shell with the recording timeout; prints its stdout
  : > "$T/rec.log"
  # shellcheck disable=SC2016
  PATH="$T/rec:$PATH" bash -c '. "$1"; . "$2"; eval "$3"' _ "$LIB_OS" "$LIB_TLS" "$1" 2> "$T/err"
}
# shellcheck disable=SC2016
got="$(MY_TIMEOUT=4 rec 'run_bounded MY_TIMEOUT 9 sh -c "exit 7"; echo "rc=$?"')"
if [ "$got" = 'rc=7' ] && [ "$(tail -1 "$T/rec.log")" = '--foreground 4 sh -c exit 7' ]; then
  ok "run_bounded: reads the named variable, passes --foreground, returns the command's own status"
else bad "run_bounded: the variable, the flag or the status is wrong" "said '${got}'; timeout got '$(tail -1 "$T/rec.log")'"; fi
# shellcheck disable=SC2016
got="$(MY_TIMEOUT=0 rec 'run_bounded MY_TIMEOUT 9 true; echo "rc=$?"')"
if [ "$got" = 'rc=0' ] && [ "$(tail -1 "$T/rec.log")" = '--foreground 9 true' ]; then
  ok "run_bounded: a 0 never reaches timeout: the default does"
else bad "run_bounded: a 0 reached timeout" "timeout got '$(tail -1 "$T/rec.log")'"; fi
# shellcheck disable=SC2016
got="$(MY_TIMEOUT=4 rec 'run_bounded_group MY_TIMEOUT 9 sh -c "exit 5"; echo "rc=$?"')"
if [ "$got" = 'rc=5' ] && [ "$(tail -1 "$T/rec.log")" = '4 sh -c exit 5' ] && ! command grep -q -- '--foreground' "$T/rec.log"; then
  ok "run_bounded_group: the same clamp, and NEVER --foreground (the command's children die at the bound)"
else bad "run_bounded_group: it passed --foreground, or lost the bound or the status" "said '${got}'; timeout got '$(tr '\n' ';' < "$T/rec.log")'"; fi
# shellcheck disable=SC2016
got="$(rec 'run_bounded_group "=30s" 9 true; run_bounded_group "=0" 9 true; run_bounded_group "=" 9 true; run_bounded "=2m" 9 true')"
if [ "$(tr '\n' ';' < "$T/rec.log")" = '30 true;9 true;9 true;--foreground 5 true;--foreground 120 true;' ] && [ ! -s "$T/err" ]; then
  ok "runners: the '=value' form clamps a value the caller already holds (30s -> 30, 0 -> default, empty -> default)"
else bad "runners: the '=value' form" "timeout got '$(tr '\n' ';' < "$T/rec.log")'"; fi
r=0; run_bounded "=1" 9 sleep 20 || r=$?
if [ "$r" = 124 ]; then ok "run_bounded: a command that outlives its bound returns 124"
else bad "run_bounded: the bound did not end the command" "rc=${r}"; fi
r=0; run_bounded_group "=1" 9 sleep 20 || r=$?
if [ "$r" = 124 ]; then ok "run_bounded_group: a command that outlives its bound returns 124"
else bad "run_bounded_group: the bound did not end the command" "rc=${r}"; fi

# ══ 6. THE GATE ══════════════════════════════════════════════════════════════════════════════
# What is looked for: the COMMAND `timeout`, any of its own flags (and the argument a flag takes:
# `-s KILL`, `-k 2`), then a duration that holds a `$`: "$X", "${X:-3}", $X, ${X}s, $((X)).
# A literal number is fine: it cannot be 0 by accident.
# NOT the command: `--timeout`, `_sup_timeout`, and the word inside a sentence, `(timeout ${X}s)`,
# which is told apart by the bracket before it: `$(timeout` and `=(timeout` are code, ` (timeout`
# is prose. Left out: comment lines, test files, and the runner lines, which carry a marker.
MARK='# bounded-runner'
# The awk program's own `$0` is written literally (SC2016 is deliberate).
# shellcheck disable=SC2016
scan() {  # <dir> ; prints file:line:text for every offending line
  find "$1" -name '*.sh' ! -name 'test-*.sh' -print0 | xargs -0 awk -v mark="$MARK" '
    function check(rest,    n, tok, i, flag) {
      n = split(rest, tok, /[[:space:]]+/); i = 1
      while (i <= n && tok[i] ~ /^-/) {
        flag = tok[i]; i++
        if (flag ~ /^(-s|--signal|-k|--kill-after)$/) i++      # the flag takes an argument
      }
      return (i <= n && tok[i] ~ /\$/)
    }
    FNR == 1 { lineno = 0 }
    { lineno++ }
    /^[[:space:]]*#/ { next }
    index($0, mark) { next }
    {
      s = $0
      while (match(s, /(^|[^-A-Za-z0-9_.])timeout[[:space:]]+/)) {
        pre = substr(s, 1, RSTART + RLENGTH - 1); rest = substr(s, RSTART + RLENGTH)
        sub(/timeout[[:space:]]+$/, "", pre)
        prose = (pre ~ /(^|[^$=])\($/)
        if (!prose && check(rest)) { printf "%s:%d:%s\n", FILENAME, lineno, $0; break }
        s = rest
      }
    }'
}
hits="$(scan "${REPO}/scripts")"
n_files="$(find "${REPO}/scripts" -name '*.sh' ! -name 'test-*.sh' | wc -l | tr -d ' ')"
n_word="$(command grep -rlE --include='*.sh' -- '(^|[^-A-Za-z0-9_.])timeout[[:space:]]' "${REPO}/scripts" | command grep -cvE '/test-[^/]*\.sh$' || true)"
if [ -z "$hits" ]; then ok "gate: no script hands a variable to timeout outside the runners"
else bad "gate: a variable reaches timeout unclamped (a 0 there is no limit)" "$(printf '%s' "$hits" | sed "s#${REPO}/##" | cut -c1-160 | head -8)"; fi
# THE EXEMPTION IS COUNTED WHERE IT APPLIES: across all of scripts/, not in one file. Exactly the
# three runner lines may carry the marker, and all three are in lib/os.sh.
marked="$(command grep -rnF --include='*.sh' -- "$MARK" "${REPO}/scripts" | command grep -vE '/test-[^/]*\.sh:' || true)"
n_mark="$(command grep -c . <<< "$marked" || true)"
n_mark_os="$(command grep -cF -- "$MARK" "$LIB_OS" || true)"
# The pattern is the runner line as written in lib/os.sh (SC2016 is deliberate).
# shellcheck disable=SC2016
n_mark_cmd="$(command grep -cE ':[[:space:]]+timeout( --foreground)? "\$_rb_t" "\$@"' <<< "$marked" || true)"
if [ "${n_files:-0}" -ge 100 ] && [ "${n_word:-0}" -ge 10 ] && [ "${n_mark:-0}" = 3 ] && [ "${n_mark_os:-0}" = 3 ] && [ "${n_mark_cmd:-0}" = 3 ]; then
  ok "gate: it looked at something (${n_files} scripts, ${n_word} run timeout) and the exemption marker is on exactly the 3 runner lines, all in lib/os.sh"
else bad "gate: the scan looked at too little, or the exemption marker is somewhere it should not be" "scripts=${n_files} with-timeout=${n_word} marked-in-scripts=${n_mark} in-os.sh=${n_mark_os} of-which-runner-lines=${n_mark_cmd}"; fi
# CONTROL: the same scan over planted lines.
mkdir -p "$T/plant"
# The planted lines ARE the forms under test, written literally (SC2016 is deliberate).
# shellcheck disable=SC2016
{
  printf 'timeout "${SOME_TIMEOUT:-3}" kubectl get ns\n'
  printf 'x="$(timeout "$SOME_TIMEOUT" getent hosts h)"\n'
  printf 'timeout $SOME_TIMEOUT true\n'
  printf 'timeout -k 2 "${A:-${B:-10}}" \\\n'
  printf 'KUBECONFIG="$kc" timeout --foreground "${SOME_TIMEOUT}" kubectl version\n'
  printf 'timeout -s KILL "$SOME_TIMEOUT" kubectl get ns\n'
  printf 'timeout ${SOME_TIMEOUT}s kubectl get ns\n'
  printf 'timeout $((SOME_TIMEOUT)) kubectl get ns\n'
  printf 't=(timeout "$SOME_TIMEOUT"); "${t[@]}" kubectl get ns\n'
  printf 'timeout --signal KILL --kill-after 2 "$SOME_TIMEOUT" true\n'
} > "$T/plant/caught.sh"
# shellcheck disable=SC2016
{
  printf 'timeout 15 openssl s_client\n'
  printf 'timeout -s KILL 15 openssl s_client -connect "$h"\n'
  printf 'helm upgrade --wait --timeout "${READY_TIMEOUT_SECONDS}s"\n'
  printf 'log_info "waiting (timeout ${READY_TIMEOUT_SECONDS}s)"\n'
  printf 'curl --connect-timeout "${X:-5}" https://h\n'
  printf '_sup_timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl get ns\n'
  printf '  # timeout "$X" would be wrong here\n'
  printf 'timeout "$t" "$@"   # bounded-runner\n'
  printf 'run_bounded SOME_TIMEOUT 3 getent hosts h\n'
} > "$T/plant/clean.sh"
n_caught="$(scan "$T/plant" | command grep -c 'caught.sh' || true)"
n_clean="$(scan "$T/plant" | command grep -c 'clean.sh' || true)"
if [ "$n_caught" = 10 ] && [ "$n_clean" = 0 ]; then
  ok "gate control: all 10 planted raw forms are caught (quoted, bare, -s KILL, \${X}s, \$((X)), an array) and none of the 9 legitimate lines is"
else bad "gate control: the scan is wrong" "caught ${n_caught} of 10 raw forms; flagged ${n_clean} of 9 legitimate lines: $(scan "$T/plant" | sed "s#$T/plant/##" | cut -c1-70 | tr '\n' ';')"; fi

# EVERY VARIABLE NAMED AT A RUNNER IS ONE bounds_normalize KNOWS. A new knob that is handed to a
# runner but missing from the registry would be clamped in silence: the defect this file is about.
# Test files name made-up variables on purpose; only the product's count. Comment lines dropped.
named="$(find "${REPO}/scripts" -name '*.sh' ! -name 'test-*.sh' -exec grep -hE -- 'run_bounded(_group)?[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]' {} + 2>/dev/null \
           | command grep -vE '^[[:space:]]*#' | command grep -oE 'run_bounded(_group)?[[:space:]]+[A-Z][A-Z0-9_]*' | sed -E 's/run_bounded(_group)?[[:space:]]+//' | sort -u)"
unknown=""
while IFS= read -r v; do
  [ -n "$v" ] || continue
  command grep -qE "^${v} [0-9]+\$" <<< "$BOUND_VARIABLES" || unknown="${unknown} ${v}"
done <<< "$named"
n_named="$(command grep -c . <<< "$named" || true)"
if [ -z "$unknown" ] && [ "${n_named:-0}" -ge 6 ]; then ok "registry: all ${n_named} variables handed to a runner by name are in BOUND_VARIABLES (so an unusable value is reported)"
else bad "registry: a variable reaches a runner that bounds_normalize does not know (it would be clamped in silence)" "named at runners: ${n_named}; not in the registry:${unknown:- none}"; fi

# NO MARKER FILE IS LEFT IN THE DESIGN. Its write followed a symlink planted at the path. The
# needle is put together here so that this file does not contain it.
needle=".bound-""warned"
left="$(command grep -rlF --include='*.sh' -- "$needle" "${REPO}/scripts" 2>/dev/null || true)"
left2="$(command grep -rlE --include='*.sh' -- '_bound_warn_once|_BOUND_WARNED' "${REPO}/scripts" 2>/dev/null | command grep -vE '/test-timeout-bounds\.sh$' || true)"
# (this file is left out of the second search only: it names the two helpers to look for them)
if [ -z "$left" ] && [ -z "$left2" ]; then ok "no marker-file path and no warn-once helper is left anywhere under scripts/"
else bad "the marker file (or its helper) is still in the tree" "$(printf '%s %s' "$left" "$left2" | sed "s#${REPO}/##g" | cut -c1-160)"; fi
# NO DYNAMIC ASSIGNMENT TARGET IN A LIBRARY. `printf -v "$name"` in lib/os.sh made shellcheck
# assume any variable, `$!` included, may be written, and `make lint` then failed on a test file
# that only SOURCES the library (SC2031 on `& SRV=$!`). A per-file shellcheck of the changed
# files cannot see that; this line can. Comment lines are dropped (one names the form).
# The pattern is the form itself (SC2016 is deliberate).
# shellcheck disable=SC2016
dyn="$(command grep -nE 'printf[[:space:]]+-v[[:space:]]+"?\$' "${REPO}"/scripts/lib/*.sh | command grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' || true)"
n_libs="$(find "${REPO}/scripts/lib" -name '*.sh' | wc -l | tr -d ' ')"
if [ -z "$dyn" ] && [ "${n_libs:-0}" -ge 5 ]; then ok "no library assigns through a dynamic target (printf -v \"\$name\"): the form that makes lint fail in every script that sources it (${n_libs} libraries)"
else bad "a library assigns through printf -v \"\$name\": shellcheck will flag \$! in unrelated callers" "$(printf '%s' "$dyn" | sed "s#${REPO}/##" | cut -c1-160)"; fi
if [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then ok "nothing in this file left anything in TMPDIR"
else bad "something wrote to TMPDIR" "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | head -3 | tr '\n' ' ')"; fi

printf '\ntest-timeout-bounds: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-timeout-bounds: OK\n'
