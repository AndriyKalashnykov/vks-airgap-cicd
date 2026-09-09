#!/usr/bin/env bash
# test-ci-pass-verdict.sh — the offline gate for ci-pass-verdict.sh.
#
# ⚠️ THIS FILE IS REACHABLE TWO WAYS, AND A `# ci-tier:` MARKER CANNOT EXPRESS THAT. Since
# #1198 it is a NAMED PREREQ of `static-check-fast` (Makefile), which is the only CI job with
# no `if:` and no `needs:` — i.e. the only one that runs on every PR. It is ALSO in TEST_OFFLINE
# by the wildcard, so `make static-check` runs it TWICE on the weekly (measured: 2 occurrences
# in `make -n static-check`; cost 0.06s each, over 3 draws).
# So adding `# ci-tier: slow` here would read "not on the PR path" while the file STILL runs on
# every PR — a marker that lies. If you want it off the PR path, remove the Makefile prereq;
# the marker alone will not do it.
#
# WHY THIS FILE EXISTS. ci-pass is the SOLE required status check on this repo, so a defect in the
# verdict script has exactly two blast radii and both are total: it lets a red run merge, or it
# refuses every run. The second is not hypothetical — an implementation round MEASURED that the
# hand-typed job lists in ci-pass-verdict.sh refuse 66 of 400 historical runs, because
# static-check-fast was added in #650 (2026-08-16) while #535 had disabled static-check on 08-11.
# The job set changed TWICE in six days. Nothing asserted the lists still matched ci.yml, so the
# rot mode was "the sole required check refuses everything until someone notices".
#
# So the load-bearing assertions here are the ci.yml ones. They fail at PR time, loudly, naming the
# file to edit — instead of at merge time, silently, for everyone.
#
# ⚠️ THE LISTS ARE DERIVED FROM THE SCRIPT, NEVER RE-TYPED HERE. A second hand-typed copy is the
# enumerated-list rot one level up: it drifts the first time someone edits one and not the other,
# and then this gate cheerfully certifies a stale pair against itself.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
VERDICT="${VERDICT:-$SCRIPT_DIR/ci-pass-verdict.sh}"
CI_YML="${CI_YML:-$REPO_ROOT/.github/workflows/ci.yml}"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n     %s\n' "$1" "${2:-}"; }

for f in "$VERDICT" "$CI_YML"; do
  [ -r "$f" ] || { printf '  FAIL  INSTRUMENT MISSING: %s\n' "$f"; exit 1; }
done

# ── the sets, DERIVED ───────────────────────────────────────────────────────────────────────────
# From the script under test: its two constants, as whitespace-delimited words.
_const() { sed -n "s/^$1=\"\([^\"]*\)\".*/\1/p" "$VERDICT" | head -1 | xargs -n1 2>/dev/null | sort -u; }
S_UNCOND="$(_const UNCONDITIONAL)"
S_COND="$(_const CONDITIONAL)"
S_SELF="$(sed -n 's/^SELF="\([^"]*\)".*/\1/p' "$VERDICT" | head -1)"

# POSITIVE CONTROL FIRST. If the extraction above silently produced nothing, every set comparison
# below would compare two empty strings and "pass" — the vacuous-green this repo keeps finding.
if [ -n "$S_UNCOND" ] && [ -n "$S_COND" ] && [ -n "$S_SELF" ]; then
  ok "extracted the script's own constants (UNCONDITIONAL=$(echo "$S_UNCOND" | tr '\n' ' '), CONDITIONAL=$(echo "$S_COND" | tr '\n' ' '), SELF=$S_SELF)"
else
  bad "could not extract the constants from $VERDICT" "every set assertion below would compare empty to empty and pass vacuously"
fi

# From ci.yml: every top-level job, and which of them carry a job-level if: guard.
Y_JOBS="$(awk '/^jobs:/{j=1;next} j && /^  [a-z][a-z0-9-]*:/{n=$1;sub(/:$/,"",n);print n}' "$CI_YML" | sort -u)"
Y_IF="$(awk '/^jobs:/{j=1} j && /^  [a-z][a-z0-9-]*:/{n=$1;sub(/:$/,"",n)} j && /^    if:/{print n}' "$CI_YML" | sort -u)"
Y_NEEDS="$(sed -n 's/^ *needs: *\[\(.*\)\].*/\1/p' "$CI_YML" | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort -u)"

if [ "$(printf '%s\n' "$Y_JOBS" | wc -l)" -ge 3 ] && [ -n "$Y_NEEDS" ]; then
  ok "parsed ci.yml ($(printf '%s\n' "$Y_JOBS" | wc -l) jobs, $(printf '%s\n' "$Y_NEEDS" | wc -l) needs)"
else
  bad "could not parse ci.yml" "the assertions below would be vacuous"
fi

_same() { # _same <label> <a> <b>
  local d; d="$(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") 2>/dev/null)"
  if [ -z "$d" ]; then ok "$1"; else bad "$1" "$(printf '%s' "$d" | tr '\n' ' ')"; fi
}

