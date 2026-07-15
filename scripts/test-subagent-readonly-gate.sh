#!/usr/bin/env bash
# test-subagent-readonly-gate.sh — prove the PreToolUse hook is RED for subagents and GREEN for us.
#
# The hook has TWO failure modes and BOTH are silent:
#   * too loose  -> an adversary destroys uncommitted work again (the bug it exists to stop);
#   * too strict -> it blocks the MAIN agent's git/gh, and the session cannot ship anything.
# So it is not enough to prove it blocks. It must be proven to block the SUBAGENT and to leave the
# MAIN agent (no agent_id/agent_type in the payload) completely untouched.
#
# Offline: feeds synthetic PreToolUse JSON on stdin. No git, no gh, no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

HOOK=".claude/hooks/subagent-readonly-gate.py"
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# probe <expect-rc> <label> <json>
probe() {
  local want="$1" label="$2" json="$3" rc
  printf '%s' "$json" | python3 "$HOOK" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else bad "$label (rc=$rc, want $want)"; fi
}

sub()  { printf '{"agent_type":"vks-adversary","agent_id":"a1","tool_name":"Bash","tool_input":{"command":%s}}' "$1"; }
main() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1"; }

echo "--- SUBAGENT: mutations must be BLOCKED (rc=2) ---"
probe 2 "subagent: git commit"                 "$(sub '"git commit -m x"')"
probe 2 "subagent: git push"                   "$(sub '"git push origin main"')"
probe 2 "subagent: git checkout -- (THE ONE THAT DESTROYED WORK)" "$(sub '"git checkout -- scripts/lib/os.sh"')"
probe 2 "subagent: git reset --hard"           "$(sub '"git reset --hard origin/main"')"
probe 2 "subagent: git stash"                  "$(sub '"git stash push -u"')"
probe 2 "subagent: gh pr create"               "$(sub '"gh pr create --title x --body y"')"
probe 2 "subagent: gh pr merge"                "$(sub '"gh pr merge 1 --squash"')"
probe 2 "subagent: gh api -X POST"             "$(sub '"gh api -X POST repos/o/r/pulls"')"
probe 2 "subagent: gh api implicit POST (-f)"  "$(sub '"gh api repos/o/r/pulls -f title=x"')"
probe 2 "subagent: mutation HIDDEN MID-CHAIN"  "$(sub '"make static-check && git push"')"
# shellcheck disable=SC2016  # the $(...) is a LITERAL test fixture: it must NOT expand — it is the
# command string we are asserting the hook blocks. Expanding it would run `git commit` in the test.
probe 2 "subagent: mutation in a subshell"     "$(sub '"echo $(git commit -m x)"')"
probe 2 "subagent: sudo-prefixed"              "$(sub '"sudo git clean -fd"')"

echo "--- SUBAGENT: FILE writes to the caller's MAIN tree BLOCKED; writes INSIDE its worktree ALLOWED ---"
edit() { printf '{"agent_type":"adversary-go","agent_id":"a1","tool_name":"%s","tool_input":{"file_path":%s}}' "$1" "$2"; }
probe 2 "subagent: Edit a MAIN-tree file"            "$(edit Edit  '"/home/u/proj/scripts/x.sh"')"
probe 2 "subagent: Write a MAIN-tree file"           "$(edit Write '"/home/u/proj/README.md"')"
probe 2 "subagent: MultiEdit a MAIN-tree file"       "$(edit MultiEdit '"/home/u/proj/Makefile"')"
probe 0 "subagent: Edit INSIDE its .claude/worktrees checkout" "$(edit Edit  '"/home/u/proj/.claude/worktrees/agent-a1/scripts/x.sh"')"
probe 0 "subagent: Write INSIDE its worktree"        "$(edit Write '"/home/u/proj/.claude/worktrees/agent-a1/new.txt"')"
# TRAVERSAL: a raw substring test would ALLOW these (adversary-proven); realpath collapses .. and BLOCKS.
probe 2 "subagent: worktrees/../.. escape to MAIN tree" "$(edit Edit '"/home/u/proj/.claude/worktrees/../../scripts/x.sh"')"
probe 2 "subagent: worktrees/../../../.. escape the repo" "$(edit Write '"/home/u/proj/.claude/worktrees/agent-Z/../../../../etc/cron.d/x"')"

echo "--- SUBAGENT: read-only work must still be ALLOWED (rc=0) — else the review is worthless ---"
probe 0 "subagent: git log"                    "$(sub '"git log --oneline -5"')"
probe 0 "subagent: git diff"                   "$(sub '"git diff origin/main --stat"')"
probe 0 "subagent: git show"                   "$(sub '"git show HEAD:scripts/lib/os.sh"')"
probe 0 "subagent: git status"                 "$(sub '"git status --short"')"
probe 0 "subagent: gh pr view"                 "$(sub '"gh pr view 199 --json state"')"
probe 0 "subagent: gh search code"             "$(sub '"gh search code /etc/docker/certs.d"')"
probe 0 "subagent: gh api GET"                 "$(sub '"gh api repos/o/r/contents/go.mod"')"
probe 0 "subagent: grep"                       "$(sub '"grep -rn docker scripts/"')"
probe 0 "subagent: PROSE mentioning git push"  "$(sub '"echo \"never run git push here\""')"
probe 0 "subagent: make static-check"          "$(sub '"make static-check"')"

echo "--- MAIN AGENT: must be UNTOUCHED (rc=0). If any of these block, the session cannot ship. ---"
probe 0 "main: git commit"                     "$(main '"git commit -m x"')"
probe 0 "main: git push"                       "$(main '"git push origin main"')"
probe 0 "main: git reset --hard"               "$(main '"git reset --hard origin/main"')"
probe 0 "main: gh pr create"                   "$(main '"gh pr create --title x"')"
probe 0 "main: gh pr merge"                    "$(main '"gh pr merge 1 --squash"')"

echo "--- robustness: must FAIL OPEN, never wedge the session ---"
probe 0 "malformed JSON -> allow"              'not json at all'
probe 0 "non-Bash tool -> allow"               '{"agent_id":"a1","tool_name":"Read","tool_input":{"file_path":"/x"}}'
probe 0 "empty command -> allow"               "$(sub '""')"

if [ "$fail" = 0 ]; then echo "test-subagent-readonly-gate: OK"; exit 0; fi
echo "test-subagent-readonly-gate: FAILED" >&2
exit 1
