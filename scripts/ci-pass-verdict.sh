#!/usr/bin/env bash
# ci-pass-verdict.sh — decide whether a CI run may merge, from the JOBS API rather than the
# workflow `needs` context.
#
# WHY THIS EXISTS: ci-pass is the SOLE required status check on this repo, and it was MEASURED
# passing over a FAILED gate job — THREE times over 400 runs, once on main.
#
#   run 32043952216 (PR #754)             secrets  conclusion=failure  -> ci-pass=success
#   run 32044803928 (on main)             secrets  conclusion=failure  -> ci-pass=success
#   run 32041902265 (docs/b148-lab-...)   secrets  conclusion=failure  -> ci-pass=success
#
# The old guard was contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled'),
# and the incident's own step log renders it as literally "if false; then" WITH secrets at
# conclusion failure. ci-at-run.yml confirms secrets WAS in that job's needs at the time, so this
# is not a missing-dependency artefact. The entire merge gate could be green over a failed
# security scan.
#
# ⚠️ WHAT ACTUALLY FIXES IT: reading each job's conclusion from the JOBS API instead of from the
# needs context. That is the whole mechanism. An earlier draft of this header called the STEP
# COUNT "the discriminator" — that was FALSE and it is corrected here, because a false fact inside
# a control is worse than no comment: across 2,698 jobs in 400 runs, steps<=1 occurs 4 times and
# every one is already non-success, and "success with a runner-only step list" occurs ZERO times.
# The step check below has NEVER fired. It is defence-in-depth against an UNOBSERVED twin, not the
# fix — do not let it tempt anyone into weakening the conclusion arm, which is what does the work.
#
# ⚠️ THE ROOT CAUSE OF ALL THREE INCIDENTS, measured from the failing job's log: "Prepare all
# required actions" hit codeload.github.com 429, 429, 503 while downloading an action. So it is
# transient GitHub infrastructure, it recurs, and `secrets` is the most exposed job (two action
# downloads). That CONFIRMS refuse-is-correct: the gate genuinely did not run, so a retry is a
# workaround and this is the fix.
#
# INPUT: one job per line on stdin, TAB-separated:
#     <name>\t<conclusion>\t<n_own_steps>
# where n_own_steps EXCLUDES the runner's own "Set up job" and "Complete job". The caller does the
# API read and that filtering, so this file is offline, hermetic and unit-testable.
#
# ⚠️ NO FIELD MAY EVER BE EMPTY, and this is a correctness requirement rather than tidiness. TAB is
# IFS-*whitespace*, so `IFS=$'\t' read` COLLAPSES a run of tabs: a line whose middle field is empty
# loses it and every later field SHIFTS LEFT. A job that is still RUNNING has conclusion null, so a
# naive `.conclusion` renders an empty middle field and `name<TAB><TAB>0` silently parses as
# conclusion="0" with no step count — a misparse that reads as a malformed-input error pointing at
# an innocent job. The caller must therefore emit a SENTINEL, never an empty string:
#
#   jq -r '.jobs[] | [ .name, (.conclusion // "none"),
#          ([ .steps[]? | select(.name!="Set up job" and .name!="Complete job") ] | length) ] | @tsv'
#
# "none" then falls through to the unrecognised-conclusion arm and fails CLOSED for a declared job,
# which is right: ci-pass must not certify a run while something it needs is still running.
#
# ⚠️ THE CALLER MUST NOT PASS filter=all. MEASURED: runs 32044956290 and 32044785511 are genuinely
# green after a re-run (real ci-pass=success), and with filter=all this script sees 12 jobs instead
# of 6 — attempt 1's failure included — and flips rc 0 -> 1. A `rerun --failed` that FIXES CI would
# make the PR permanently unmergeable. The API default (latest) is correct; verified it returns only
# the current attempt. The duplicate-name check below self-detects the mistake if anyone re-adds it.
#
# OUTPUT: a verdict line + a reconcilable denominator. rc=0 may merge, rc=1 must not.
set -uo pipefail

# The jobs with NO if: guard — anything other than success here is a real defect, never a
# paths-filter decision.
UNCONDITIONAL=" changes static-check-fast secrets "
# The trio that legitimately skips. MEASURED over 60 PR runs: 59/60 (98%) skip at least one —
# 33 docs-only skip {diagrams-check,static-check}, 11 code-only skip {diagrams-check,docs-lint}.
# A blanket every-job-must-succeed would redden 98% of PRs. This is the constraint, not a nicety.
CONDITIONAL=" static-check docs-lint diagrams-check "
# ci-pass is the caller: while it runs, its own conclusion is null. Never judge yourself.
SELF="ci-pass"
#
# ⚠️ THESE TWO LISTS ARE HAND-TYPED AND DUPLICATE ci.yml, AND THEIR ROT MODE IS A HARD REFUSE OF
# EVERY RUN — not a silent hole. MEASURED: 66 of 400 runs refuse solely on "static-check-fast
# ABSENT", because that job was added in #650 on 2026-08-16 while #535 disabled static-check on
# 08-11 — the job set changed TWICE in six days. Add, rename or remove a job and the sole required
# check refuses everything until someone edits this file. scripts/test-ci-pass-verdict.sh is the
# offline gate that fails at PR time instead, asserting these two sets against ci.yml's own job
# list AND against ci-pass's needs:. If you change ci.yml's jobs, that gate tells you to come here.

rc=0; seen=0; ok=0; skipped=0; bad=0; unknown=0
declare -A GOT=()

