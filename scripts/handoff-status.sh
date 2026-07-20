#!/usr/bin/env bash
# handoff-status.sh — put the HANDOFF and what-merged-since SIDE BY SIDE, for a human to compare.
#
# 🔴 IT MEASURES NOTHING, AND THAT IS DELIBERATE. It prints; it never gates; it exits 0
# unconditionally, including on its own errors. NEVER add it to static-check / ci / docs-lint — the
# instant it can go red it inherits every finding below.
#
# WHY NOT A GATE. The handoff went stale twice in one session, so a staleness gate is the obvious
# response. Four candidates were IMPLEMENTED and RUN over 30 real commits; all four failed:
#   PR-lag         93% false-RED (28/30), and structurally RED on 7/7 handoff commits — a squash
#                  merge assigns #NNN at MERGE time, so a handoff can never cite its own PR. Its only
#                  remedy is to stop citing PRs: a gate whose fix degrades the artifact.
#   word blocklist BLOCKS ITS OWN REMEDIATION (the fix quotes the banned word to correct it), and
#                  30/30 commits carry one legitimately ("no cluster" in `make help`; "still unbuilt"
#                  in a TRUE backlog row).
#   same-commit    73% false-RED — most commits correctly do not rewrite the handoff.
#   date-match     trivially green, and WAS green during both incidents.
#
# 🔴 AND THE NUMBER BELOW DOES NOT DISCRIMINATE — measured. The commit that carried the false claim
# scored a lag of 3; an ordinary healthy commit scored 22. Mid-session staleness is the CORRECT state
# (that is what "write the handoff at the last merge" means), so no threshold separates them. Do not
# add one. The list is for reading, not for counting.
#
# WHY `git log -L` AND NOT PR NUMBERS: the first version keyed on "newest #NNN cited in the handoff".
# Measured against the two REAL incidents, both stale handoffs cited **zero** PR numbers, so that
# version would have printed "drift cannot be measured this way" on the exact cases it was built for.
# The line range is citation-independent and works on any handoff.
#
# WHAT THIS HELPS WITH: incident 1 — a handoff left behind by a whole session of merges.
# WHAT IT CANNOT HELP WITH: incident 2 — a claim that was TRUE when written and falsified by a LATER
# commit ("Unbuilt", built one PR later). No commit-time instrument can see that; reading the subjects
# against the handoff's claims is a HUMAN act. Task-status claims belong in the Backlog, not here —
# the handoff's own scoping rule already says so, and following it is the real fix for that class.
#
# shellcheck shell=bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || exit 0                       # never gate, not even on our own failure

s="$(grep -n '^## ▶️ HANDOFF' CLAUDE.md 2>/dev/null | head -1 | cut -d: -f1)"
[ -n "${s:-}" ] || { log_warn "handoff-status: no '## ▶️ HANDOFF' section in CLAUDE.md."; exit 0; }
e="$(awk -v s="$s" 'NR>s && /^## /{print NR; exit}' CLAUDE.md)"; : "${e:=$(wc -l < CLAUDE.md)}"

printf '%s\n' "$(sed -n "${s}p" CLAUDE.md)" >&2
last="$(git log -1 --format=%H -L "${s},${e}:CLAUDE.md" 2>/dev/null | head -1)"
[ -n "${last:-}" ] || { log_warn "handoff-status: cannot locate the handoff's last edit (shallow clone?)."; exit 0; }

since="$(git log --oneline "${last}..main" 2>/dev/null || true)"
n="$(printf '%s' "$since" | grep -c . || true)"
log_info "handoff-status: the handoff was last edited by $(git log -1 --format='%h (%ad)' --date=short "$last" 2>/dev/null); ${n} commit(s) on main since."
if [ "${n:-0}" -gt 0 ]; then
  printf '  READ THESE AGAINST WHAT THE HANDOFF CLAIMS — that comparison is the whole point, and it\n' >&2
  printf '  is the part no tool does. The COUNT is not a signal (measured: it does not discriminate).\n' >&2
  printf '%s\n' "$since" | sed 's/^/    /' >&2
fi
exit 0
