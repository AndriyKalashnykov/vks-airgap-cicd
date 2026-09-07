#!/usr/bin/env bash
# ci-tier: fast — offline; greps two documents. No network, no cluster.
#
# check-vcenter-scenario-split.sh — the vCenter note in `make creds` rests on a FACT ABOUT TWO
# FILES; this is what stops that fact going stale (B536).
#
# `scripts/creds.sh` prints, when the vCenter row is blank:
#     "That is expected on the scenario-2 walk: docs/scenario-2.md never asks for VCENTER_* ,
#      while docs/scenario-1.md does."
#
# WHY THE NOTE IS WORDED ABOUT FILES AND NOT ABOUT THE READER. The report cannot know who is
# reading it. "You are a tenant" / "you are not expected to have these" is a claim about a PERSON
# and their possessions — a colleague of the VI admin may well hold vCenter credentials — and
# `creds.sh` already legislates the same rule for the flow line ("IT MUST NOT CLAIM WHAT IS
# INSTALLED — it cannot know"). A statement about two documents is checkable, which is why it can
# be gated at all and a statement about the reader could not.
#
# MEASURED at the time the note was written: scenario-1 = 13 mentions, scenario-2 = 0.
# This gate does NOT pin those numbers — a count is not the claim. The claim is the SPLIT:
# scenario-1 asks, scenario-2 does not. Pinning 13 would go RED on an unrelated edit that adds a
# sentence, which is the enumerated-value rot this repo keeps paying for.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

_s1="${REPO_ROOT}/docs/scenario-1.md"
_s2="${REPO_ROOT}/docs/scenario-2.md"
for f in "$_s1" "$_s2"; do
  [ -f "$f" ] || die "check-vcenter-scenario-split: ${f} not found — this gate reads two documents
  and cannot answer without both. That is a broken gate, not a clean repo."
done

_pat='VCENTER_HOST|VCENTER_USERNAME|VCENTER_PASSWORD'

# ⚠️ A MENTION IS NOT AN ASK, and conflating them made this gate go RED on a CORRECT document.
# `docs/scenario-2.md:812` ALREADY says "This document never asks you for vCenter credentials".
# The moment someone makes that sentence more precise — naming the three variables — a
# mention-counting gate reddens `static-check` on the doc that makes creds.sh's note MORE true, and
# the cheapest way to go green is to DELETE the clarification. A gate whose only remedy degrades the
# artifact is refuted on sight (configuration.md). So DISCLAIMING lines are excluded from the count.
_disclaim='never asks|does not ask|do NOT set|don.t set|Expect:'

# ⚠️ `grep -c` EXITS 2 ON AN UNREADABLE FILE and prints 0 — the HEALTHY value. With `|| true` that
# rc was swallowed and the gate reported "OK — scenario-2 does not (0)" for a file it could not
# read, positively asserting a number it never obtained. MEASURED with `chmod 000`. The `[ -f ]`
# guard above catches MISSING, not UNREADABLE. rc 0 = matched, 1 = no match (the healthy case this
# gate exists for), >=2 = a real error that must be fatal.
# ⚠️ NOT `x="$(grep … | grep … | wc -l)"; rc="${PIPESTATUS[0]}"`. That was the first fix and it is
# BROKEN: after an ASSIGNMENT, PIPESTATUS[0] is the assignment's own status, not the pipeline's.
# MEASURED on an unreadable file — the assignment form reports rc=1 (indistinguishable from the
# healthy no-match case) while the bare pipeline reports grep's real rc=2. So the read-error arm
# would never have fired, and the gate would have looked fixed while still failing open.
# ⚠️ THE READABILITY CHECK IS OUT HERE, NOT INSIDE _count — AND THAT IS THE WHOLE POINT.
# A first fix put `die` inside a helper called as `_n2="$(_count "$_s2")"`. `die` calls `exit`, and
# `exit` inside a COMMAND SUBSTITUTION terminates only the SUBSHELL. This script is `set -uo
# pipefail` with NO `-e`, so the failed assignment did not stop anything: `_n2` came back EMPTY,
# `${_n2:-0}` turned it into 0 — the HEALTHY value — and the gate printed its own die message and
# then reported OK with rc=0. MEASURED on a `chmod 000` file: the error text appeared AND rc was 0.
# That is worse than the bug it replaced, because the message makes it look handled.
for _f in "$_s1" "$_s2"; do
  [ -r "$_f" ] || die "check-vcenter-scenario-split: ${_f} exists but is NOT READABLE. This gate
  cannot answer without it, and reporting '0 mentions' would assert a number it never obtained."
done

_count() { # _count <file> -> mentions that are not disclaimers. Readability is guaranteed above.
  local _f="$1" _hits
  _hits="$(grep -E "$_pat" "$_f" || true)"
  [ -n "$_hits" ] || { printf '0'; return 0; }  # grep -c on empty input would count a phantom line
  printf '%s\n' "$_hits" | grep -cvE "$_disclaim" || true
}
_n1="$(_count "$_s1")"
_n2="$(_count "$_s2")"

_bad=0
if [ "${_n1:-0}" -eq 0 ]; then
  log_error "check-vcenter-scenario-split: docs/scenario-1.md mentions VCENTER_* ZERO times."
  log_error "  creds.sh tells a reader with a blank vCenter row that scenario-1 DOES ask for these."
  log_error "  If scenario-1 no longer does, that sentence is now false — fix the note, not this gate."
  _bad=1
fi
if [ "${_n2:-0}" -ne 0 ]; then
  log_error "check-vcenter-scenario-split: docs/scenario-2.md mentions VCENTER_* ${_n2} time(s)."
  log_error "  creds.sh tells a reader that scenario-2 NEVER asks for them, so that sentence is now"
  log_error "  false — and it is printed to the audience least able to notice (RULE ZERO-B)."
  grep -nE "$_pat" "$_s2" | head -5 | while IFS= read -r l; do log_error "    ${l}"; done
  _bad=1
fi
[ "$_bad" -eq 0 ] || die "check-vcenter-scenario-split: the vCenter note in creds.sh is no longer true."
log_info "check-vcenter-scenario-split: OK — scenario-1 asks for VCENTER_* (${_n1} mention(s)), scenario-2 does not (0)"
