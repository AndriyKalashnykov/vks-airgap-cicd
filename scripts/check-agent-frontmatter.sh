#!/usr/bin/env bash
# check-agent-frontmatter.sh — every .claude/agents/*.md must have PARSEABLE YAML frontmatter.
#
# WHY (2026-07-14): `.claude/agents/vks-adversary.md` shipped to main with BROKEN frontmatter —
#
#     Error in user YAML: mapping values are not allowed in this context at line 2 column 247
#
# because its `description:` value contained an unquoted `: ` (from the prose "…9.1 + Kubernetes…
# whose job is to REFUTE the design on REAL-LAB grounds: …"), and YAML reads that as a nested mapping.
# GitHub renders the error instead of the file. Worse, the agent definition is what makes the BLOCKING
# adversary loadable at session start — a repo-wide control, silently malformed, and nothing was
# checking it. A sibling agent definition happened to be fine, which is exactly how it hid.
#
# The lesson is the house one: a file that is CONFIG for a control is part of the control. If it can be
# malformed, it needs a gate. Prose in a YAML scalar must be quoted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

cd "$REPO_ROOT" || exit 1

shopt -s nullglob
files=(.claude/agents/*.md)
[ ${#files[@]} -gt 0 ] || { log_info "check-agent-frontmatter: no agent definitions"; exit 0; }

rc=0
for f in "${files[@]}"; do
  # Capture the gate's OWN rc on its OWN line. NOT `out="$(...)" && log_info ... || { ... }` — that is
  # `A && B || C`, which is not if-then-else (C runs when A is true and B fails), and it is the exact
  # fake-green shape the repo has a hook against. Do not write it, not even here.
  out="$(python3 - "$f" <<'PY'
import sys, yaml
p = sys.argv[1]
s = open(p).read()
if not s.startswith("---"):
    print("NO FRONTMATTER (must start with ---)"); sys.exit(1)
parts = s.split("---", 2)
if len(parts) < 3:
    print("UNTERMINATED FRONTMATTER (missing the closing ---)"); sys.exit(1)
try:
    d = yaml.safe_load(parts[1])
except Exception as e:
    print("INVALID YAML: %s" % str(e).replace("\n", " ")[:160]); sys.exit(1)
if not isinstance(d, dict):
    print("FRONTMATTER IS NOT A MAPPING"); sys.exit(1)
for k in ("name", "description"):
    if not d.get(k):
        print("MISSING REQUIRED KEY: %s" % k); sys.exit(1)
sys.exit(0)
PY
)"
  frc=$?
  if [ "$frc" -eq 0 ]; then
    log_info "  ok  $f"
  else
    log_error "  $f: $out"
    rc=1
  fi
done

if [ $rc -ne 0 ]; then
  log_error "check-agent-frontmatter: an agent definition has broken frontmatter."
  log_error "  GitHub renders a YAML error instead of the file, and the agent may not load at all."
  log_error "  Most common cause: prose containing ': ' in an unquoted value. QUOTE the value:"
  log_error '      description: "BLOCKING reviewer: refutes the design on real-lab grounds."'
  exit 1
fi
log_info "check-agent-frontmatter: ${#files[@]} agent definition(s), all parseable"
