#!/usr/bin/env bash
# check-doc-make-targets.sh — every `make <target>` a doc tells the operator to run MUST exist.
#
# WHY THIS GATE EXISTS
# `check-readme-scenarios` and `check-doc-command-count` both DEMAND that the runbooks contain
# specific `make X` commands — but neither ever checked that X is a real target. They grep the DOC,
# not the Makefile. So a Makefile-only PR that renames a target (this repo has done exactly that:
# `creds` -> `creds-show`) leaves every runbook pointing at a command that no longer exists, and
# NOTHING goes red: a Makefile-only change classifies as code=true/docs=false, so `docs-lint` is
# skipped — and even if it ran, the gate would still have passed.
#
# That is a COVERAGE hole, not a reachability one: you cannot fix it by moving a gate. Hence this,
# which reads BOTH sides. It is wired into `docs-lint` AND `static-check` (it guards docs, but its
# ground truth is the Makefile, so a code-only PR must run it too).
#
# ONLY commands in a CODE CONTEXT count — inside `backticks` or a fenced block. English prose
# ("make our lives easier", "make the cluster") is not an instruction and must not be flagged; the
# backtick is the discriminator, and it is the same convention the docs already follow.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

cd "$REPO_ROOT"

# OPERATOR-FACING docs only (the same set check-doc-command-count uses). CLAUDE.md is deliberately
# EXCLUDED: it is the agent/dev brief, and it legitimately DISCUSSES targets that are designed but
# not yet built ("make engine-check / make trust-harbor ... NOT yet built"). Those are mentions, not
# instructions — nobody executes CLAUDE.md. The harm this gate prevents is an OPERATOR being told to
# run a command that does not exist, and that only happens in a runbook.
#
# docs/reviews/ is excluded for the SAME reason, and it is not a loophole. Those files are the archived
# output of adversarial audits: they QUOTE findings, and a finding legitimately PROPOSES a target that
# does not exist yet ("add a `make lab-trust-harbor`") or quotes a shell line the parser reads as one
# ("install gawk" -> `make gawk`). They are a RECORD, not a runbook — nobody executes a review. Rewriting
# an audit's own words to appease a doc gate would falsify the record, which is worse than the gate's
# green. Every OPERATOR-facing doc (README + the runbooks) is still checked.
# `|| true` is what makes the guard BELOW reachable. Without it, an empty pathspec feeds `grep -v`
# empty input, grep exits 1, `pipefail` promotes it, and `set -e` kills this gate SILENTLY at rc=1 —
# so the die never prints and the blindness the guard exists to announce is announced by nothing.
# Found 2026-07-19 by an adversary, ONE DAY after the guard was added, in the exact case it targets.
docs=$(git ls-files --cached --others --exclude-standard 'README.md' 'docs/*.md' \
        | grep -v '^docs/reviews/' || true)
# WRONG POLARITY until 2026-07-19: this exited 0 when the doc list was empty, so a broken pathspec
# was indistinguishable from a clean repo. An empty operator-doc set is not a valid state here.
[ -n "$docs" ] || die "check-doc-make-targets: the doc pathspec matched 0 files — the gate has gone BLIND."

missing=""
checked=0
scanned=0

for f in $docs; do
  scanned=$((scanned + 1))
  # `make foo`, `make foo BAR=1`, and fenced lines beginning with `make foo`.
  # Strip the leading fence/backtick, take the token after `make`.
  while IFS= read -r tgt; do
    [ -n "$tgt" ] || continue
    checked=$((checked + 1))
    grep -qE "^${tgt}:" Makefile || missing="${missing}\n  ${f}: make ${tgt}"
  done < <(
    { grep -oE '`make [a-z][a-z0-9-]*' "$f" || true;
      grep -oE '^[[:space:]]*make [a-z][a-z0-9-]*' "$f" || true; } \
      | sed -E 's/^[[:space:]]*`?make //' | sort -u
  )
done

if [ -n "$missing" ]; then
  log_error "check-doc-make-targets: a doc tells the operator to run a make target THAT DOES NOT EXIST:"
  # shellcheck disable=SC2059
  printf "$missing\n" >&2
  log_error "  Either restore the target, or update the doc. A runbook that names a dead command is worse"
  log_error "  than one that says nothing: the operator trusts it and it fails."
  exit 1
fi

# B39 called this gate "the cleanest proof" of the file-vs-item bug: it prints BOTH numbers and
# gated on the wrong one, so 25 EMPTY docs read as `0 command(s) across 25 doc(s)` -- rc=0.
[ "$checked" -gt 0 ] || die "check-doc-make-targets: examined 0 'make <target>' command(s) across ${scanned} doc(s) — the FILE count is healthy but the ITEM count is zero. The gate has gone BLIND."
log_info "check-doc-make-targets: OK — ${checked} 'make <target>' command(s) across ${scanned} doc(s) all exist in the Makefile"
