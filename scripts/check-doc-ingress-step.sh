#!/usr/bin/env bash
# check-doc-ingress-step.sh — a scenario document's INGRESS step must be EXECUTABLE, and must be
# followed by a check that the routes work.
#
# WHY THIS EXISTS. The certification matrix walks the scenario documents and executes their FENCED
# blocks (`scripts/walk-doc.sh`); prose and table cells are read, never run. Until 2026-08-28
# `docs/scenario-2.md` carried its ingress branch ONLY as a table row (`:885-886`) and prose
# (`:897`), and carried no `make verify-ingress` at all. So no scenario-2 row could publish
# `INGRESS_LB_IP`, and nothing asserted the hosts route.
#
# MEASURED: rows 5 and 6 printed `<needs ingress>` for all eight hosts — gitea, tekton and the six
# apps, i.e. the whole demo — in 20 logs across 12 runs since 2026-08-20, and every one of those rows
# was graded `0 FAILED`. Meanwhile the ONE scenario-1 row that printed it graded `2 FAILED`, because
# scenario-1 does fence `make verify-ingress`. The difference between a row that catches this and a
# row that cannot is one fenced block. (B517.)
#
# THE INVARIANT, and it is derived, not enumerated: for every `docs/scenario-*.md`, if the document
# tells the reader to install/attach an ingress at all, it must do so in a FENCED block AND must
# carry a FENCED `make verify-ingress`. It does not check WHICH branches exist — scenario-1 has two
# and a future document may have one — only that the step is runnable and verified.
#
# ⚠️ IT MUST NOT MATCH ITS OWN PROSE. The strings it hunts appear in this header, so it scans only
# `docs/scenario-*.md`; this file is not in that glob. The `make ...` forms above are deliberately
# written inside backticks in PROSE, never as a fenced block, so a future move of this text into a
# scanned document still could not satisfy the gate.
#
# ⚠️ "FENCED" MEANS WHAT `walk-doc.sh` MEANS BY IT, AND A DIVERGENCE IS A FALSE GREEN. A first
# version toggled on any line starting with ``` and was measured wrong THREE ways, each certifying a
# document the walk cannot run:
#   * INFO STRING IGNORED — an ingress step in a ```text or ```console fence passed the gate while
#     the walk extracted ZERO blocks. Both scenario docs already contain ```text and ```yaml fences,
#     and `istio-preflight` PRINTS the command to run, so showing its output in ```console is the
#     natural authoring move.
#   * 4-BACKTICK DESYNC — a ````-wrapped block containing an odd number of ``` lines INVERTS the
#     toggle for the rest of the file; measured, three prose lines were then read as fenced.
#   * <details> — scenario-2 already collapses alternatives that way, and the walk SKIPS them
#     ("inside a <details> alternative"). Collapsing the two mutually-exclusive branches into one is
#     exactly what an author does, and it reintroduces the original bug under a green gate.
# The parser below mirrors `walk-doc.sh` (its extractor, at the `re.match(r'^(\s*)(`{3,})(\S*)'`
# line): >=3 backticks, close on a run of AT LEAST that many, info string must be bash|sh|shell,
# <details> blocks skipped). `test-doc-ingress-step.sh` pins all three divergences.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$REPO_ROOT" || exit 1

rc=0; scanned=0
# Emit the lines the WALK would execute. Tracking fence state is the whole point: a table cell and a
# fenced command are the same characters to a naive grep, and the table cell is exactly what shipped.
# Python, not awk, because the rules above (matched close length, info string, <details>) are not
# expressible as a one-line toggle -- and because this must read the same way walk-doc.sh does.
fenced_lines() {
  python3 - "$1" <<'PYEOF'
import re, sys
fence = None          # (info, backtick_count) while open
details = False
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    m = re.match(r'^(\s*)(`{3,})(\S*)', line)
    if fence is None:
        if line.lstrip().startswith('<details'):
            details = True
        elif line.lstrip().startswith('</details>'):
            details = False
        elif m:
            fence = (m.group(3).split(':')[0].lower(), len(m.group(2)))
        continue
    # inside a fence: close on a run of AT LEAST the opening length, with no info string
    if m and m.group(3) == '' and len(m.group(2)) >= fence[1]:
        fence = None
        continue
    if not details and fence[0] in ('bash', 'sh', 'shell'):
        sys.stdout.write(line)
PYEOF
}

