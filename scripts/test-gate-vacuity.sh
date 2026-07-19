#!/usr/bin/env bash
# test-gate-vacuity.sh — a gate that judged NOTHING must not report OK.
#
# WHY THIS EXISTS (B39/B49):
#   A gate can be green because it is satisfied, or green because it never looked. Those are
#   indistinguishable from the outside, and this repo has now shipped BOTH failures:
#     * check-doc-novels and check-doc-robot-quoting each reported `OK — scanned N` with rc=0 over a
#       corpus of EMPTY files. Their zero-guards counted FILES OPENED, which stayed healthy, while the
#       ITEM count that carries the verdict was zero. (Fixed; both are cases below.)
#   The obvious fix — a meta-gate that statically asserts "every check-*.sh prints a denominator and
#   dies on zero" — was BUILT AND MEASURED AT 67% ACCURACY (wrong about 7 of 21 gates, in both
#   directions) and is REFUTED. It cannot see the distinction that matters, because "is the guard on
#   the ITEM count or the FILE count" is semantic. So this harness does not read the gates. It STARVES
#   them and looks at what they do.
#
# THE METHOD: empty a gate's declared corpus in a throwaway `git archive` copy, run the gate there,
# and require rc != 0. It cannot be satisfied by `echo "checked 1"`, and it needs no model of how the
# gate is written.
#
# THE RESIDUAL, STATED NOT HIDDEN: the per-gate corpus declaration below is an ENUMERATED LIST, and
# enumerated lists rot. A WRONG declaration makes a starvation vacuous — the same failure class this
# harness exists to catch, one level up. Two mitigations, both partial: the self-check below proves
# the harness can still tell blind from healthy, and the coverage denominator is PRINTED so the gates
# nobody has declared a corpus for are visible rather than silently implied.
#
# shellcheck shell=bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0; ran=0
ok()  { printf 'ok    %s\n' "$1"; ran=$((ran + 1)); }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT

# A pristine throwaway checkout, re-inited as a git repo because several gates drive off `git ls-files`.
# `git archive HEAD` for the corpus, then the WORKING TREE's scripts/ overlaid on top. The overlay is
# load-bearing and was missing in the first draft: without it this harness tests the COMMITTED gates,
# so a fix you have not committed yet is invisible and the harness reports your just-fixed gate as
# still vacuous. (It did exactly that, quoting the pre-fix message — the same "measuring the wrong
# artifact" class this file exists to catch.)
fresh() {
  rm -rf "${SB:?}/repo"; mkdir -p "$SB/repo"
  git archive HEAD | tar -x -C "$SB/repo"
  cp -a "${REPO_ROOT}/scripts/." "$SB/repo/scripts/"
  ( cd "$SB/repo" && git init -q . && git add -A >/dev/null 2>&1 \
      && git -c user.email=t@t -c user.name=t commit -qm starve >/dev/null 2>&1 )
}

# starve <pathspec...> — empty every tracked file matching, leaving it TRACKED. Emptying rather than
# deleting is deliberate: deletion is the easy case (most gates notice a missing file), while an empty
# file keeps every file-count healthy and is exactly the state that fooled two gates.
starve() { ( cd "$SB/repo" && git ls-files "$@" | while read -r f; do : > "$f"; done ); }

# assert_starved <gate> <label> <pathspec...>
assert_starved() {
  local gate="$1" label="$2"; shift 2
  fresh
  # Exit status read DIRECTLY off each run, never via a later `$?` — the house rule, and the reason
  # is that `$?` silently becomes the status of whatever ran most recently.
  if ! ( cd "$SB/repo" && bash "scripts/${gate}" ) >"$SB/base.log" 2>&1; then
    bad "${label} — the gate is RED on an UNSTARVED corpus, so this case proves nothing about vacuity"
    sed 's/^/        /' "$SB/base.log" >&2
    return
  fi
  starve "$@"
  if ( cd "$SB/repo" && bash "scripts/${gate}" ) >"$SB/starved.log" 2>&1; then
    bad "${label} — VACUOUS: green with an EMPTY corpus. It reported:"
    tail -2 "$SB/starved.log" | sed 's/^/        /' >&2
    return
  fi
  ok "${label}"
}

