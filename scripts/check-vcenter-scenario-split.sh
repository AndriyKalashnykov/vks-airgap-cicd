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
# `grep -c` prints 0 AND EXITS 1 on no match, which under `set -e` would kill the script on exactly
# the healthy case. `|| true` is load-bearing here, not decoration.
_n1="$(grep -cE "$_pat" "$_s1" || true)"
_n2="$(grep -cE "$_pat" "$_s2" || true)"

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
