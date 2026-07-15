#!/usr/bin/env bash
# test-no-gate-in-commit-chain.sh — prove the PreToolUse gate blocks a REAL gate+commit chain but
# does NOT trip on a commit MESSAGE that merely QUOTES such a chain (the B8 false-positive).
#
# The gate has two failure modes and both are silent:
#   * too loose  -> a FAILED gate produces a green-looking commit (the class the hook exists to stop);
#   * too strict -> it blocks its OWN documentation. It literally blocked the commit that documented
#                   this bug, because the message quoted `make static-check && git commit` in a
#                   backtick code-span — and a backtick is a command-position char, so the gate token
#                   inside the message was read as a real execution.
# So it is not enough to prove it blocks. It must ALLOW a message that quotes the pattern AND still
# BLOCK a real chain. The B8 fix strips the -m/--message/-F/--file argument before matching.
#
# Offline: feeds synthetic PreToolUse JSON on stdin. No git, no gh, no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

HOOK=".claude/hooks/no-gate-in-commit-chain.py"
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# probe <expect-rc> <label> <raw-command-string>  — python json-encodes the command so backticks,
# quotes and && inside it are passed verbatim as DATA (never interpreted by this test's shell).
probe() {
  local want="$1" label="$2" cmd="$3" rc json
  json="$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd")"
  printf '%s' "$json" | python3 "$HOOK" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else bad "$label (rc=$rc, want $want)"; fi
}

echo "--- B8: a commit MESSAGE quoting the pattern must be ALLOWED (rc=0) ---"
# The REAL reproduction: a backtick code-span puts the gate token at a command position INSIDE the
# message. This is the exact shape that blocked the bug's own commit. The backticks below are
# LITERAL test fixtures — they must NOT expand (expanding them would run `make ...` in the test).
# shellcheck disable=SC2016
probe 0 "message: backtick code-span (the real reproduction)" 'git commit -m "docs: no `make static-check && git commit` chains"'
# shellcheck disable=SC2016
probe 0 "message: backtick gate+commit"                       'git commit -m "explain `make ci && git commit` is banned"'
probe 0 "message: && quoted in message"                       'git commit -m "make ci && git commit"'
probe 0 "message: combined -am short flag"                    'git commit -am "make ci && git commit"'
probe 0 "message: single-quoted"                              "git commit -m 'make lint && git push'"
probe 0 "message: --message= form"                            'git commit --message="make ci | tail && git commit"'
probe 0 "message: multiple -m, gate only in a message"        'git commit -m "one" -m "make ci && git commit"'
probe 0 "message: -F file operand, no gate"                   'git commit -F /tmp/msg.txt'
probe 0 "heredoc body is data"                                "git commit -F - <<'EOF'
make ci && git commit
EOF"

echo "--- REAL chains must STILL be BLOCKED (rc=2) — no regression ---"
probe 2 "chain: gate && commit -m"                'make ci && git commit -m x'
probe 2 "chain: tail-pipe -> commit"              'make static-check 2>&1 | tail -3 && git commit -m "wip"'
probe 2 "chain: lint && commit with message"      'make lint && git commit -m "done"'
probe 2 "chain: gate && commit -F"                'make ci && git commit -F /tmp/body.md'
probe 2 "chain: grep||echo -> commit"             'npm run test | grep -i error || echo clean && git commit -m "ok"'
probe 2 "chain: e2e && push (no message)"         'make e2e-kind && git push'
probe 2 "chain: scanner ; commit"                 'trivy fs . ; git commit -m "scanned"'

echo "--- benign singletons ALLOWED (rc=0) ---"
probe 0 "plain commit"    'git commit -m "just a normal message"'
probe 0 "gate alone"      'make ci'
probe 0 "read-only git"   'git status'

[ "$fail" -eq 0 ] && echo "PASS: no-gate-in-commit-chain gate is correct in both directions" \
                  || echo "FAIL: no-gate-in-commit-chain gate has a hole" >&2
exit "$fail"
