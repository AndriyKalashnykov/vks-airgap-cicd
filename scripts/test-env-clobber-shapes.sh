#!/usr/bin/env bash
# ci-tier: fast — offline; throwaway REPO_ROOTs under mktemp, no network, no cluster.
#
# test-env-clobber-shapes.sh — PIN THE BOOLEAN-TOGGLE ARM'S REGEX, because on the current tree the
# widening that added these shapes is INERT and therefore UNDETECTABLE if reverted.
#
# MEASURED: the five newly-caught shapes occur ZERO times in `scripts/` + `Makefile` today, and the
# old and new patterns match the SAME 19 variables across all 235 names in `.env.example`. So the
# widening changes nothing observable, no other test drives it, and `test-gate-vacuity.sh` only
# STARVES this gate rather than exercising its arms. Its only evidence was a hand-run recorded in a
# commit message — and this repo's own doctrine is that a RED-proof which is not committed as a
# runnable case EXPIRES at the next commit touching the gate or its toolchain. This file is that
# case.
#
# WHY IT RUNS THE REAL GATE rather than re-implementing the pattern: a test that re-types the regex
# passes when the gate's copy rots, which is the defect it exists to catch. It plants one probe
# script per shape in a throwaway REPO_ROOT and runs `check-env-clobber.sh` end to end.
#
# ⚠️ THE NEGATIVE CONTROL IS THE POINT, not padding. Every shape below is a `${V:-<literal>}`, and
# the arm deliberately fires only on a BOOLEAN literal — an ordinary `${V:-30}` is the NORMAL way to
# write a default and flagging it measured 97% false-RED when tried. A widening that also caught
# `${V:-30}` would pass every positive case here and make the gate unusable.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# Plant ONE probe script whose only content is a read of X_PROBE in the given shape, plus an
# uncommented X_PROBE in .env.example, then run the real gate. rc!=0 == the arm fired.
shape_fires() {  # $1 = the ${...} body, e.g. 'X_PROBE:-0'
  local T rc; T="$(mktemp -d)"
  cp .env.example "$T/.env.example" 2>/dev/null || { rm -rf "$T"; return 2; }
  cp Makefile "$T/Makefile" 2>/dev/null
  cp -r scripts "$T/scripts"
  printf 'X_PROBE=0\n' >> "$T/.env.example"
  # shellcheck disable=SC2016  # the ${...} is being WRITTEN INTO the probe file for the gate to
  # read; expanding it here would plant the empty string and every case would go vacuously green.
  printf '#!/usr/bin/env bash\nv="${%s}"\necho "$v"\n' "$1" > "$T/scripts/zz-probe.sh"
  ( cd "$T" && REPO_ROOT="$T" ./scripts/check-env-clobber.sh >/dev/null 2>&1 ); rc=$?
  rm -rf "$T"
  return "$rc"
}

# ── The shapes that MUST fire. `${V:-0}` is the original; the other four are the widening. ────────
for shape in 'X_PROBE:-0' 'X_PROBE-0' 'X_PROBE:-"0"' "X_PROBE:-'1'" 'X_PROBE-true'; do
  if shape_fires "$shape"; then
    bad "\${${shape}} was NOT flagged. An uncommented boolean toggle in .env.example silently
        defeats the code's own default, and this is the arm that catches it.
        \${V:-0} is the original shape; \${V-0} (no colon) and the quoted forms were added after an
        adversary measured them MISSED — if one of THOSE regressed, the widening has been reverted."
  else
    ok "\${${shape}} is flagged"
  fi
done

# ── THE NEGATIVE CONTROL: an ordinary non-boolean default must stay quiet. ────────────────────────
if shape_fires 'X_PROBE:-30'; then
  ok "\${X_PROBE:-30} is correctly IGNORED (a plain default is the normal shape, not a defect)"
else
  bad "\${X_PROBE:-30} was FLAGGED. The arm has been widened past boolean literals; measured at 97%
        false-RED when that was tried, because \${V:-<literal>} is how every ordinary default is
        written. A gate that fires on all of them gets switched off."
fi

# ── And the arm must still be REACHED on the real file: a green here with a broken gate would be
# indistinguishable from a green here with a working one. ─────────────────────────────────────────
if REPO_ROOT="$PWD" ./scripts/check-env-clobber.sh >/dev/null 2>&1; then
  ok "the real .env.example is still clean under the widened arm (0 false-RED)"
else
  bad "the widened arm now FIRES on the committed .env.example. Either a real clobber was
        introduced, or the widening caught a shape that is legitimately in use — read the gate's
        output before loosening anything."
fi

[ "$fail" -eq 0 ] || exit 1
printf 'SUCCESS — five toggle shapes flagged, a plain numeric default ignored, real file clean.\n'
