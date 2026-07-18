#!/usr/bin/env bash
# test-psa-defaults.sh — the RED-proof for check-psa-defaults.sh.
#
# A gate's value is its demonstrated RED, never its observed green. Every case below was a REAL
# defect in an earlier draft of that gate, found by an adversary round that RAN it — not by reading
# it. Three of them were CRITICAL and two of those produced a VACUOUS GREEN, which is the failure
# mode this whole file exists to make impossible to reintroduce.
#
# METHOD: mutate a SANDBOX COPY, never the real tree. The gate resolves REPO_ROOT from its own
# location, so copying scripts/ + .env.example into a temp dir and running the copy makes that temp
# dir the repo — no `git checkout --` restore (which destroys uncommitted work), no risk to the tree.
#
# shellcheck shell=bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0; ran=0
ok()  { printf 'ok    %s\n' "$1"; ran=$((ran + 1)); }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# THE TOKENS THIS TEST PLANTS ARE COMPOSED AT RUNTIME, NEVER WRITTEN LITERALLY, and that is
# load-bearing. The gate scans all of scripts/ — including this file. A first draft spelled the
# mutation strings out, so the gate matched THIS FILE's literals and every case failed for the wrong
# reason: exactly the "a gate in the tree it scans sees its own prose" defect these cases exist to
# prove. The reflex fix — exclude this file by name — is refused deliberately: it would hide any
# REAL fallback that ever appears here. Instead, `%s` breaks the gate's key charclass
# ([A-Za-z0-9_]+ cannot match `%`), so these format strings are invisible to it while producing the
# genuine form at runtime.
# shellcheck disable=SC2016  # the $ is LITERAL and the single quotes are the point: these are
# printf FORMAT strings that must emit the source text `${PSA_LEVEL_<KEY>:-<level>}`, not expand it.
tok()  { printf '${PSA_LEVEL_%s:-%s}' "$1" "$2"; }   # a fallback reference
# shellcheck disable=SC2016  # ditto — emits the assign-if-unset form this test plants deliberately.
atok() { printf '${PSA_LEVEL_%s:=%s}' "$1" "$2"; }   # an assign-if-unset (the REFUTED design)

# Literal, non-regex replacement — the tokens contain ${ } : - which sed would mangle.
sub() { python3 - "$1" "$2" "$3" "${4:-1}" <<'PY'
import sys
path, old, new, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
s = open(path, encoding="utf-8").read()
if old not in s:
    sys.exit("test-psa-defaults: mutation target not found in %s: %r" % (path, old))
open(path, "w", encoding="utf-8").write(s.replace(old, new, count))
PY
}
append() { printf '%s\n' "$2" >> "$1"; }

# A pristine sandbox per case: the gate under test plus everything it reads.
fresh() {
  rm -rf "${SB:?}/repo"; mkdir -p "$SB/repo"
  cp -a "${REPO_ROOT}/scripts" "$SB/repo/scripts"
  cp -a "${REPO_ROOT}/.env.example" "$SB/repo/.env.example"
}
run_gate() { ( cd "$SB/repo" && bash scripts/check-psa-defaults.sh >"$SB/out" 2>&1 ); }

# expect_red <name> <substring the diagnostic MUST contain>
expect_red() {
  local name="$1" want="$2"
  if run_gate; then
    bad "$name — gate returned 0 (a VACUOUS GREEN: it did not see the defect)"
    return
  fi
  if ! grep -qF "$want" "$SB/out"; then
    bad "$name — gate went red, but for the WRONG reason (no '${want}' in its output)"
    sed 's/^/        /' "$SB/out" >&2
    return
  fi
  ok "$name"
}

# --- 0. the baseline: GREEN on the real tree ------------------------------------------------------
# If this fails, every RED below is meaningless — a gate that is red on a clean tree gets deleted.
fresh
if run_gate; then ok "clean tree is GREEN (an earlier draft was RED on day one, because it matched its own die message)"
else bad "clean tree is RED — the gate cannot be wired into static-check"; sed 's/^/        /' "$SB/out" >&2; fi

# --- 1. CRITICAL: value drift ---------------------------------------------------------------------
fresh
sed -i 's/^PSA_LEVEL_CI=baseline/PSA_LEVEL_CI=privileged/' "$SB/repo/.env.example"
expect_red "value drift: .env.example says privileged, scripts fall back to baseline" "documents 'privileged'"

