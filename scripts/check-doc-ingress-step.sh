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
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$REPO_ROOT" || exit 1

rc=0; scanned=0
# Emit "<file>:<lineno>:<line>" for lines INSIDE a ``` fence only. Tracking the fence state is the
# whole point: a table cell and a fenced command are the same characters to a naive grep, and the
# table cell is exactly what shipped.
fenced_lines() {
  awk '
    /^[[:space:]]*```/ { infence = !infence; next }
    infence            { printf "%d:%s\n", FNR, $0 }
  ' "$1"
}

for doc in docs/scenario-*.md; do
  [ -f "$doc" ] || continue
  scanned=$((scanned + 1))
  body="$(fenced_lines "$doc")"

  # Does the document ASK for an ingress at all (anywhere — prose, table or fence)?
  asks=0
  grep -q 'make install-ingress' "$doc" && asks=1
  [ "$asks" -eq 1 ] || { printf '  %s: no ingress step at all — nothing to check\n' "$doc"; continue; }

  inst="$(printf '%s' "$body" | grep -c 'make install-ingress' || true)"
  veri="$(printf '%s' "$body" | grep -c 'make verify-ingress'  || true)"
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