_same "the script's two lists together == ci.yml's jobs minus $S_SELF" \
  "$(printf '%s\n%s\n' "$S_UNCOND" "$S_COND" | sort -u)" \
  "$(printf '%s\n' "$Y_JOBS" | grep -vx "$S_SELF" | sort -u)"

_same "the script's two lists together == ${S_SELF}'s declared needs" \
  "$(printf '%s\n%s\n' "$S_UNCOND" "$S_COND" | sort -u)" \
  "$Y_NEEDS"

_same "CONDITIONAL == exactly the jobs carrying a job-level if:" \
  "$S_COND" \
  "$(printf '%s\n' "$Y_IF" | grep -vx "$S_SELF" | sort -u)"

# ── THE PR FLOOR — the assertion that survives the rot the one above PRESCRIBES ─────────────────
# MEASURED 2026-09-08, two arms, both reproducible with VERDICT=/CI_YML= above:
#   event-gate static-check-fast, lists untouched          -> 24/1  CAUGHT (by the assertion above)
#   event-gate it AND move UNCONDITIONAL -> CONDITIONAL     -> 25/0  BLIND
# The second is what a person actually does, because the FIRST arm's message says "ci.yml changed
# and this list did not" -- so they dutifully update the list. THE GUARD'S OWN ERROR TEXT IS THE
# INSTRUCTION THAT BLINDS IT. Under that rot the merge gate printed, on a PR shape where 2 of 6 jobs
# ran: `2 ok, 4 legitimately skipped, 0 bad` -> `ci-pass: OK`.
#
# WHY THIS SHAPE, AND NOT THE TWO THAT WERE REFUTED. An adversary round built 12 rot arms + 3
# states this repo ACTUALLY SHIPPED and scored three candidates:
#   (A) "an event-gated job belongs in NEITHER list"        -> a FAIL-OPEN. `ci-pass-verdict.sh`
#       notes-but-does-not-judge an unlisted job, so a FAILED static-check went `note ... OK`,
#       reproducing that script's founding incident BY DESIGN.                          4/11
#   (C) "the set of event-gated jobs in ci.yml == {static-check}"  -> quantified over the `if:`
#       TEXT, i.e. over a proxy. Blind to the SAME rot spelled with a DIFF gate (the repo's own
#       documented restoration spelling), blind to a folded `if: >-`, and RED on 2 of the 3 guard
#       forms static-check has genuinely shipped.                                       5/11
#   (F) this one -- quantified over the POLICY, not over any YAML text.                11/11, 0 false-RED
#
# Every blind arm was the SAME single edit: a job moved OUT of UNCONDITIONAL. So assert the move.
# Growing this list is a POLICY DELETION ("this gate no longer runs on every PR"), not bookkeeping.
PR_FLOOR="changes static-check-fast secrets"   # changes:           classifies the diff every other gate reads
                                               # static-check-fast: the ONLY per-PR alignment/doc/env gate
                                               # secrets:           gitleaks + the prose-secret scan
_floor_missing=""
for _j in $PR_FLOOR; do
  printf '%s\n' "$S_UNCOND" | grep -qx "$_j" || _floor_missing="$_floor_missing $_j"