# --- THE HARNESS'S OWN KNOWN ANSWER --------------------------------------------------------------
# Non-circular by construction: two fixtures whose verdict is known WITHOUT reference to any real
# gate. If the harness cannot tell these apart it is broken, and every result below is worthless.
# (Contrast B37, where the fixture had to encode my own model of the defect — that is what made it
# circular and unbuildable.)
selfcheck() {
  fresh
  cat > "$SB/repo/scripts/_vac-blind.sh" <<'BLIND'
#!/usr/bin/env bash
# BLIND ON PURPOSE: guards the FILE count, which stays healthy when the files are empty.
set -uo pipefail
n=$(git ls-files '*.md' | wc -l)
[ "$n" -gt 0 ] || { echo "scanned 0"; exit 1; }
echo "OK — scanned $n doc(s)"
BLIND
  cat > "$SB/repo/scripts/_vac-good.sh" <<'GOOD'
#!/usr/bin/env bash
# HEALTHY ON PURPOSE: guards the ITEM count (bytes actually read).
set -uo pipefail
items=0
while read -r f; do items=$(( items + $(wc -c < "$f") )); done < <(git ls-files '*.md')
[ "$items" -gt 0 ] || { echo "examined 0 items"; exit 1; }
echo "OK — examined $items byte(s)"
GOOD
  chmod +x "$SB/repo/scripts/_vac-blind.sh" "$SB/repo/scripts/_vac-good.sh"
  starve '*.md'
  ( cd "$SB/repo" && bash scripts/_vac-blind.sh ) >/dev/null 2>&1
  local blind_rc=$?
  ( cd "$SB/repo" && bash scripts/_vac-good.sh ) >/dev/null 2>&1
  local good_rc=$?
  if [ "$blind_rc" -eq 0 ] && [ "$good_rc" -ne 0 ]; then
    ok "SELF-CHECK: the harness distinguishes a BLIND gate (green on empty) from a HEALTHY one (red)"
  else
    bad "SELF-CHECK BROKEN — blind_rc=${blind_rc} (want 0), good_rc=${good_rc} (want non-zero). Every result below is meaningless until this passes."
  fi
}

selfcheck

# --- DECLARED CORPORA ------------------------------------------------------------------------------
# Only gates whose corpus is confidently known are listed. The coverage denominator is printed at the
# end so the REST are visible as an admitted gap rather than an implied pass.
assert_starved check-doc-novels.sh        "check-doc-novels dies on an empty doc corpus"        '*.md'
assert_starved check-doc-robot-quoting.sh "check-doc-robot-quoting dies on an empty corpus"     '*.md' '.env.example'
assert_starved check-vks-provenance.sh    "check-vks-provenance dies with no fact rows"         'docs/vks-services/*.md'
# NOTE the pathspec here is `.env.example` ONLY, not `scripts/*.sh`. Starving the scripts would empty
# check-psa-defaults.sh ITSELF — bash then runs an empty file and exits 0, which this harness would
# report as "VACUOUS" when in truth the gate never ran. A starvation whose blast radius includes the
# gate under test measures nothing; when a gate's corpus overlaps its own source, starve the OTHER side.
assert_starved check-psa-defaults.sh      "check-psa-defaults dies with nothing documented"     '.env.example'

DECLARED=4
TOTAL=$(find "${REPO_ROOT}/scripts" -maxdepth 1 -name 'check-*.sh' | wc -l)

# Fail-check FIRST: `ran` counts only PASSING cases, so if everything failed, ran==0 AND fail==1 —
# checking a "nothing ran" skip first would exit 0 on a run that printed nothing but FAIL.
if [ "$fail" -ne 0 ]; then echo "test-gate-vacuity: FAILED" >&2; exit 1; fi
[ "$ran" -gt 0 ] || { echo "test-gate-vacuity: no case ran — the harness is broken, not the gates" >&2; exit 1; }
echo "test-gate-vacuity: OK (${ran} case(s); starvation declared for ${DECLARED} of ${TOTAL} check-*.sh — the rest are UNAUDITED for vacuity, not proven healthy)"