while IFS=$'\t' read -r name concl nsteps extra || [ -n "${name:-}" ]; do
  [ -n "${name:-}" ] || continue
  [ "$name" = "$SELF" ] && continue

  # Validate the LINE before judging the JOB. An earlier draft coerced a malformed field to 0 and
  # then reported "conclusion=success but it never ran a step of ours" — sending the operator to
  # inspect a healthy job when the real fault was the caller's jq expression.
  # ⚠️ An EMPTY conclusion is NOT malformed: a job still RUNNING has conclusion null, which the
  # caller's jq renders as empty, and an unknown job (a nightly outside ci-pass's needs) can
  # legitimately still be running when ci-pass evaluates. Rejecting it here fired BEFORE the
  # unknown-job arm below and reddened a run over a job this gate does not even judge. An empty
  # conclusion on a DECLARED job still falls through to the unrecognised-conclusion arm and fails
  # closed. A missing third field is caught by the numeric check immediately after this.
  if [ -n "${extra:-}" ] || [ -z "${nsteps:-}" ]; then
    printf 'FAIL  malformed input line for %-14s — want exactly 3 tab-separated fields\n' "$name"
    printf '        This is a CALLER defect (the jq expression), not a defect in that job.\n'
    bad=$((bad+1)); rc=1; continue
  fi
  case "$nsteps" in ''|*[!0-9]*)
    printf 'FAIL  malformed step count for %-14s: [%s] is not a non-negative integer\n' "$name" "$nsteps"
    printf '        This is a CALLER defect (the jq expression), not a defect in that job.\n'
    bad=$((bad+1)); rc=1; continue ;;
  esac

  # A duplicate name means the caller passed filter=all (see the header). Refusing here is right,
  # but say WHY, because the failure otherwise looks like a job that failed on a previous attempt.
  if [ -n "${GOT[$name]:-}" ]; then
    printf 'FAIL  %-20s appears TWICE — the caller passed filter=all and is judging stale attempts\n' "$name"
    printf '        Drop the filter parameter: the API default returns only the latest attempt.\n'
    bad=$((bad+1)); rc=1; continue
  fi

  seen=$((seen+1)); GOT["$name"]=1

  # A job outside ci-pass's declared needs is not this gate's business. Report it, do not judge it:
  # an added nightly/dispatch-only/optional job must not redden the sole required check.
  if [[ " $UNCONDITIONAL $CONDITIONAL " != *" $name "* ]]; then
    printf 'note  %-20s not in ci-pass needs — reporting, not judging (conclusion=%s)\n' "$name" "$concl"
    unknown=$((unknown+1)); continue
  fi

  case "$concl" in
    failure|cancelled|timed_out|action_required)
      printf 'FAIL  %-20s conclusion=%s own-steps=%s\n' "$name" "$concl" "$nsteps"
      printf '        A needed job did not succeed. The old needs-context guard rendered this as\n'
      printf '        a false condition when the job died during set-up, which is how this gate\n'
      printf '        went green over it three times.\n'
      bad=$((bad+1)); rc=1; continue ;;
  esac

  if [ "$concl" = skipped ]; then
    if [[ " $CONDITIONAL " != *" $name "* ]]; then
      printf 'FAIL  %-20s SKIPPED, but it has no if: guard — it cannot legitimately skip\n' "$name"
      printf '        Something broke upstream of it, or ci.yml changed and this list did not.\n'
      bad=$((bad+1)); rc=1; continue
    fi
    if [ "$nsteps" -ne 0 ]; then
      printf 'FAIL  %-20s SKIPPED but ran %s step(s) of ours — not a paths-filter decision\n' "$name" "$nsteps"
      bad=$((bad+1)); rc=1; continue
    fi
    printf 'skip  %-20s (paths-filter — legitimate, ran none of our steps)\n' "$name"
    skipped=$((skipped+1)); continue
  fi

  if [ "$concl" = success ]; then
    # DEFENCE-IN-DEPTH, never observed firing (see the header): a success that ran none of OUR
    # steps is not a success. The caller has already excluded the runner's own "Set up job" and
    # "Complete job", so this needs no threshold and cannot rot as steps are added.
    if [ "$nsteps" -lt 1 ]; then
      printf 'FAIL  %-20s conclusion=success but it ran NONE of our steps\n' "$name"
      bad=$((bad+1)); rc=1; continue
    fi
    printf 'ok    %-20s own-steps=%s\n' "$name" "$nsteps"
    ok=$((ok+1)); continue
  fi

  printf 'FAIL  %-20s unrecognised conclusion=%s — refusing to guess\n' "$name" "$concl"
  bad=$((bad+1)); rc=1
done

# A job that never REPORTED is not a job that passed. if: always() does not guarantee an entry:
# MEASURED, 2 of 13 cancelled runs had no ci-pass entry at all. Absence must be fail-CLOSED.
for j in $UNCONDITIONAL $CONDITIONAL; do
  [ -n "${GOT[$j]:-}" ] && continue
  printf 'FAIL  %-20s ABSENT from the jobs list — it never reported\n' "$j"
  printf '        If this job was renamed or removed in ci.yml, update the lists in this file;\n'
  printf '        test-ci-pass-verdict.sh should have caught that at PR time.\n'
  bad=$((bad+1)); rc=1
done

# THE DENOMINATOR. A verdict without one cannot be reconciled against the run, and this gate's
# whole history is a green nobody could check.
printf '\nci-pass-verdict: %s job(s) judged — %s ok, %s legitimately skipped, %s bad, %s not-judged\n' \
  "$seen" "$ok" "$skipped" "$bad" "$unknown"
if [ "$seen" -eq 0 ]; then
  printf 'FAIL  the jobs list was EMPTY — the API read produced nothing, so this verdict is vacuous\n'
  printf '      Fail-closed is deliberate: an API 503 must not read as "nothing failed".\n'
  exit 1
fi
if [ "$rc" -eq 0 ]; then printf 'ci-pass: OK\n'; else printf 'ci-pass: REFUSED\n'; fi
exit "$rc"