done
if [ -z "$_floor_missing" ]; then
  ok "every PR-floor gate ($(printf '%s' "$PR_FLOOR")) is in UNCONDITIONAL"
else
  bad "PR-floor gate(s) NOT in UNCONDITIONAL:$_floor_missing" \
      "moving one there is how ci-pass goes OK over a PR that ran almost nothing -- it is a POLICY change, not bookkeeping"
fi

# ⚠️ NOT CLOSED BY ANY OF THIS, named rather than implied: a job NEUTERED IN PLACE
# (`run: make static-check-fast` -> `run: true`) is green everywhere -- conclusion=success,
# nsteps>=1. An anchor assertion on the run: line is the shape that would catch it; not built.

# ── the aggregator's OWN if: — the one line in the graph that nothing asserted ──────────────────
# ⚠️ THE ASSERTION ABOVE DELIBERATELY EXCLUDES $S_SELF (`grep -vx`), which is correct for the
# CONDITIONAL-set comparison and left ci-pass's own guard covered by NOTHING. An adversary round
# (2026-08-17) mutated `if: always()` to `if: needs.changes.outputs.code == 'true'` in a scratch
# copy of ci.yml and this suite still scored 23/23.
#
# WHY THAT IS FATAL RATHER THAN UNTIDY: ci-pass is the SOLE required status check in the ruleset
# (`required_status_checks: [{context: "ci-pass"}]`). If its own guard ever stops being
# unconditional, a docs-only PR publishes `ci-pass / skipped`, and both candidate outcomes are
# unacceptable — either a skipped check SATISFIES the requirement, so every docs PR merges with
# ZERO verification, or it does not, and the repo is permanently wedged. Nothing in the repo
# distinguishes those two today (see the residual in the row), which is exactly why the guard must
# not be allowed to drift in the first place.
Y_SELF_IF="$(awk -v self="$S_SELF" '
  /^jobs:/{j=1}
  j && /^  [a-z][a-z0-9-]*:/{n=$1; sub(/:$/,"",n)}
  j && n==self && /^    if:/{sub(/^    if:[[:space:]]*/,""); print; exit}' "$CI_YML")"
if [ "$Y_SELF_IF" = "always()" ]; then
  ok "${S_SELF}'s OWN job-level guard is exactly 'if: always()' (it is the sole required check — a conditional guard would let it SKIP)"
else
  bad "${S_SELF}'s own guard must be 'if: always()'" "found '${Y_SELF_IF:-<none>}' — as the SOLE required status check, anything conditional means it can publish 'skipped' on a filtered PR"
fi

# ── behaviour, against REAL captured runs ───────────────────────────────────────────────────────
# _run <want:REFUSE|allow> <name> <tsv on stdin>
_run() {
  local want="$1" name="$2" out rc
  out="$(bash "$VERDICT" 2>&1)"; rc=$?
  local got; if [ "$rc" -ne 0 ]; then got=REFUSE; else got=allow; fi
  if [ "$got" = "$want" ]; then ok "$name ($got)"
  else bad "$name: got $got want $want" "$(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)"; fi
  LAST_OUT="$out"
}

echo
echo "== real captured runs =="
# THE INCIDENT, verbatim from run 32043952216: secrets died inside "Set up job" (own-steps 0) and
# the old needs-context guard rendered as a false condition, so ci-pass reported SUCCESS over it.
_run REFUSE "run 32043952216 — the false green (secrets failed, ci-pass said success)" <<'EOF'
static-check-fast	success	3
changes	success	3
secrets	failure	0
docs-lint	success	5
static-check	skipped	0
diagrams-check	skipped	0
ci-pass	success	1
EOF
# It must refuse for the RIGHT reason. A non-zero exit is not a RED; the gate saying the specific
# thing it exists to say is.
if printf '%s' "$LAST_OUT" | grep -q '^FAIL  secrets'; then
  ok "  ...and it names secrets, not something incidental"
else
  bad "  ...but it did not name secrets" "a refusal for the wrong reason is not a proof"
fi

