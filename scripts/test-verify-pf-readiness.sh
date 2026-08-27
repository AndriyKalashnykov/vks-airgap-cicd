#!/usr/bin/env bash
# shellcheck disable=SC2016  # every grep pattern here is a LITERAL to match inside 99-verify.sh,
#   not an expansion. Double-quoting would expand ${app}/${health}/$rc and match nothing.
# shellcheck disable=SC2034  # img/app/ns/pf_target are consumed by the classifier stand-in under
#   the SAME names the real function uses; renaming them would weaken the fidelity this test needs.
# test-verify-pf-readiness.sh — the READINESS wait must rebuild a dead tunnel, not blame the app.
#
# THE DEFECT THIS PINS (measured 2026-08-27, KinD e2e). B497 gave marker_visible() a tunnel-death
# classifier that rebuilds the port-forward. The `app HTTP up` READINESS wait, which runs BEFORE it,
# had none: a tunnel that died there was never detected, the wait burned its full 600s, and it died
#   FATAL [javawebapp] app not serving /healthz (tunnel to javawebapp-...-cxhjq, generation 1)
# `generation 1` proves no rebuild happened. At that moment the app served HTTP 200 through the
# ingress, both pods were 1/1 Running, and NO kubectl port-forward process existed.
#
# ⚠️ HONESTY — WHAT THIS GREEN DOES NOT PROVE. The cases below exercise a REIMPLEMENTATION of the
# classifier's contract, not scripts/99-verify.sh's actual _pf_classify: that function is nested
# inside verify_app() with locals and cannot be sourced standalone. A contract test of a stand-in is
# a test of the stand-in unless something ties it to the real code -- so the WIRING block at the end
# asserts, against the real file, that the readiness wait calls the predicate and that the predicate
# delegates to the ONE shared classifier. Contract + wiring together are the claim; neither alone is.
# What is still NOT covered: the live behaviour of a real dying port-forward. That is
# `make e2e-kind`, and it is where the defect was found in the first place.
set -uo pipefail
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok    $1"; else fail=$((fail+1)); echo "  FAIL  $1 (want '$3', got '$2')"; fi; }

# A faithful stand-in for the shared classifier's contract: same inputs, same state transitions.
mk() {  # mk <curl-rc> <kubectl-rc> <ready-string>
  RC="$1"; KRC="$2"; READY="$3"
  PF_DEATHS=0; PF_POLL_FAILS=0; PF_RESTARTS_BLOCKED=""; PF_UNKNOWN=""; PF_GEN=1; REBUILT=0
  _start_pf() { PF_GEN=$((PF_GEN+1)); REBUILT=$((REBUILT+1)); }
  # shellcheck disable=SC2329  # stand-ins for the real script's indirect callees
  _pf_ev() { :; }
  # shellcheck disable=SC2329
  _pick_pod() { echo "pod-x"; }
  # shellcheck disable=SC2329
  _curl_rc_label() { echo "rc=$1"; }
  VERIFY_PF_MAX_GENERATIONS=5; img=i; app=a; ns=n; pf_target=pod-x
  classify() {
    local rc="$1"
    if [ "$rc" -eq 22 ]; then PF_POLL_FAILS=$((PF_POLL_FAILS+1)); return 1; fi
    if [ "$KRC" -ne 0 ]; then
      PF_UNKNOWN="kubectl rc=$KRC"; PF_DEATHS=$((PF_DEATHS+1))
      [ "$PF_GEN" -lt "$VERIFY_PF_MAX_GENERATIONS" ] && _start_pf
      return 1
    fi
    if grep -q false <<< "$READY" || [ -z "$READY" ]; then
      PF_RESTARTS_BLOCKED="pods not Ready"; PF_POLL_FAILS=$((PF_POLL_FAILS+1)); return 1
    fi
    PF_DEATHS=$((PF_DEATHS+1))
    [ "$PF_GEN" -lt "$VERIFY_PF_MAX_GENERATIONS" ] && _start_pf
    return 1
  }
  classify "$RC"
}

