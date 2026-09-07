#!/usr/bin/env bash
# check-install-chain.sh — the `install-all` CHAIN STRING spelled out in prose must match the
# Makefile's actual prerequisite list, in order (B539).
#
# WHY. When `build-apps` joined `install-all` (b24082f), no prose copy was updated. This is the
# repo's own "a value living in >1 file needs a gate asserting they agree" class — the same class
# check-image-alignment and check-toolchain-alignment exist for — and its absence is why the
# omission survived a merge.
#
# ⚠️ IT IS A RECURRENCE, NOT A ONE-OFF. `docs/reviews/2026-07-14-doc-truth-audit.md:213` flagged
# CLAUDE.md's copy stale on 2026-07-14; it was fixed, and by 2026-09-07 it had drifted again —
# missing FIVE of twelve targets, including `build-apps`, the one this gate was filed for.
# `Makefile`'s install-all line has changed 8 times, 4 of them in 12 days. It is a hot line.
#
# ⚠️ SCOPE, and every clause of it is load-bearing. A round REFUTED the obvious scope
# (`docs/` + ASCII ` -> ` + a `#` comment): it is blind to CLAUDE.md's copy on THREE axes at once —
# not under docs/, a UNICODE arrow, no `#` — and prototyped GREEN over an 11-day-old live drift.
#   *.md TREE-WIDE            CLAUDE.md is not under docs/, and it is the copy that matters most:
#                             it is auto-loaded into every session AND re-injected into every
#                             subagent, so a stale chain there misinforms every reviewer, every
#                             time. A docs/ copy misinforms one operator, once.
#   BOTH ARROWS               18 doc files use U+2192; the live defect was on that side of the line.
#   COMPARE THE JOINED STRING A sorted/set compare passes on REORDERED links — measured. Order is
#                             the contract here (it is a prerequisite LIST).
#
# ⚠️ THREE EXCLUSIONS, each with a measured reason. Without them the gate has 4 false REDs in 7 hits.
#   Makefile        it is the LEFT-HAND SIDE. Its own `##` help prose is legitimately ABBREVIATED
#                   (`platform -> headlamp -> ingress -> gitops -> build-apps`) and names two things
#                   that are NOT targets — `headlamp`/`ingress` (the targets are install-headlamp /
#                   install-ingress). Gating help prose against the prereq list is a category error.
#   BACKLOG.md      line ~1581 quotes a chain inside a CLOSED row: a historical record.
#   docs/reviews/   `:176` and `:213` DELIBERATELY quote stale chains — that is what a review IS.
#                   CLAUDE.md's own naming-history rule: rewriting them "would falsify the record".
#                   A gate whose only remedy degrades the artifact is refuted on sight.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. "$PWD/scripts/lib/os.sh"

WANT="$(grep -m1 '^install-all:' Makefile | sed 's/^install-all: *//; s/ *##.*//' | tr -s ' ' | sed 's/ *$//')"

# ⚠️ SANITY-GATE THE LEFT-HAND SIDE FIRST. Forgetting the `s/ *##.*//` yields 49 tokens instead of
# 12 — and then BOTH correct docs go RED, with a message that reads as a DOC defect and sends the
# fixer to the wrong file. An error that names the wrong cause is worse than a crash.
_n=$(printf '%s' "$WANT" | wc -w)
if [ "$_n" -lt 8 ] || [ "$_n" -gt 20 ]; then
  log_error "check-install-chain: could not read install-all's prerequisites from the Makefile."
  log_error "  got ${_n} token(s): ${WANT}"
  log_error "  Expected 8-20 bare target names. This is a fault in THIS GATE (most likely the"
  log_error "  '##' help comment is no longer being stripped), NOT a defect in any document."
  exit 1
fi
for _t in $WANT; do
  case "$_t" in
    *[!a-z0-9-]*) log_error "check-install-chain: '$_t' is not target-shaped — refusing to compare."; exit 1 ;;
  esac
done

scanned=0; bad=0
# ⚠️ `-I` skips binary files: docs/diagrams/out/ holds PNGs, and B540 closed two days ago on exactly
# this class of grep noise.
while IFS= read -r _hit; do
  _f="${_hit%%:*}"; _rest="${_hit#*:}"; _ln="${_rest%%:*}"
  # ⚠️ MATCH ON THE PATH SUFFIX, not a `./`-anchored prefix. A worktree-isolated subagent nests a
  # FULL REPO COPY at .claude/worktrees/agent-<id>/, so `./docs/reviews/*` does not match
  # `./.claude/worktrees/agent-x/docs/reviews/...` — measured: this gate flagged a REVIEW document
  # inside a running adversary's worktree on its very first run. `.claude` is excluded outright for
  # the same reason every tree-walking gate here excludes it.
  # `*/X` already covers the `./X` form grep emits (the glob `*` matches the leading `.`), so a
  # second `./X` alternative is DEAD — shellcheck SC2222 proves it. Do not "restore" it.
  case "$_f" in
    ./.claude/*)       continue ;;
    */BACKLOG.md)      continue ;;
    */docs/reviews/*)  continue ;;
    */Makefile)        continue ;;
  esac
  # The chain on this line: the longest run of arrow-joined target-shaped tokens.
  # ⚠️ TOLERATE THE WHITESPACE THE SUBSTITUTION ITSELF CREATES. `s/→/ -> /g` turns `a → b` into
  # `a  ->  b` (DOUBLE spaces, because the arrow already had spaces around it), and a pattern
  # demanding single spaces then matches nothing — so the gate scanned 2 files instead of 3 and was
  # GREEN over the one live drift. Measured; caught by counting what it scanned, not by reading it.
  _got="$(sed -n "${_ln}p" "$_f" \
            | sed 's/→/ -> /g' \
            | grep -oE '[a-z][a-z0-9-]*([[:space:]]*->[[:space:]]*[a-z][a-z0-9-]*){3,}' \
            | head -1 || true)"
  [ -n "$_got" ] || continue
  _got="$(printf '%s' "$_got" | sed 's/[[:space:]]*->[[:space:]]*/ /g' | tr -s ' ')"
  scanned=$((scanned + 1))
  if [ "$_got" = "$WANT" ]; then
    log_info "ok    ${_f}:${_ln}"
  else
    bad=$((bad + 1))
    log_error "DRIFT ${_f}:${_ln}"
    log_error "  got : ${_got}"
    log_error "  want: ${WANT}"
  fi
done < <(grep -rnI 'install-all' --include='*.md' . 2>/dev/null || true)

if [ "$bad" -gt 0 ]; then
  log_error "check-install-chain: ${bad} of ${scanned} prose chain(s) disagree with the Makefile."
  log_error "  install-all's prerequisite list is the SOURCE OF TRUTH. Update the prose, in order."
  exit 1
fi
log_info "check-install-chain: OK — ${scanned} prose chain(s) match install-all's prerequisites"