# A genuine failure that ci-pass ALSO caught: the two must agree, or the change is not conservative.
_run REFUSE "run 32055155395 — genuine failure (secrets failed with own-steps=4)" <<'EOF'
secrets	failure	4
static-check-fast	success	3
changes	success	3
docs-lint	success	5
static-check	success	10
diagrams-check	skipped	0
ci-pass	failure	1
EOF

# The 98% case. If this refuses, the gate reddens nearly every PR and gets deleted within a week.
# ── a REAL captured payload, not hand-transcribed ───────────────────────────────────────────────
# ⚠️ EVERY OTHER FIXTURE IN THIS FILE IS HAND-TRANSCRIBED TSV, AND ITS SOURCE RUNS ARE GONE.
# Runs 32043952216 / 32044803928 / 32041902265 (the three false greens) and 32055155395 (the genuine
# failure) all return HTTP 404 today — deleted by a routine `gh run delete` sweep on 2026-08-17 that
# was not aware anything cited them. So if a future edit gets a field wrong, nothing can re-check
# those four against source, and the header's factual claims about them can never be re-derived.
# Recorded rather than quietly lived with, because a control whose evidence cannot be re-checked is
# one you will eventually stop trusting for the wrong reason.
#
# THIS one is different: captured verbatim from the live jobs API and COMMITTED, so it can be
# diffed against source for as long as the run survives, and re-captured from any run afterwards:
#   gh api --paginate "repos/<o>/<r>/actions/runs/<id>/jobs?per_page=100" --jq '.jobs[] |
#     [ .name, (.conclusion // "none"),
#       ([ .steps[]? | select(.name != "Set up job" and .name != "Complete job") ] | length) ] | @tsv'
# It carries the shape that matters — `success` AND `skipped` together — so it pins the property
# that a legitimately skipped conditional job must NOT be read as a failure.
_run allow "run 32087322157 — REAL captured payload (success + skipped), from a committed fixture" \
  < "${SCRIPT_DIR}/fixtures/ci-pass-run-32087322157.tsv"

_run allow "run 31948536196 — healthy docs-only (two conditional jobs skipped)" <<'EOF'
static-check-fast	success	3
changes	success	3
secrets	success	4
diagrams-check	success	3
docs-lint	skipped	0
static-check	skipped	0
ci-pass	success	1
EOF

echo
echo "== the caller can break this, so the script must refuse loudly =="
# MEASURED: with filter=all the API returns every attempt, so a rerun --failed that FIXES ci makes
# the run permanently unmergeable. Runs 32044956290 and 32044785511 are the real instances.
# ── D3: a FAILED CONDITIONAL job must REFUSE — and nothing pinned that until now ────────────────
# MEASURED 2026-09-08: all 11 `static-check` lines across this file and scripts/fixtures/*.tsv are
# `skipped` or `success`, and ZERO fixtures carry ANY conditional job at a failing conclusion. So
# the failure|cancelled|timed_out arm had never been exercised for one. An adversary built the
# exploit -- `[ "$name" = static-check ] && continue`, justified as "a CONDITIONAL job's failure is
# not our business" -- and the 25-case suite scored 25/0 over it. This fixture catches it.
#
# ⚠️ ASSERT THE MESSAGE, NOT rc. A DIFFERENT plausible mutation (a per-job `continue` earlier in the
# loop) also exits non-zero -- but with `ABSENT from the jobs list`, the INPUT-parsing arm, whose
# text instructs the very list edit that blinds the gate. A fixture asserting only rc!=0 banks that
# as a proof. This is the schedule shape: static-check RAN (own-steps=10) and FAILED.
_run REFUSE "a CONDITIONAL job that RAN and FAILED must refuse (schedule shape)" <<'EOF'
changes	success	3
static-check-fast	success	3
secrets	success	4
docs-lint	success	5
static-check	failure	10
diagrams-check	success	3
EOF
if printf '%s' "$LAST_OUT" | grep -qE '^FAIL  static-check .*conclusion=failure'; then
  ok "...and it REFUSED for the RIGHT reason (named static-check, conclusion=failure)"
else
  bad "the refusal did not name static-check's conclusion" \
      "rc!=0 alone is satisfied by the ABSENT arm, whose text tells you to edit the list that blinds this gate: $(printf '%s' "$LAST_OUT" | tr '\n' '|' | cut -c1-160)"