echo "the readiness wait's tunnel classification"
mk 7 0 "true true "
ck "rc=7, pods Ready  -> counts a DEATH"        "$PF_DEATHS" 1
ck "rc=7, pods Ready  -> REBUILDS the tunnel"   "$REBUILT"   1
ck "rc=7, pods Ready  -> not blamed on the app" "$PF_RESTARTS_BLOCKED" ""

mk 56 0 "true true "
ck "rc=56 (accept-then-RST) is a death too"     "$PF_DEATHS" 1
mk 28 0 "true true "
ck "rc=28 (accept-then-hang) is a death too"    "$PF_DEATHS" 1

mk 22 0 "true true "
ck "rc=22 is a SUCCESSFUL round trip"           "$PF_DEATHS" 0
ck "rc=22 does NOT rebuild"                     "$REBUILT"   0

mk 7 0 "true false "
ck "pods NOT Ready -> the APP, no death"        "$PF_DEATHS" 0
ck "pods NOT Ready -> no rebuild"               "$REBUILT"   0

mk 7 1 ""
ck "kubectl unavailable -> death + rebuild"     "$PF_DEATHS" 1
ck "kubectl unavailable -> flagged UNKNOWN"     "${PF_UNKNOWN:+set}" set

mk 7 0 "true true "; PF_GEN=5; REBUILT=0; classify 7
ck "generation cap spent -> no further rebuild" "$REBUILT"   0

echo
echo "the WIRING, asserted against scripts/99-verify.sh itself"
V="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/99-verify.sh"
[ -f "$V" ] || { echo "  FAIL  99-verify.sh not found at $V"; exit 1; }
ck "readiness wait uses the predicate"        "$(grep -c 'wait_for "\[\${app}\] app HTTP up" _health_up' "$V")" 1
ck "_health_up delegates to the classifier"   "$(grep -c '_pf_classify "\$rc"' "$V")" 2
ck "exactly ONE classifier definition"        "$(grep -c '_pf_classify() {' "$V")" 1
ck "readiness failure can say HARNESS-TUNNEL" "$(grep -c 'HARNESS-TUNNEL \[\${app}\] \${health} was NEVER reached' "$V")" 1
ck "the old un-rebuilding wait is GONE"       "$(grep -c 'wait_for "\[\${app}\] app HTTP up" curl' "$V")" 0

echo

# --- the REMOTE port must follow the TARGET ---------------------------------------
# 80 is the SERVICE port (targetPort `http` = 8080 in the container). Binding a NAMED POD on :80
# can never connect. MEASURED on a healthy Ready pod: pod:80 -> http 000, pod:8080 -> http 200,
# svc:80 -> http 200. It shipped as `"${app_local_port}:80"` for BOTH targets, so every run that
# successfully found a Ready pod was unreachable -- 114 refused connections across the generation
# cap, ~10 minutes after the pods were Ready in 6s. The svc/ fallback still worked, so the failure
# only appeared when the pod lookup SUCCEEDED.
pf_line=$(grep -c 'port-forward "$pf_target" "${app_local_port}:${pf_port}"' "$V")
ck "the port-forward binds \${pf_port}, not a literal :80" "$pf_line" "1"
ck "no literal :80 remains on the port-forward line" \
   "$(grep -c 'port-forward "$pf_target" "${app_local_port}:80"' "$V")" "0"
# ⚠️ THIS USED TO ASSERT THE JSONPATH APPEARS EXACTLY ONCE, and that made it a gate that was GREEN
# over a live defect and RED on its remedy -- the shape most likely to get a correct fix reverted to
# restore a green gate. The defect: pf_port was resolved ONCE, at the initial bind, while both
# tunnel-rebuild sites reassigned pf_target and inherited the stale port. Every Service exposes only
# 80 and every containerPort is 8080, so pod->svc/ bound svc/ on 8080 (no such service port) and
# svc/->pod bound a pod on 80 (nothing listening); either killed the tunnel for the rest of the run.
# Resolving the port in a helper called at all three sites is the fix, and it necessarily makes the
# jsonpath appear once while the CALL appears three times. Assert the invariant that matters: the
# port is re-derived wherever the target is chosen.
ck "pf_port is resolved from the pod's containerPort" \
   "$([ "$(grep -c 'jsonpath=.{.spec.containers\[0\].ports\[0\].containerPort}' "$V")" -ge 1 ] && echo ok)" "ok"
