#!/usr/bin/env bash
# ci-tier: fast
#
# Pins `kube_token_expiry` (lib/os.sh). Every case below is a MEASURED defect from one of the two
# adversary rounds on this function, not a hypothetical — the function shipped with FOUR of them and
# `make ci` was green over all four, which is exactly why this file exists.
#
# The failure direction that matters throughout: reporting a DEAD token as VALID. Three separate
# defects did that, each by a different mechanism (wrong user, wrong claim, unreadable integer).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source lib/os.sh"; exit 1; }

_pass=0; _fail=0
ok()  { printf 'ok    %s\n' "$1"; _pass=$((_pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; _fail=$((_fail + 1)); }
_T="$(mktemp -d)"; trap 'rm -rf "$_T"' EXIT

# b64url WITHOUT tr — this file must run on a box that has none (see the function's own header).
_b64u() { local x; x="$(base64 -w0)"; x="${x%%=*}"; x="${x//+/-}"; x="${x////_}"; printf '%s' "$x"; }
_jwt()  { printf '%s.%s.sig' "$(printf '{"alg":"none"}' | _b64u)" "$(printf '%s' "$1" | _b64u)"; }

# $1=file $2..=  name:payload pairs; FIRST pair is users[0], current-context is the LAST one.
_kc() {
  local f="$1"; shift
  { printf 'apiVersion: v1\nkind: Config\ncurrent-context: ctx\n'
    printf 'clusters: [{name: k, cluster: {server: https://127.0.0.1:1}}]\n'
    printf 'contexts:\n'
    local last=""; for p in "$@"; do last="${p%%:*}"; done
    printf -- '- {name: ctx, context: {cluster: k, user: %s}}\n' "$last"
    for p in "$@"; do [ "${p%%:*}" = "$last" ] || printf -- '- {name: c_%s, context: {cluster: k, user: %s}}\n' "${p%%:*}" "${p%%:*}"; done
    printf 'users:\n'
    for p in "$@"; do printf -- '- {name: %s, user: {token: %s}}\n' "${p%%:*}" "$(_jwt "${p#*:}")"; done
  } > "$f"
}
_past=1000000000            # 2001 — safely expired
_future=4102444800          # 2100 — safely valid

# ── 1. --minify: the CURRENT CONTEXT's token, not users[0] ──────────────────────────────────────
# MEASURED defect: users[0] was a live GUEST token while the current context's Supervisor token was
# dead, so a dead credential reported VALID. 11 of 11 other [0]-index reads in scripts/ minify.
_kc "$_T/multi" "guest:{\"exp\":$_future}" "supervisor:{\"exp\":$_past}"
case "$(kube_token_expiry "$_T/multi")" in
  EXPIRED*) ok  "multi-user: reads the CURRENT CONTEXT's token, not users[0]" ;;
  *)        bad "multi-user: read users[0] — a live guest token hides a DEAD Supervisor one (--minify missing?)" ;;
esac

# ── 2. MORE THAN ONE exp -> REFUSE, in EITHER order ─────────────────────────────────────────────
# Two measured defects, one after the other. First: no comma split, so a greedy .* took the LAST
# "exp" and a nested future claim made a dead token report VALID. The comma-split fix was then
# itself refuted: `head -1` is the first TEXTUAL match, NOT the top-level claim, so putting the
# nested claim FIRST reproduced the identical failure — and that order is realistic, because Go's
# encoding/json sorts map keys and act/amr/aud/azp/cnf all sort BEFORE exp.
# ⚠️ BOTH ORDERS ARE ASSERTED ON PURPOSE. The version that only tested the top-level-first order
# passed while the reversed order reported a DEAD TOKEN LIVE.
_kc "$_T/nest_a" "u:{\"exp\":$_past,\"aud_claims\":{\"exp\":$_future}}"
_kc "$_T/nest_b" "u:{\"aud_claims\":{\"exp\":$_future},\"exp\":$_past}"
_kc "$_T/nest_c" "u:{\"cnf\":{\"exp\":$_future},\"exp\":$_past}"
for _n in nest_a nest_b nest_c; do
  if [ "$(kube_token_expiry "$_T/$_n")" = UNKNOWN ]; then
    ok  "two exp claims ($_n): REFUSES rather than picking one"
  else
    bad "two exp claims ($_n): picked one — a nested future exp can mask a DEAD token"
  fi
done

# ── 2b. base64url really is decoded ─────────────────────────────────────────────────────────────
# MEASURED: deleting the ${pay//_//} / ${pay//-/+} substitutions left the suite 17/17 GREEN,
# because no other payload's base64 contains + or /. This one does (sub is "?\\>"), so the case
# dies if the replacement is ever "simplified" away.
_kc "$_T/b64url" "u:{\"sub\":\"?\\\\>\",\"exp\":$_past}"
case "$(kube_token_expiry "$_T/b64url")" in
  EXPIRED*) ok  "base64url with both - and _ decodes (pins the // substitutions)" ;;
  *)        bad "base64url with - and _ failed to decode — the // substitutions are gone?" ;;
