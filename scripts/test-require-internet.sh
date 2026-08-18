#!/usr/bin/env bash
# test-require-internet.sh — the internet PROBE's predicate, and that it names the failure MODE.
#
# WHY THIS EXISTS (B181). Run 6's only RED was row 3: `require_internet` printed `NO INTERNET on this
# box`, killed `make mirror-pull`, and took the rest of a ~25-minute matrix row with it. The box was
# online -- it had downloaded OS packages from the internet ~18 minutes earlier in the same walk.
#
# The defect was the PREDICATE, not the patience. `curl -sSf --head https://storage.googleapis.com`
# returns **HTTP 400**, and `-f` turns any 4xx into exit 22 -- so probe host #1 had NEVER succeeded in
# the life of that code (measured 5/5 on a box with working internet, github 200 in the same second).
# The comment above it claimed "two hosts, so one provider being down is not read as 'no internet'";
# that redundancy DID NOT EXIST. github.com alone decided, and any 403/429/5xx from it -- the
# abuse-detection class `http_get_retry` already fights -- read as "this box has no internet".
#
# An HTTP status line of ANY kind requires DNS + TCP + TLS + a full round trip to SUCCEED, so a 400 is
# POSITIVE PROOF of internet that `-f` discarded. The predicate is now "did anything answer"
# (`%{http_code} != 000`), and curl's exit code names the mode (6=DNS, 7=refused, 28=timeout, 35/60=TLS).
#
# ⚠️ WHAT THIS DOES NOT PROVE, stated rather than implied:
#   * It does not touch the network. `curl` is STUBBED, so this is offline and deterministic -- which
#     also means it cannot catch storage.googleapis.com CHANGING its answer to `HEAD /`. That is a
#     live fact with a 5/5 measurement behind it, re-checkable in one command:
#         curl -sS -o /dev/null --head -w '%{http_code}\n' https://storage.googleapis.com
#   * It does not prove a retry is unnecessary. A bounded retry was REFUTED for a different reason
#     (it re-runs the predicate, and the predicate was the bug) -- see B181.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

pass=0; fail=0
ck() {  # ck <label> <predicate-command...>  -- the helper RUNS the predicate, so no `$?`-after-a-
        # condition (SC2319) and the rc cannot be clobbered by an expansion in the label.
  local label="$1"; shift
  if "$@"; then echo "  PASS  ${label}"; pass=$((pass+1))
  else echo "  FAIL  ${label}"; fail=$((fail+1)); fi
}