# ⚠️ TWO PREVIOUS VERSIONS OF THIS ASSERTION WERE BOTH GAMEABLE, AND BOTH WERE MEASURED SO.
#   v1  grep -c '_resolve_pf_port' == 4   -> GREEN on a new rebuild site with NO re-derivation,
#                                            RED on a correct addition, RED on a bare comment.
#   v2  executable SITES vs executable CALLS -> RED on the _pick_pod-shaped defect (an improvement),
#       but still GREEN on FOUR other realistic edits that carry the same stale-port bug: a
#       `pf_target="svc/${app}"` site with no _pick_pod (a shape that ALREADY EXISTS TWICE in the
#       file); a call made unreachable by a condition; the call moved BEFORE the assignment; and a
#       blanking revert written `pf_target=''` in single quotes, which v2's sibling guard could not
#       see because it greps the double-quoted literal.
#
# Detecting the bug was the wrong goal. The port is now resolved INSIDE _start_pf, which is the one
# place that binds, so a site cannot exist without a re-derivation. The assertion collapses to a
# structural fact with nothing to count and nothing to gap.
_pf_body="$(sed -n '/_start_pf() {/,/^  }/p' "$V")"
# ⚠️ THREE VERSIONS OF THIS ASSERTION HAVE NOW BEEN MEASURED GAMEABLE. v1 counted occurrences of
# the helper name; v2 compared "sites" to "calls"; v3 asserted the call is PRESENT in _start_pf's
# body. v3 still had FOUR false greens, two of which an adversary EXECUTED to the wrong port:
#   - the call moved BELOW the port-forward line      -> bound svc/ on 8080 AND a pod on 80
#   - `[ "${PF_GEN:-0}" -eq 0 ] && _resolve_pf_port`  -> bound svc/ on 8080 on every rebuild
#   - the call deleted with only a TRAILING comment naming it (the `grep -vE '^[[:space:]]*#'`
#     filter strips FULL-LINE comments only)
#   - a SECOND port-forward of the app port outside _start_pf, breaking the one-bind invariant
# Presence is not enough: ORDER and REACHABILITY and one-binder all matter. Assert the call is the
# FIRST EXECUTABLE LINE of the body -- which is unorderable, unreachable-proof and comment-proof --
# and that exactly one line binds the app's local port.
_pf_first="$(printf '%s\n' "$_pf_body" | sed 1d | grep -vE '^[[:space:]]*(#|$)' | head -1 | sed 's/^[[:space:]]*//')"
ck "_resolve_pf_port is the FIRST executable line of _start_pf" "$_pf_first" "_resolve_pf_port"
ck "exactly ONE line binds the app's local port" \
   "$(grep -cE 'port-forward .*\$\{app_local_port\}' "$V")" "1"
# The single-quote blindness that let a blanking revert through v2, in both spellings.
ck "no code path assigns an empty pf_target (single-quoted)" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c "pf_target=''")" "0"
# One channel definition, not two. Two existed at 443 and 529 and DIFFERED in indentation, so the
# same helper formatted archive events differently depending on which wait fired.
ck "exactly ONE _pf_ev definition" \
   "$(grep -c '_pf_ev() {' "$V")" "1"
