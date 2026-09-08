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

# ── 2. the FIRST exp claim, not the last ────────────────────────────────────────────────────────
# MEASURED defect: the payload is one line, so a greedy .* took the LAST "exp" — a nested claim
# turned an expired token into a valid one.
_kc "$_T/nested" "u:{\"exp\":$_past,\"aud_claims\":{\"exp\":$_future}}"
case "$(kube_token_expiry "$_T/nested")" in
  EXPIRED*) ok  "nested exp: takes the FIRST claim, so a nested future exp cannot mask a dead token" ;;
  *)        bad "nested exp: took the LAST claim — a DEAD token reports VALID (comma split missing?)" ;;
esac

# ── 3. an exp the shell cannot compare must REFUSE, not guess ───────────────────────────────────
# MEASURED: bash `[` errors (rc=2) at NINETEEN digits, and `if` consumes that error as FALSE, so the
# value fell through to the VALID branch and rendered `VALID ?` — a test error stated as a verdict.
_kc "$_T/huge" 'u:{"exp":9223372036854775808}'
[ "$(kube_token_expiry "$_T/huge")" = UNKNOWN ] \
  && ok  '19-digit exp: refuses to judge (a bracket-test error must not become a verdict)' \
  || bad "19-digit exp: judged it — `[` errors at 19 digits and the error is read as false"

# ── 4. a wrong-UNIT epoch must REFUSE, not render a nonsense date as fact ───────────────────────
# MEASURED: 1757000000000000 rendered `VALID 55679083-07-23T03:33Z`.
for _u in 1757000000000 1757000000000000 1757000000000000000; do
  [ "$(kube_token_expiry "$(_kc "$_T/u$_u" "u:{\"exp\":$_u}"; echo "$_T/u$_u")")" = UNKNOWN ] \
    && ok  "epoch in the wrong unit ($_u): refuses" \
    || bad "epoch in the wrong unit ($_u): rendered a date as fact"
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
  [ "$(kube_token_expiry "$_f")" = UNKNOWN ] && ok "$_d -> UNKNOWN" || bad "$_d did not degrade to UNKNOWN"
done
[ "$(kube_token_expiry)" = UNKNOWN ] && ok "no argument -> UNKNOWN" || bad "no argument did not degrade"

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