# --- 2. CRITICAL: an INVALID fallback level -------------------------------------------------------
# The measured vacuous green in the earlier draft: its regex was [a-z]+ only, so a capitalised level
# was DROPPED from side A entirely, the other 5 tekton sites still agreed, and a namespace that would
# die at runtime shipped green. The only signal was a denominator nobody reads.
fresh
sub "$SB/repo/scripts/41-install-tekton.sh" "$(tok TEKTON restricted)" "$(tok TEKTON Privileged)"
expect_red "invalid level 'Privileged' (capitalised) is FLAGGED, not silently dropped" "is not one of"

# --- 3. CRITICAL: a key containing a DIGIT is visible ---------------------------------------------
# The earlier draft's key charclass was [A-Z_]+, so a digit made a NEW key invisible — reproducing
# the very "a new key hides from the gate" class the gate exists to close.
fresh
sub "$SB/repo/scripts/41-install-tekton.sh" "$(tok TEKTON restricted)" "$(tok TEKTON2 restricted)"
expect_red "a key with a DIGIT (PSA_LEVEL_TEKTON2) is seen and reported undocumented" "TEKTON2"

# --- 4. HIGH: a duplicate declaration in .env.example ---------------------------------------------
# load_env sources with `set -a`, so the LAST wins. The earlier draft compared the alphabetically
# first value and certified a level that would not run.
fresh
printf 'PSA_LEVEL_CI=privileged\n' >> "$SB/repo/.env.example"
expect_red "duplicate declaration is flagged (set -a means the LAST one wins)" "declared MORE THAN ONCE"

# --- 5. HIGH: an EMPTY documented value ------------------------------------------------------------
# The earlier draft's whitespace-delimited records collapsed here and it reported the LINE NUMBER as
# the level ("documents '584'"). The message must name the real condition.
fresh
sed -i 's/^PSA_LEVEL_CI=baseline/PSA_LEVEL_CI=/' "$SB/repo/.env.example"
expect_red "empty documented value gives a COHERENT diagnostic, not a line number as a level" "EMPTY value"

# --- 6. key used in scripts/ but not documented ----------------------------------------------------
fresh
sed -i '/^PSA_LEVEL_TRAEFIK=/d' "$SB/repo/.env.example"
expect_red "key used in scripts/ but not documented in .env.example" "NOT documented"

# --- 7. key documented but unused ------------------------------------------------------------------
fresh
printf 'PSA_LEVEL_ORPHAN=restricted\n' >> "$SB/repo/.env.example"
expect_red "key documented but no script falls back to it" "no script falls back"

# --- 8. two use sites disagreeing about the same key ------------------------------------------------
fresh
sub "$SB/repo/scripts/41-install-tekton.sh" "$(tok TEKTON restricted)" "$(tok TEKTON baseline)"
expect_red "two use sites claiming different defaults for one key" "DISAGREE"

# --- 9. the RECONCILIATION backstop: the REFUTED design creeping back --------------------------------
# An assign-if-unset in lib/psa.sh is the design two adversary rounds refuted. It is not a fallback,
# so no other check would see it; only the denominator reconciliation catches it.
fresh
append "$SB/repo/scripts/lib/psa.sh" ": \"$(atok CI baseline)\""
expect_red "an assign-if-unset (the REFUTED design) is caught by reconciliation" "accounted for"

# --- 10. the gate must not match ITSELF --------------------------------------------------------------
# Layer three of the self-scan defence. If a future edit puts a matchable fallback back into the
# gate's own prose, its docstring starts VOTING on values: an earlier draft stayed green after the
# only real CI use site was deleted, because its own comment stood in for the deleted code.
fresh
append "$SB/repo/scripts/check-psa-defaults.sh" "# example: $(tok CI baseline)"
expect_red "a matchable fallback in the gate's OWN source is caught by the self-test" "OWN source"

# --- 11. the vacuous-green case that motivated case 10 ------------------------------------------------
# Delete the ONE real CI use site. With the gate's prose clean, CI must vanish from side A and be
# reported as documented-but-unused. The earlier draft passed this, because its comment supplied CI.
fresh
sub "$SB/repo/scripts/60-configure-tekton.sh" "$(tok CI baseline)" '"baseline"'
expect_red "deleting the only real CI use site is DETECTED (no docstring stands in for it)" "no script falls back"

# --- verdict ------------------------------------------------------------------------------------------
# Fail-check FIRST: `ran` counts only PASSING cases, so if every case failed, ran==0 AND fail==1 —
# checking the skip first would exit 0 on a run that printed nothing but FAIL.
if [ "$fail" -ne 0 ]; then echo "test-psa-defaults: FAILED" >&2; exit 1; fi
[ "$ran" -gt 0 ] || { echo "test-psa-defaults: no case ran — the harness is broken, not the gate" >&2; exit 1; }
echo "test-psa-defaults: OK (${ran} case(s))"