# ⚠️ EXECUTABLE lines only: the phrase appears in the explanatory comment too, and counting both
# made this assert 2. Same trap as "a check that greps a symbol also matches its own docstring".
# ⚠️ THIS USED TO ASSERT THE MESSAGE APPEARS EXACTLY ONCE, which made it brittle AND vacuous: it
# broke when a second, DIFFERENT channel was added for the same event, while never checking what the
# fallback assigns (the assertions below do that). The real invariant is that a rebuild-time
# downgrade reaches BOTH channels -- log_warn for a human tailing the run, and _pf_ev for the
# archive -- because at both rebuild sites this code runs inside a wait_for predicate that discards
# stdout and stderr, so log_warn ALONE leaves no trace of a silent target/port change.
ck "the no-containerPort downgrade is reported to a human (log_warn)" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c 'log_warn.*declares no containerPort')" "1"
ck "the no-containerPort downgrade also reaches the ARCHIVE (_pf_ev, which wait_for cannot discard)" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c '_pf_ev.*declares no containerPort')" "1"
# ⚠️ THIS COUNTED OCCURRENCES (== 2) AND NAMED NO CHANNEL -- the exact vacuity it replaced.
# MEASURED: swapping the log_warn for a SECOND _pf_ev deletes the human channel entirely and the
# count stays 2, so it stayed `ok`. Anchor each channel, like the pair above.
ck "a kubectl FAILURE reaches a human (log_warn), not mislabelled as 'declares no containerPort'" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c 'log_warn.*could not read')" "1"
ck "a kubectl FAILURE also reaches the ARCHIVE (_pf_ev)" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c '_pf_ev.*could not read')" "1"

# ⚠️ THE LINE ABOVE COUNTS A LOG MESSAGE, NOT A BEHAVIOUR, and was therefore VACUOUS with respect to
# what the fallback actually assigns: it passed both when the helper blanked pf_target and when it
# set svc/. That distinction is the whole bug -- MEASURED, `kubectl port-forward "" 18099:80` ->
# "error: resource name may not be empty", and the two REBUILD sites call _start_pf immediately with
# no empty-check, so a blanking fallback is a permanently dead tunnel there. Assert the assignment.
ck "the no-containerPort fallback assigns svc/, never an empty target" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -A1 'declares no containerPort' | grep -c 'pf_target="svc/\${app}"')" "1"
ck "no code path assigns an empty pf_target" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -c 'pf_target=""')" "0"

# ---------------------------------------------------------------------------
# B502 -- a REBUILD's bind must reach the ARCHIVE, not only the terminal. Rebuild sites run inside a
# wait_for predicate, invoked as `"$@" >/dev/null 2>&1`, and _log writes to STDERR -- so log_info
# from a rebuild is discarded. PROVEN FIXED LIVE: a `make verify` recorded 6/6 apps with
# `bound <pod> remote port 8080 (generation 2)`, against 0/6 on the old channel.
# ⚠️ ANCHOR EVERY PRESENCE GREP AT LINE START. A body-presence grep is vacuous to a TRAILING
# comment: measured, `:  # _pf_ev "bound ..."` scored a full green against the unanchored form.
_b502="$(awk '/^  _start_pf\(\) \{/,/^  \}/' "$V")"
ck "_start_pf reports its bind through _pf_ev (the channel wait_for cannot discard)" \
   "$(printf '%s\n' "$_b502" | grep -cE '^[[:space:]]*_pf_ev .*bound .*generation')" "1"
ck "_start_pf still logs to the terminal too (the FIRST bind is worth a human-visible line)" \
   "$(printf '%s\n' "$_b502" | grep -cE '^[[:space:]]*log_info .*tunnel target')" "1"

# ---------------------------------------------------------------------------
# B503 -- the verdict is decided by POLL CLASSES on the SAME SCALE. Four designs were measured and
# THREE refuted: the latching string (one transient poll disabled HARNESS for the whole app); an
# ever-unstable guard (2/4 -- worse than the bug); and clearing the string per poll (3/4 -- inverts
# the error, telling a flapping app to "retry the row"). A fourth, PF_DEATHS vs PF_NOTREADY_POLLS,
# was refuted by INTERACTION: B506 caps PF_DEATHS at the generation cap while NOTREADY is capped by
# the poll count, so `D > N` became unwinnable after ~25s of any pod not-Ready -- and a rolling
# update makes that ordinary. Two individually-correct changes destroying each other.
# So: three UNCAPPED counters, one increment per poll, and PF_DEATHS kept only as the rebuild count.
_b503="$(awk '/^  _pf_classify\(\) \{/,/^  \}/' "$V")"
ck "not-Ready polls are counted as a CLASS" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*PF_NOTREADY_POLLS=\$\(\(PF_NOTREADY_POLLS \+ 1\)\)')" "1"
ck "could-not-ask polls are counted as a CLASS" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*PF_UNKNOWN_POLLS=\$\(\(PF_UNKNOWN_POLLS \+ 1\)\)')" "1"
ck "tunnel-dead polls are counted as a CLASS, OUTSIDE the generation-cap test" \
   "$(printf '%s\n' "$_b503" | grep -B2 -E '^[[:space:]]*if \[ "\$PF_GEN" -lt' | grep -cE '^[[:space:]]*PF_TUNNEL_POLLS=\$\(\(PF_TUNNEL_POLLS \+ 1\)\)')" "1"