for doc in docs/scenario-*.md; do
  [ -f "$doc" ] || continue
  # A notes file RECORDS an incident and quotes the commands involved -- that is what it is for.
  # Demanding a fenced verify block in one is a false RED, and `docs/scenario-1-notes.md` is in the
  # glob today (which is why the denominator reads 3, not 2).
  case "$doc" in *-notes.md) printf '  %s: notes file — records incidents, does not prescribe steps\n' "$doc"; continue ;; esac
  scanned=$((scanned + 1))
  body="$(fenced_lines "$doc")"

  # Does the document ASK for an ingress at all (anywhere — prose, table or fence)?
  # Allow anything make itself takes between the verb and the target -- flags AND their arguments
  # (`make -C .. install-ingress` is two words, not one flag). Bounded to the same command by
  # excluding ; & | so `make foo && echo install-ingress` is not read as an ingress step. A bare
  # literal reported
  # "no ingress step at all", rc=0, on a document that installs an ingress and never verifies it --
  # a swallow arm whose message reads as reassurance rather than as "I could not see one".
  asks=0
  grep -qE 'make[[:space:]]+([^;&|[:space:]]+[[:space:]]+)*install-ingress' "$doc" && asks=1
  [ "$asks" -eq 1 ] || { printf '  %s: no ingress step MATCHED — if this document HAS one, the gate cannot see it\n' "$doc"; continue; }

  inst="$(printf '%s' "$body" | grep -cE 'make[[:space:]]+([^;&|[:space:]]+[[:space:]]+)*install-ingress' || true)"
  veri="$(printf '%s' "$body" | grep -cE 'make[[:space:]]+([^;&|[:space:]]+[[:space:]]+)*verify-ingress'  || true)"
  case "$inst" in ''|*[!0-9]*) inst=0 ;; esac
  case "$veri" in ''|*[!0-9]*) veri=0 ;; esac

  if [ "$inst" -eq 0 ]; then
    printf 'ERROR %s: names an ingress step but has ZERO FENCED blocks that run it.\n' "$doc"
    printf '      A table cell or prose is READ by the reader and NEVER RUN by the walk, so the\n'
    printf '      certification matrix cannot execute this step and every row will report\n'
    printf '      "<needs ingress>" for every host while grading itself 0 FAILED.\n'
    rc=1
  fi
  if [ "$veri" -eq 0 ]; then
    printf 'ERROR %s: installs an ingress and never verifies it.\n' "$doc"
    # No backticks in this message: shellcheck reads them as a would-be expansion inside the single
    # quotes (SC2016) even though literal is exactly what is wanted, and terminal output gains
    # nothing from markdown emphasis anyway.
    printf '      Add a FENCED verify-ingress block after the install/attach block: it sends a\n'
    printf '      Host: header to the LB IP and asserts each host reaches ITS OWN backend, which\n'
    printf '      is the only assertion in the walk that can fail when the routes are wrong.\n'
    rc=1
  fi
  printf '  %s: fenced install=%s verify=%s\n' "$doc" "$inst" "$veri"
done

if [ "$scanned" -eq 0 ]; then
  printf 'ERROR check-doc-ingress-step: scanned ZERO documents — the glob found nothing.\n'
  exit 1
fi
[ "$rc" -eq 0 ] && printf 'check-doc-ingress-step: OK — scanned %s scenario document(s)\n' "$scanned"
exit "$rc"