# Substring predicates as REAL COMMANDS, not `bash -c '<string>'`. Two reasons, and the second is
# the one that reddened CI: (a) `ck` runs its argv, so a plain command composes cleanly; (b) CI's
# `make lint` treats shellcheck SC2016 *info* as a finding, and every `bash -c '[[ "$1" == ... ]]'`
# trips it -- while a bare local `shellcheck -x` exits 0, so the divergence is invisible until CI.
# The sibling tests (e.g. test-argocd-classify.sh) already pass simple commands for this reason.
# shellcheck disable=SC2329  # invoked INDIRECTLY, via ck's "$@" -- the case the message itself exempts
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2329  # same: indirect via ck "$@"
hasnt() { case "$2" in *"$1"*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------------------------------------
# The stub reproduces curl's REAL contract, which is the whole point of the fix:
#   * `-w '%{http_code}'` writes the code to STDOUT -- and it writes `000` when there was no answer
#   * transport errors go to STDERR (that is what `-S` is for)
#   * the exit status is curl's, and it is NOT 0 for a 4xx once `-f` is gone... it IS 0, because
#     without `-f` curl does not treat an HTTP status as an error. The stub takes rc per case so a
#     future reader can encode either.
# ---------------------------------------------------------------------------------------------
_probe() {  # _probe <expect: 0|die> <label> <host:code:rc> ...
  local want="$1" label="$2"; shift 2
  local cases="$*" out rc
  # Run in a SUBSHELL: `die` calls exit, so it must not take the test harness with it.
  out="$(
    # Optional: make mktemp FAIL, to exercise the degraded path (a read-only or full /tmp -- exactly
    # the kind of box this function exists to diagnose). MEASURED: without the `|| true` guard in
    # os.sh, a failed mktemp makes the assignment non-zero and `set -euo pipefail` kills the script,
    # so the operator gets mktemp's message INSTEAD of the air-gap guidance.
    if [ -n "${_STUB_MKTEMP_FAIL:-}" ]; then
      mktemp() { echo "mktemp: failed to create file" >&2; return 1; }
    fi
    curl() {
      local url="${*: -1}" c
      for c in $cases; do
        case "$url" in *"${c%%:*}"*)
          # ⚠️ ONE `local` PER VARIABLE. `local a=X b="${a...}"` leaves b EMPTY: `local` marks every
          # name local (and unset) BEFORE the right-hand sides expand, so ${a} reads the fresh empty
          # local rather than the value assigned one word earlier. Measured: one-statement -> [],
          # two-statement -> [400]. This exact bug lived in the FIRST version of this harness and
          # made a CORRECT fix look broken -- distrust the instrument before the product.
          local rest="${c#*:}"
          local code="${rest%%:*}"
          rest="${rest#*:}"
          local crc="${rest%%:*}"
          local err="${rest#*:}"
          [ "$err" = "-" ] || printf 'curl: (%s) %s\n' "$crc" "${err//_/ }" >&2
          printf '%s' "$code"
          return "$crc" ;;
        esac
      done
      printf '000'; return 6      # a host the case list does not mention: no answer
    }
    require_internet "the test" 2>&1 && echo "__ONLINE__"
  )" && rc=0 || rc=$?

  case "$want" in
    0)   ck "$label" test "$rc" -eq 0
         ck "  ...and it reported ONLINE rather than dying" has __ONLINE__ "$out" ;;
    die) ck "$label" test "$rc" -ne 0
         ck "  ...and it did NOT report ONLINE" hasnt __ONLINE__ "$out" ;;
  esac
  _LAST_OUT="$out"
}

echo "require_internet — the predicate is 'did anything ANSWER', not 'did it answer 2xx'"

# THE MEASURED INCIDENT. storage answers its usual 400; github is blackholed (000 / rc28). Pre-fix
# this DIED and cost a matrix row. The 400 alone proves the box is online.
_probe 0 "row-3 shape: storage 400 + github TIMED OUT -> ONLINE" \
  'storage:400:22:The_requested_URL_returned_error:_400' 'github:000:28:Connection_timed_out'

# The class the missing redundancy exposed: github rate-limits (429) while storage answers.
_probe 0 "github 429 + storage 400 -> ONLINE (the abuse-detection class)" \
  'storage:429:22:The_requested_URL_returned_error:_429' 'github:429:22:The_requested_URL_returned_error:_429'

# A 400 from the FIRST host must short-circuit: online, without needing github at all.
_probe 0 "storage 400 alone -> ONLINE (github never consulted)" \
  'storage:400:22:The_requested_URL_returned_error:_400'

# ---- The CONTROLS. A guard that cannot say NO is not a guard. -------------------------------
_probe die "genuinely air-gapped: both hosts unresolvable -> DIES" \
  'storage:000:6:Could_not_resolve_host' 'github:000:6:Could_not_resolve_host'
ck "  ...and the PER-HOST line names the mode as DNS (rc=6)" has "rc=6 (DNS" "$_LAST_OUT"

_probe die "blackholed: both hosts time out -> DIES" \
  'storage:000:28:Connection_timed_out' 'github:000:28:Connection_timed_out'
ck "  ...and the PER-HOST line names the mode as TIMED OUT (rc=28)" has "rc=28 (TIMED OUT" "$_LAST_OUT"

_probe die "intercepting proxy: TLS fails on both -> DIES" \
  'storage:000:60:SSL_certificate_problem' 'github:000:35:SSL_connect_error'
ck "  ...and the PER-HOST lines name the mode as TLS (rc=60 AND rc=35)" has "rc=60 (TLS failed" "$_LAST_OUT"
ck "  ...on the SECOND host too (a per-host label, not one applied to both)" has "rc=35 (TLS failed" "$_LAST_OUT"

ck "  ...and the die keeps curl's OWN message (the old form asked for it via -S then discarded it)" \
   has SSL "$_LAST_OUT"

