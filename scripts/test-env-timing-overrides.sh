#!/usr/bin/env bash
# test-env-timing-overrides.sh — a timing knob must be reachable FROM THE COMMAND LINE.
#
# NO ci-tier MARKER, deliberately: Makefile:1079 builds TEST_ALL from a wildcard and tiers from
# this marker, so an unmarked file lands in TEST_FAST and runs on every code PR — which is where
# this belongs. PRs run `static-check-pr` -> `test-scripts-fast`, NOT `test-scripts`, so a
# `slow` marker would demote it to the weekly run. Measured cost: ~10ms per probe.
#
# WHAT IT GUARDS (B122). `load_env` sources .env.example with `set -a` AFTER the caller's
# environment, so an UNCOMMENTED value there is exported and BEATS the code's ${VAR:-default}.
# The knob then looks settable, is documented as settable, and is inert. It was true of 14 keys.
#
# ⚠️ THE FALSE GREEN THIS TEST IS BUILT TO AVOID, measured before writing it. The obvious probe --
# export K=99999, run load_env, assert K is still 99999 -- PASSES WHEN load_env NEVER RUNS:
#
#     env POLL_INTERVAL_SECONDS=99999 bash -c 'printf "%s" "${POLL_INTERVAL_SECONDS:-UNSET}"'
#       -> 99999            (no load_env anywhere; a test asserting 99999 would pass)
#
# The probe exports the value itself, so a renamed load_env, a moved lib/os.sh or a dropped `.`
# line is INDISTINGUISHABLE from a working one, and the regression test goes green forever.
# Check 1 below is the discriminator and it must run FIRST.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }

# The name-shaped predicate. It is the one that FOUND the 14th key (BUILDER_PROBE_TIMEOUT), which
# lives outside section 8 and which any section-scoped or hand-typed list structurally cannot see.
# Deliberately NOT "every uncommented key": 55 of 57 are clobbered, so that predicate is 55 false
# positives and unusable. Deliberately NOT "keys carrying an acquisition marker": measured vacuous
# (0 on main AND 0 on the branch), so it has no RED for this class at all.
TIMING_RE='^[A-Z_]*(TIMEOUT|WAIT|INTERVAL|RETRIES|MAX_TIME|SECONDS)[A-Z_]*='

# ISOLATION. SKIP_DOTENV=1 skips ONLY .env. The state overlay (state_file() -> .env.state) and the
# legacy .env.kind are still sourced under `set -a` AFTERWARDS, so on any box that has run an
# install a leftover overlay value wins and this test goes RED for a reason unrelated to the
# defect. A test that reds on operator state gets weakened or deleted, so pin the overlay away.
ISO_STATE="$(mktemp -u)/definitely-not-here"

# effective <KEY> [OVERRIDE] — the value the code would see, through the REAL load_env.
# Reads with `-` (unset-only), never `:-`, so an EMPTY value is distinguishable from an unset one.
effective() {
  local k="$1" ov="${2-}"
  if [ -n "$ov" ]; then
    env "$k=$ov" SKIP_DOTENV=1 VKS_STATE_FILE="$ISO_STATE" \
      bash -c ". '${REPO_ROOT}/scripts/lib/os.sh' >/dev/null 2>&1; load_env >/dev/null 2>&1; printf '%s' \"\${$k-NOTSET}\"" 2>/dev/null
  else
    env SKIP_DOTENV=1 VKS_STATE_FILE="$ISO_STATE" \
      bash -c ". '${REPO_ROOT}/scripts/lib/os.sh' >/dev/null 2>&1; load_env >/dev/null 2>&1; printf '%s' \"\${$k-NOTSET}\"" 2>/dev/null
  fi
}

echo "== 1. LIVENESS — did load_env actually run? (every check below is vacuous if not) =="
# DERIVED from the file's first uncommented key, so it cannot rot when that key is renamed.
SENTINEL="$(grep -oE '^[A-Z_][A-Z0-9_]*=' "$ENV_EXAMPLE" | head -1 | tr -d '=')"
if [ -z "$SENTINEL" ]; then
  bad "no uncommented key in .env.example to use as a liveness sentinel — cannot prove load_env ran"
else
  sv="$(effective "$SENTINEL")"
  if [ "$sv" = NOTSET ] || [ -z "$sv" ]; then
    bad "load_env did NOT deliver \$$SENTINEL — it never ran, so nothing below means anything"
  else
    ok "load_env ran (\$$SENTINEL arrived as '$sv')"
  fi
fi

echo "== 2. DERIVED — no timing-shaped key may be UNCOMMENTED in .env.example =="
# A count, not a list: a 15th key added uncommented next month is caught with no edit here.
uncommented="$(grep -nE "$TIMING_RE" "$ENV_EXAMPLE" || true)"
n_unc="$(printf '%s' "$uncommented" | grep -c . || true)"
if [ "${n_unc:-0}" -eq 0 ]; then
  ok "0 uncommented timing-shaped keys"
else
  bad "$n_unc uncommented timing-shaped key(s) — each is INERT from the command line:"
  printf '%s\n' "$uncommented" | sed 's/^/         /'
fi

echo "== 3. BEHAVIOURAL — every COMMENTED timing key's override must survive load_env =="
# Also derived: the commented form of the same predicate. This is what actually proves the
# mechanism, rather than proving the file's punctuation.
keys="$(grep -oE "^#[[:space:]]*[A-Z_]*(TIMEOUT|WAIT|INTERVAL|RETRIES|MAX_TIME|SECONDS)[A-Z_]*=" "$ENV_EXAMPLE" \
        | sed -E 's/^#[[:space:]]*//; s/=$//' | sort -u)"
n_keys="$(printf '%s' "$keys" | grep -c . || true)"
if [ "${n_keys:-0}" -eq 0 ]; then
  bad "found NO commented timing keys — the predicate has gone blind; do not read the ok's below as coverage"
else
  ok "probing $n_keys commented timing key(s)"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    got="$(effective "$k" 99999)"
    [ "$got" = 99999 ] && continue
    bad "\$$k override was CLOBBERED -> '$got' (uncommented in .env.example?)"
  done <<< "$keys"
  [ "$FAIL" -eq 0 ] && ok "all $n_keys survived a command-line override"
fi

echo
printf 'test-env-timing-overrides: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
