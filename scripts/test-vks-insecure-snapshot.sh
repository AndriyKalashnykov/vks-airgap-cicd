#!/usr/bin/env bash
# ci-tier: fast
#
# `VKS_INSECURE_SKIP_TLS_VERIFY` is SNAPSHOT-PROTECTED by `load_env`, and deliberately NOT more.
#
# WHY THIS EXISTS. The toggle skips TLS verification of the Supervisor on a connection that submits
# a credential — `30-vks-login.sh:271` says so in its own words. It is read at THREE sites, not two:
# `30-vks-login.sh:275` (vcf arm), `30-vks-login.sh:473` (vsphere arm, via `bool_word`), and
# `31-fetch-argocd-kubeconfig.sh:96`. Before this change none of them was protected, so a value in a
# personal `.env` beat a per-run override — a RATCHET, because `load_env` sources `.env.example` then
# `.env` with `set -a` AFTER the caller's environment.
#
# That ratchet made a DOCUMENTED PROMISE FALSE. `.env.example:1209-1210` says, verbatim: "Commented
# so the code default (false) applies and a `make vks-login VKS_INSECURE_SKIP_TLS_VERIFY=1` / `.env`
# override is not clobbered." Measured before the fix: caller `=0` with `.env=true` resolved to
# **true** — the override WAS clobbered, and there was no per-run way back.
#
# ⚠️ ARM 2 IS THE POINT OF THIS FILE, AND IT ASSERTS A NON-FIX. Threat (B) — caller silent, `.env`
# arms it — stays OPEN **on purpose**, because for THIS variable `.env` is the documented, invited
# channel in three places: `.env.example:1209`, `docs/vks-authentication.md:23`+`:35` (a table column
# headed "Inputs (`.env`)"), and `docs/lab-validation-plan.md:268`. Closing (B) would convert
# documented configuration into a FATAL and re-create the exact bug `scripts/lib/os.sh:139-146`
# records as ALREADY FIXED ("an operator who set the value THE REPO DOCUMENTS hit the die below
# demanding the value they had just set"). So a future change that makes arm 2 resolve to empty is a
# REGRESSION, not an improvement, and this arm exists to fail it. Reclassifying the variable as
# prefix-only is an OWNER POLICY DECISION that must move all four documents in the same commit — see
# backlog B196.
#
# This replays `load_env`'s ordering in a throwaway REPO_ROOT. The real `.env` is never read/written.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# $1 = caller's value ('' = caller sets nothing); $2 = line for the throwaway .env ('' = no .env)
probe() {
  local T; T="$(mktemp -d)"
  cp .env.example "$T/.env.example" 2>/dev/null || { rm -rf "$T"; printf 'NOENV'; return; }
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$T/.env"
  cp -r scripts "$T/scripts"
  ( cd "$T" || exit 1
    [ -n "${1:-}" ] && export VKS_INSECURE_SKIP_TLS_VERIFY="$1"
    # shellcheck source=/dev/null
    . scripts/lib/os.sh >/dev/null 2>&1
    load_env >/dev/null 2>&1
    printf '%s' "${VKS_INSECURE_SKIP_TLS_VERIFY:-<empty>}" )
  rm -rf "$T"
}

got="$(probe 0 'VKS_INSECURE_SKIP_TLS_VERIFY=true')"
if [ "$got" = 0 ]; then
  ok "caller=0 + .env=true -> 0 (the RATCHET is broken; .env.example:1209's promise now holds)"
else
  bad "caller=0 with .env=true must resolve 0, got '${got}'.
        .env.example:1209 promises a per-run override 'is not clobbered'. Before the snapshot it
        resolved 'true' and there was no way back — the documented promise was false."
fi

got="$(probe 1 '')"
if [ "$got" = 1 ]; then
  ok "no .env + caller=1 -> 1 (the documented prefix form works)"
else
  bad "the documented 'make vks-login VKS_INSECURE_SKIP_TLS_VERIFY=1' form must arm it, got '${got}'"
fi

# ⚠️ ARM 3 ASSERTS A DELIBERATE NON-CLOSURE — read the header before "fixing" it.
got="$(probe '' 'VKS_INSECURE_SKIP_TLS_VERIFY=true')"
if [ "$got" = true ]; then
  ok "caller silent + .env=true -> true (threat B stays OPEN — .env is the DOCUMENTED channel)"
else
  bad "a .env value must still configure this, got '${got}'.
        .env is documented as an input in three places (.env.example:1209,
        docs/vks-authentication.md:23+35, docs/lab-validation-plan.md:268). Making it inert converts
        documented config into a FATAL and re-creates the bug lib/os.sh:139-146 calls already fixed.
        If that reclassification is genuinely wanted it is an OWNER DECISION and must move all four
        documents in the same commit — see B196."
fi

got="$(probe '' '')"
if [ "$got" = '<empty>' ]; then
  ok "nothing set anywhere -> unset (secure default; is_true '' is false)"
else
  bad "the default must be unset, got '${got}'.
        Snapshot with \${V:-}, never \${V:-0} — a '0' makes the value SET where it is currently
        UNSET, changing any future [ -n ... ] read at the three call sites."
fi

# ARM 5 BINDS THIS TO THE REAL FILES. Arms 1-4 replay load_env's ordering through the real lib, but
# the drift that actually breaks this is the NAME leaving one of the two lists. They must move
# TOGETHER: check-env-clobber.sh:105 sed-derives PROTECTED from load_env and asserts
# PROTECTED subset-of SELECTORS, so adding to os.sh alone gives
# "FATAL: SELECTORS has FALLEN BEHIND" (measured, B188-F1).
V=VKS_INSECURE_SKIP_TLS_VERIFY
in_snap=$(sed -n 's/^[[:space:]]*for _sel in \(.*\); do$/\1/p' scripts/lib/os.sh | head -1 | tr ' ' '\n' | grep -cx "$V" || true)
in_sel=$(sed -n "s/^SELECTORS='\(.*\)'$/\1/p" scripts/check-env-clobber.sh | head -1 | tr '|' '\n' | grep -cx "$V" || true)
if [ "${in_snap:-0}" -eq 1 ] && [ "${in_sel:-0}" -eq 1 ]; then
  ok "$V is in BOTH load_env's snapshot list and check-env-clobber's SELECTORS"
else
  bad "$V must be in BOTH lists (snapshot=${in_snap:-0} SELECTORS=${in_sel:-0}).
        They are coupled: PROTECTED is sed-derived from load_env and must be a SUBSET of SELECTORS,
        so removing it from SELECTORS alone makes check-env-clobber FATAL, and removing it from
        os.sh alone silently restores the ratchet arms 1-4 exist to catch."
fi

[ "$fail" -eq 0 ] && printf 'test-vks-insecure-snapshot: ALL PASS (5)\n'
exit "$fail"