# An ABSENCE check must NOT be anchored -- anchoring softens it. The most natural way to re-add the
# refuted clear is to append it to the existing `local rc=...` line, which an anchored grep misses.
ck "the REFUTED per-poll clear has not come back (unanchored on purpose)" \
   "$(printf '%s\n' "$_b503" | grep -vE '^[[:space:]]*#' | grep -cE 'PF_RESTARTS_BLOCKED=""; *PF_UNKNOWN=""')" "0"
# The arms must compare CLASSES. PF_DEATHS is capped, so any arm comparing it is the refuted design.
ck "NO verdict arm compares the CAPPED PF_DEATHS against a poll-class counter" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -cE 'PF_DEATHS" -(gt|ge|lt|le) "\$PF_(NOTREADY|UNKNOWN|TUNNEL)_POLLS|PF_(NOTREADY|UNKNOWN|TUNNEL)_POLLS" -(gt|ge|lt|le) "\$PF_DEATHS')" "0"
ck "both arms rank UNKNOWN by class, not by the capped death count" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -cE 'PF_UNKNOWN_POLLS" -ge "\$PF_TUNNEL_POLLS')" "2"
ck "the tunnel arm requires tunnel-dead polls to DOMINATE not-Ready polls" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -cE 'PF_TUNNEL_POLLS" -gt "\$PF_NOTREADY_POLLS')" "1"
ck "all three class counters are reset per app" \
   "$(grep -cE '^  PF_NOTREADY_POLLS=0; PF_UNKNOWN_POLLS=0; PF_TUNNEL_POLLS=0' "$V")" "1"

# ---------------------------------------------------------------------------
# B508 -- BOTH arms must be able to say UNKNOWN, and must rank it FIRST. The first attempt added the
# branch to the readiness arm but left it BELOW the tunnel branch and gated on `U <= D` -- measured a
# TAUTOLOGY (both incremented adjacently), so over 4000 random interleavings `U > D` never occurred
# and the branch could not fire for the tenant it was written for. Ranking the same evidence in
# opposite orders in the two arms is the defect; assert the ORDER, not merely the presence.
# MATCH THE MESSAGE, NOT THE VERB: a `(die|log_error)` pattern puts those literals in this file and
# check-lib-sourcing reads a lib-function name inside a quoted grep argument as a CALL (B509).
ck "BOTH verdict arms can report UNKNOWN" \
   "$(grep -cE '"UNKNOWN \[\$\{app\}\]' "$V")" "2"
