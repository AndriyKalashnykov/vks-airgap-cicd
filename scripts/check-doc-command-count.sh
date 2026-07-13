#!/usr/bin/env bash
# check-doc-command-count.sh — a doc that COUNTS the work must not contradict the commands beside it.
#
# The README promised the KinD path in "one command" and then, in the SAME table row, listed TWO:
#   | Just see it work | KinD — ONE COMMAND, zero .env | ... Run: `make deps` -> `make e2e-kind` |
# The same lie was in the intro list and in docs/kind-local.md. A reader budgets effort from that
# number; getting it wrong is the cheapest possible way to lose their trust, and nothing caught it
# for the repo's whole life because it is prose, not code.
#
# THE RULE: if a line claims "<N> command(s)", the `make ...` invocations ON THAT LINE must number N.
# Lines with a count but ZERO make-commands are skipped -- they are prose about something else
# ("one command OS-gates, installs git/curl/make + mise" describes the curl|bash bootstrap, which
# really is one command and names no make target).
#
# Offline: pure text. No cluster, no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

fail=0
checked=0

# number-word -> value. A doc says "two commands", never "2 commands".
declare -A WORD=([one]=1 [two]=2 [three]=3 [four]=4 [five]=5 [six]=6 [seven]=7 [eight]=8)

for f in README.md docs/*.md; do
  [ -f "$f" ] || continue
  # -n gives the line number; read the whole line so we can count the `make`s on it.
  while IFS=: read -r ln line; do
    # A COUNT claim ("two commands") is not a REFERENCE ("**the** one command the runbook tells you to
    # run"). The definite article is the discriminator: "the one command" names a specific command, it
    # does not promise how many there are. Capturing the optional leading "the" and skipping it is what
    # separates the two — without this the gate false-fires on ordinary prose, which is exactly what it
    # did on its first run (two hits in docs/lab-validation-plan.md, both "the one command").
    m="$(printf '%s' "$line" \
      | grep -oiE '(the[[:space:]]+)?(one|two|three|four|five|six|seven|eight)[[:space:]]+commands?' \
      | head -1)"
    [ -n "$m" ] || continue
    printf '%s' "$m" | grep -qiE '^the[[:space:]]' && continue   # a reference, not a count
    word="$(printf '%s' "$m" | awk '{print tolower($1)}')"
    claimed="${WORD[$word]:-}"
    [ -n "$claimed" ] || continue

    # count DISTINCT `make <target>` invocations on the same line (backticked or bare).
    actual="$(printf '%s' "$line" | grep -oE '`?make [a-z0-9][a-z0-9-]*' | sort -u | wc -l)"

    # A count with no make-commands on the line is prose about something else — not our business.
    [ "$actual" -eq 0 ] && continue

    checked=$((checked + 1))
    if [ "$actual" -ne "$claimed" ]; then
      printf 'FAIL  %s:%s claims "%s command(s)" but lists %s make command(s) on the same line\n' \
        "$f" "$ln" "$word" "$actual" >&2
      printf '        %s\n' "$(printf '%s' "$line" | cut -c1-140)" >&2
      fail=1
    fi
  done < <(grep -inE '(one|two|three|four|five|six|seven|eight)[[:space:]]+commands?' "$f" 2>/dev/null)
done

# Print the denominator: a gate that cannot say what it looked at cannot be trusted to have looked.
if [ "$fail" -eq 0 ]; then
  echo "check-doc-command-count: OK — ${checked} 'N command(s)' claim(s) match the commands beside them"
  exit 0
fi
echo "check-doc-command-count: FAILED (${checked} claim(s) checked)" >&2
exit 1