fi

_run REFUSE "filter=all — a job appearing twice is refused and named" <<'EOF'
changes	success	3
secrets	failure	0
changes	success	3
secrets	success	4
static-check-fast	success	3
docs-lint	skipped	0
static-check	skipped	0
diagrams-check	skipped	0
EOF
if printf '%s' "$LAST_OUT" | grep -qi 'twice\|filter=all'; then
  ok "  ...and it says filter=all rather than blaming the job"
else
  bad "  ...but it blamed a job" "the operator would go debug a healthy job"
fi

_run REFUSE "empty input — an API 503 must not read as 'nothing failed'" </dev/null

echo
echo "== malformed input is a CALLER defect and must say so =="
_run REFUSE "missing the step-count field" <<'EOF'
changes	success
EOF
if printf '%s' "$LAST_OUT" | grep -qi 'malformed\|CALLER'; then
  ok "  ...and it is named a caller defect, not a job defect"
else
  bad "  ...but it read as a job defect" "an earlier draft sent the operator to inspect a healthy job"
fi
_run REFUSE "non-numeric step count" <<'EOF'
changes	success	NaN
EOF
_run REFUSE "a negative step count" <<'EOF'
changes	success	-4
EOF

echo
echo "== structural cases =="
_run REFUSE "a needed job ABSENT from the list never reported" <<'EOF'
changes	success	3
secrets	success	4
docs-lint	skipped	0
static-check	skipped	0
diagrams-check	skipped	0
EOF
_run REFUSE "an UNCONDITIONAL job cannot legitimately skip" <<'EOF'
changes	success	3
secrets	skipped	0
static-check-fast	success	3
docs-lint	skipped	0
static-check	skipped	0
diagrams-check	skipped	0
EOF
_run REFUSE "a CONDITIONAL job that skipped but ran our steps is not a paths-filter decision" <<'EOF'
changes	success	3
secrets	success	4
static-check-fast	success	3
docs-lint	skipped	2
static-check	skipped	0
diagrams-check	skipped	0
EOF
_run REFUSE "success while running NONE of our steps" <<'EOF'
changes	success	3
secrets	success	0
static-check-fast	success	3
docs-lint	skipped	0
static-check	skipped	0
diagrams-check	skipped	0
EOF
# The other side of the sentinel: a job ci-pass DECLARES must never be certified while it is still
# running. ci-pass has if: always(), so it can be reached on a cancelled run with a need unfinished.
_run REFUSE "a DECLARED job still running (conclusion none) fails CLOSED" <<'EOF'
changes	success	3
secrets	none	0
static-check-fast	success	3
docs-lint	skipped	0
static-check	skipped	0
diagrams-check	skipped	0
EOF

# An added nightly/dispatch-only/optional job must NOT redden the sole required check. It may also
# still be RUNNING when ci-pass evaluates, hence the "none" sentinel.
#
# ⚠️ THE SENTINEL IS LOAD-BEARING, NOT COSMETIC. An earlier version of this fixture wrote the
# conclusion as an empty field (name, TAB, TAB, 0) because that is what `.conclusion` renders for a
# running job. TAB is IFS-*whitespace*, so `IFS=$'\t' read` COLLAPSES the pair and the line parses
# as conclusion="0" with NO step count — the script then correctly reported a malformed line, and
# the test read as a bug in the unknown-job arm. It was a defect in the INPUT CONTRACT: the caller's
# jq must emit `(.conclusion // "none")` so no field is ever empty. Do not "simplify" it back.
_run allow "a job outside ci-pass's needs is reported, not judged (and may still be running)" <<'EOF'
changes	success	3
secrets	success	4
static-check-fast	success	3
docs-lint	skipped	0
static-check	skipped	0
diagrams-check	skipped	0
e2e-nightly	none	0
EOF
if printf '%s' "$LAST_OUT" | grep -q '^note  e2e-nightly'; then
  ok "  ...and it is reported"
else
  bad "  ...but it was not reported" "silently ignoring an unknown job hides a renamed one"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
