#!/usr/bin/env bash
# Headlamp helpers, single-sourced so the INSTALLER and `creds.sh` cannot drift apart.
#
# WHY THIS FILE EXISTS. Headlamp v0.45.0 stores the pasted token in an HttpOnly cookie whose
# Max-Age is the `-session-ttl` flag, set INDEPENDENTLY of the JWT's own `exp`. A cookie that
# outlives its token leaves the browser re-presenting a DEAD credential: 401 on everything, and
# the UI bounces to the paste screen with no message. `/set-token` VALIDATES NOTHING (an expired
# token, a truncated one, and literal garbage all return 200 with a fresh cookie), so re-pasting
# "succeeds" and bounces identically. The only cure is that the two numbers agree.

# headlamp_ttl_seconds <duration> -> prints seconds on stdout, rc=0
#                                    prints NOTHING, rc=1, on anything it will not accept.
#
# ⚠️ THE VALIDATION IS BEFORE THE ARITHMETIC, AND THAT ORDER IS THE WHOLE POINT.
#   1. `$(( ))` must never see operator input. Bash arithmetic EXECUTES commands through an array
#      subscript -- MEASURED 2026-09-06: HEADLAMP_TOKEN_DURATION='a[$(id -u > /tmp/PWNED; echo 0)]h'
#      ran `id`, wrote the file, and the script continued with rc=0 because the payload's `echo 0`
#      satisfied the digit check afterwards. In this repo's DEFAULT tenant posture `.env` is handed
#      over by a platform team, so that is a config->code path from someone who is not the operator.
#   2. A guard placed AFTER the arithmetic is DEAD CODE: under `set -e`, `$(( ))` aborts first, so
#      the carefully-worded `die` never runs and the operator gets a raw bash error naming neither
#      the variable nor the fix. MEASURED for `1h30m` (value too great for base), `1.5h` (invalid
#      arithmetic operator) and `08h` (octal).
#   3. `10#` forces base 10. Without it `010h` is OCTAL and silently yields 8h, not 10h -- the worst
#      shape, because it passes every guard and simply deploys the wrong number.
headlamp_ttl_seconds() {
  local _d="${1:-}" _n _u _s
  # ⚠️ THE CHARACTER CLASSES ARE ENUMERATED, NOT A RANGE, AND THAT IS LOAD-BEARING.
  # Bash bracket RANGES like [0-9] are COLLATION-based: in a UTF-8 locale they match non-ASCII
  # digits too. MEASURED on this box, same function, same input `１２h` (fullwidth):
  #     LC_ALL=en_US.UTF-8 -> PASSES both guards -> `10#: invalid integer constant`
  #     LC_ALL=C           -> rejected cleanly, rc=1, empty
  # That error is a FATAL SHELL EXPANSION ERROR, not a failed command, so the `|| true` at both
  # call sites CANNOT absorb it -- it re-opens the exact table-killing CRITICAL this file exists to
  # close, and it is LOCALE-DEPENDENT, so it is invisible on a C-locale CI runner and live on an
  # operator's UTF-8 desktop. An enumerated class is byte-exact in every locale.
  # (357 of 400 non-ASCII Unicode digits passed the range form.)
  # Reject the whole string first. This class catches `1.5h` (a `.`), `24H` (an `H`), and every
  # injection payload (`[`, `(`, `$`, backtick) before a single arithmetic expansion happens.
  case "$_d" in
    ''|*[!0123456789hms]*) return 1 ;;
    [0-9]*h) _n="${_d%h}"; _u=3600 ;;
    [0-9]*m) _n="${_d%m}"; _u=60 ;;
    [0-9]*s) _n="${_d%s}"; _u=1 ;;
    # A BARE NUMBER is rejected on purpose: `kubectl create token --duration=86400` fails with
    # "time: missing unit in duration", so accepting it here would install a cookie TTL for a
    # duration the token mint cannot use -- the two consumers would disagree by construction.
    *) return 1 ;;
  esac
  # `1h30m` reaches here as _n="1h30" (it ends in `m`); compound durations are refused rather than
  # silently mis-derived. kubectl accepts them; this derivation cannot, so say so instead of lying.
  case "$_n" in ''|*[!0123456789]*) return 1 ;; esac
  # Bound the DIGIT COUNT before the multiply. The range check below runs AFTER it, so a 64-bit
  # wrap can land back INSIDE the valid range and yield a plausible wrong number: measured,
  # `1152921504606847000h` (2^60+24) returned 86400 silently. >7 digits cannot be in range for any
  # unit, so this is a pure narrowing.
  case "$_n" in ????????*) return 1 ;; esac
  _s=$(( 10#$_n * _u ))
  # The chart's values.schema.json is `integer, minimum 1, maximum 31536000`. Out of range, helm
  # fails with a schema error that never names HEADLAMP_TOKEN_DURATION, so bound it here where the
  # message can. MEASURED: --set config.sessionTTL=0 -> "minimum: got 0, want 1", rc=1.
  [ "$_s" -ge 1 ] && [ "$_s" -le 31536000 ] || return 1
  printf '%s' "$_s"
}

# headlamp_deployed_ttl <namespace> -> prints the Deployment's effective -session-ttl, or NOTHING.
#
# ⚠️ IT CAN NEVER FAIL. Its only caller is `creds.sh`, whose own header says the report "MUST NOT
# HANG OR DIE ... every failure degrades to a marker". A NotFound (headlamp installed by a platform
# team under another release name), a Forbidden (the DEFAULT tenant posture), or a `timeout` kill
# must all read as "unknown", never as an exit.
headlamp_deployed_ttl() {
  local _ns="${1:-headlamp}" _args
  # Its OWN knob. It used to read CREDS_KUBE_TIMEOUT_SECONDS, so an operator lowering that to
  # speed up `make creds` silently weakened the INSTALLER's assert to "UNVERIFIED".
  _args="$(timeout "${HEADLAMP_READBACK_TIMEOUT_SECONDS:-${CREDS_KUBE_TIMEOUT_SECONDS:-10}}" kubectl --request-timeout=3s \
             -n "$_ns" get deploy headlamp \
             -o jsonpath='{.spec.template.spec.containers[?(@.name=="headlamp")].args}' \
             </dev/null 2>/dev/null || true)"
  # Name selector, not containers[0]: the chart appends `headlamp-plugin` (pluginsManager) and
  # `extraContainers` AFTER the main container today, so index 0 is correct but is a template
  # ordering coincidence rather than a guarantee. The selector costs nothing.
  # `[= ]` because a chart bump could switch to the space-separated flag form; matching only `=`
  # would make this silently return empty and the comparison silently never fire.
  # `paste -sd' '` REJOINS the elements first, so the k8s-canonical TWO-ELEMENT rendering
  # (`["-session-ttl","28800"]`, the flag and its value as separate argv entries) is covered. The
  # `=` and single-element-with-a-space forms were covered before; the two-element one returned
  # EMPTY, which silently disabled BOTH consumers -- the installer's assert stops asserting and
  # creds.sh skips the comparison, together and without a word.
  printf '%s' "$_args" | tr ',' '\n' | tr -d '"[]' | paste -sd' ' - \
    | sed -n 's/.*-session-ttl[= ][ ]*\([0-9][0-9]*\).*/\1/p' | head -1 || true
}