# ---- The DEGRADED path: mktemp unavailable (read-only / full /tmp) ---------------------------
# The verdict must be UNAFFECTED; only curl's stderr text is lost. Without the guard in os.sh this
# case does not merely lose text -- the script DIES before it can print the air-gap guidance.
_STUB_MKTEMP_FAIL=1
_probe 0 "mktemp FAILS + row-3 shape -> still ONLINE (verdict unaffected)" \
  'storage:400:22:The_requested_URL_returned_error:_400' 'github:000:28:Connection_timed_out'

_probe die "mktemp FAILS + genuinely air-gapped -> still DIES with the AIR-GAP guidance" \
  'storage:000:6:Could_not_resolve_host' 'github:000:6:Could_not_resolve_host'
ck "  ...and the message is the SNEAKERNET guidance" has SNEAKERNET "$_LAST_OUT"
ck "  ...and NOT an mktemp error" hasnt "failed to create file" "$_LAST_OUT"
ck "  ...and the PER-HOST line still names the mode (the rc survives; only curl's text is lost)" \
   has "rc=6 (DNS" "$_LAST_OUT"
unset _STUB_MKTEMP_FAIL

# ---- _curl_rc_label: the vocabulary itself --------------------------------------------------
echo
echo "_curl_rc_label — every mode a no-internet report has to distinguish"
for pair in "6:DNS" "7:refused" "28:TIMED OUT" "35:TLS" "60:TLS" "22:PROVES internet" "0:answered"; do
  rc_in="${pair%%:*}"; want="${pair#*:}"
  got="$(_curl_rc_label "$rc_in")"
  ck "rc=${rc_in} names '${want}'" has "$want" "$got"
done

# ---- STRUCTURAL: defence-in-depth, and NOT a behavioural guard -------------------------------
# ⚠️ BE PRECISE ABOUT WHAT THIS CATCHES, because the obvious reading is wrong. MEASURED against the
# real network: `-w '%{http_code}'` emits the code EVEN WHEN `-f` makes curl exit 22 --
#     curl -sS   ... -> code=[400] rc=0    | predicate says INTERNET
#     curl -sSf  ... -> code=[400] rc=22   | predicate says INTERNET
# -- so the corrected predicate is IMMUNE to `-f`, and re-adding `-f` does NOT reproduce the row-3
# failure. Proven by mutation: restoring `-f` reddens ONLY the check below; all 3 behavioural cases
# still pass, correctly.
#
# The load-bearing change was therefore `-w '%{http_code}'` PLUS judging on the code instead of the
# exit status; dropping `-f` is hygiene. This check exists because a future refactor that goes back
# to keying on curl's rc would silently restore the defect, and because `-f` misstates the intent
# ("2xx or bust") of a liveness probe. Do not read a green here as behavioural coverage -- the three
# ONLINE cases above are that.
#
# ⚠️ COMMENTS MUST BE STRIPPED FIRST. The function's own header quotes `curl -sSf` while explaining
# why it is gone, so a naive grep matches the PROSE and this guard would fire on a correct tree --
# the documented "a gate that reads itself" trap. The positive control below proves the strip did
# not simply eat everything.
echo
echo "structural: the ACTIVE curl invocation, comments stripped (defence-in-depth, see header)"
body="$(sed -n '/^require_internet()/,/^}/p' "${SCRIPT_DIR}/lib/os.sh" \
        | sed 's/[[:space:]]*#.*$//')"
ck "the active invocation does NOT pass -sSf (it discarded a 400 that PROVES internet)" \
   hasnt "-sSf" "$body"
ck "the active invocation does NOT pass a bare curl -f either" hasnt "curl -f" "$body"
ck "the active invocation DOES ask for the http_code writeout (the predicate needs it)" \
   has '%{http_code}' "$body"
ck "the comment-strip did not eat the invocation itself (positive control)" \
   has "curl -sS" "$body"

echo
if [ "$fail" -eq 0 ]; then echo "require_internet: ALL PASS (${pass})"; exit 0; fi
echo "require_internet: ${fail} FAILED, ${pass} passed"; exit 1