ck "the readiness arm ranks UNKNOWN BEFORE the tunnel verdict (line order, both in the same arm)" \
   "$(awk '/if ! wait_for "\[\$\{app\}\] app HTTP up"/,/^  fi$/' "$V" | grep -nE '"UNKNOWN \[|HARNESS-TUNNEL \[' | head -1 | grep -c UNKNOWN)" "1"

# ---------------------------------------------------------------------------
# B506 -- a death per DEATH, not per POLL, and each cap-spent event ONCE. Measured at the documented
# defaults: 120 deaths / 120 event lines (6 distinct) -> 6 / 6 / 0 duplicates. The FIRST version
# applied this to the pods-Ready path only; the kubectl-unqueryable path -- the one a broken
# kubeconfig or stale token takes, i.e. the likeliest non-tunnel failure a tenant hits -- still
# flooded 120/120. Both paths are guarded now.
# ⚠️ ASSERT THE GUARD, NOT THE ASSIGNMENT. Measured: defeating the condition (`if true; then  #
# PF_CAP_SPENT=1`) leaves the assignment line intact, so an assignment-only check stays green over a
# restored flood. Same for the UNKNOWN branches -- prefixing `[ 1 -eq 0 ] &&` leaves both the message
# and the line ORDER untouched, so neither a presence nor an order check can see it. Pin the exact
# condition text; a constant-false conjunct then no longer matches.
ck "the tunnel cap-spent emit is GUARDED by the one-shot flag" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*if \[ -z "\$PF_CAP_SPENT" \]; then$')" "1"
ck "the could-not-ask cap-spent emit is GUARDED by its own one-shot flag" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*elif \[ -z "\$PF_UNKNOWN_ANNOUNCED" \]; then$')" "1"
ck "neither UNKNOWN branch carries an extra conjunct (a constant-false one makes it unreachable)" \
   "$(grep -cE '^[[:space:]]*(if|elif) \[ -n "\$PF_UNKNOWN" \] && \[ "\$PF_UNKNOWN_POLLS" -ge "\$PF_NOTREADY_POLLS" \] && \[ "\$PF_UNKNOWN_POLLS" -ge "\$PF_TUNNEL_POLLS" \]; then$' "$V")" "2"
ck "the cap-spent event is emitted ONCE on the tunnel path" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*PF_CAP_SPENT=1')" "1"
ck "the cap-spent event is emitted ONCE on the could-not-ask path too" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*PF_UNKNOWN_ANNOUNCED=1')" "1"
ck "post-cap polls are counted separately from deaths" \
   "$(printf '%s\n' "$_b503" | grep -cE '^[[:space:]]*PF_POSTCAP_POLLS=\$\(\(PF_POSTCAP_POLLS \+ 1\)\)')" "1"
ck "post-cap polls are REPORTED to the operator, not silently dropped" \
   "$(grep -vE '^[[:space:]]*#' "$V" | grep -cE 'further poll\(s\) after the cap was spent')" "2"

# ---------------------------------------------------------------------------
# B507 -- _start_pf must not RETURN until ITS OWN tunnel has bound. wait_for polls at t=0 and
# kubectl's cold-start floor alone is 22-24ms, so generation 1 was burned deterministically (36/36
# archived, 6/6 live). The first version probed the SOCKET without reaping the old listener: `kill`
# is asynchronous, so the probe connected to the DYING previous generation and reported success
# while the new kubectl failed EADDRINUSE -- measured, "broke after 0 attempts" against a corpse.
ck "the previous generation is REAPED before the new bind" \
   "$(printf '%s\n' "$_b502" | grep -cE '^[[:space:]]*_w=0; while kill -0 "\$PF_PID"')" "1"
ck "_start_pf waits for its own bind before returning" \
   "$(printf '%s\n' "$_b502" | grep -cE '^[[:space:]]*\(exec 3<>"/dev/tcp/127\.0\.0\.1/\$\{app_local_port\}"\)')" "1"
ck "the bind wait aborts if the NEW kubectl is already dead" \
   "$(printf '%s\n' "$_b502" | grep -cE '^[[:space:]]*kill -0 "\$PF_PID" .*DIED BEFORE BINDING')" "1"
ck "the bind wait is BOUNDED" \
   "$(printf '%s\n' "$_b502" | grep -cE '^[[:space:]]*while \[ "\$_b" -lt [0-9]+ \]')" "1"
ck "the bind wait probes the LOCAL socket, never the app's health URL" \
   "$(printf '%s\n' "$_b502" | grep -vE '^[[:space:]]*#' | grep -cE '^[[:space:]]*[^#]*curl ')" "0"

if [ "$fail" -eq 0 ]; then echo "test-verify-pf-readiness: ${pass} passed, 0 failed"; exit 0; fi
echo "test-verify-pf-readiness: ${pass} passed, ${fail} FAILED"; exit 1