esac

# ── 3. an exp the shell cannot compare must REFUSE, not guess ───────────────────────────────────
# MEASURED: bash `[` errors (rc=2) at NINETEEN digits, and `if` consumes that error as FALSE, so the
# value fell through to the VALID branch and rendered `VALID ?` — a test error stated as a verdict.
_kc "$_T/huge" 'u:{"exp":9223372036854775808}'
if [ "$(kube_token_expiry "$_T/huge")" = UNKNOWN ]; then
  ok  '19-digit exp: refuses to judge (a bracket-test error must not become a verdict)'
else
  bad '19-digit exp: judged it — the bracket test errors at 19 digits and the error is read as false'
fi

# ── 4. a wrong-UNIT epoch must REFUSE, not render a nonsense date as fact ───────────────────────
# MEASURED: 1757000000000000 rendered `VALID 55679083-07-23T03:33Z`.
for _u in 1757000000000 1757000000000000 1757000000000000000; do
  _kc "$_T/u$_u" "u:{\"exp\":$_u}"
  if [ "$(kube_token_expiry "$_T/u$_u")" = UNKNOWN ]; then
    ok  "epoch in the wrong unit ($_u): refuses"
  else
    bad "epoch in the wrong unit ($_u): rendered a date as fact"
  fi
done

# ── 5. the ordinary verdicts ────────────────────────────────────────────────────────────────────
_kc "$_T/exp" "u:{\"exp\":$_past}";   case "$(kube_token_expiry "$_T/exp")" in EXPIRED*) ok "past exp -> EXPIRED" ;; *) bad "past exp did not report EXPIRED" ;; esac
_kc "$_T/val" "u:{\"exp\":$_future}"; case "$(kube_token_expiry "$_T/val")" in VALID*)   ok "future exp -> VALID"  ;; *) bad "future exp did not report VALID"  ;; esac

# ── 6. degenerate inputs DEGRADE, never guess and never kill the caller ─────────────────────────
printf 'not a kubeconfig\n' > "$_T/junk"
: > "$_T/empty"
_kc "$_T/noexp" 'u:{"sub":"x"}'
printf 'apiVersion: v1\nkind: Config\nusers:\n- {name: u, user: {client-certificate-data: eA==}}\n' > "$_T/cert"
for _c in "$_T/junk::junk file" "$_T/empty::empty file" "$_T/noexp::no exp claim" "$_T/cert::client-cert (no token)" "/nope/nope::missing file" "::empty arg"; do
  _f="${_c%%::*}"; _d="${_c##*::}"
  if [ "$(kube_token_expiry "$_f")" = UNKNOWN ]; then ok "$_d -> UNKNOWN"; else bad "$_d did not degrade to UNKNOWN"; fi
done
if [ "$(kube_token_expiry)" = UNKNOWN ]; then ok "no argument -> UNKNOWN"; else bad "no argument did not degrade"; fi

# ── 7. it must not kill a `set -e` caller ───────────────────────────────────────────────────────
# The call sites wrap it in `|| printf 'UNKNOWN'`; this pins that the function itself is survivable.
if bash -c 'set -euo pipefail; . scripts/lib/os.sh 2>/dev/null; v="$(kube_token_expiry /nope 2>/dev/null || printf UNKNOWN)"; [ -n "$v" ]' 2>/dev/null; then
  ok "does not kill a set -euo pipefail caller"
else
  bad "killed a set -euo pipefail caller"
fi

# ── 8. NO `tr` — photon:5.0 ships none, and this runs on the air-gap box ────────────────────────
# MEASURED: bare photon:5.0 has base64/date/sed/head/cut and NO tr, and 00-install-prereqs.sh (which
# says so verbatim) is internet-side only, so the air-gap box never runs it.
if grep -nE "^[^#]*\btr\b" <(sed -n '/^kube_token_expiry() {/,/^}/p' scripts/lib/os.sh) >/dev/null 2>&1; then
  bad "kube_token_expiry uses \`tr\` — INERT on a bare photon:5.0 air-gap box"
else
  ok "uses no \`tr\` (works on a box without coreutils)"
fi

printf '\n  %s passed, %s failed\n' "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || { echo "kube-token-expiry FAILED"; exit 1; }
echo "SUCCESS — kube_token_expiry refuses to guess, and cannot report a dead token as live"
