#!/usr/bin/env bash
# test-adversary-gate-rearm.sh — the adversary-first gate RE-ARMS on every commit.
#
# A review authorizes guarded writes only until the next commit: the receipt records the wall-clock
# time an adversary was engaged, and a guarded write is allowed only when that time is NEWER than the
# repo's HEAD commit. Committing moves HEAD past the receipt, so the next unit of work needs its own
# adversary pass. This is the fix for the session-lifetime-receipt hole (one design review authorizing
# every later write for the whole session).
#
# Hermetic: a throwaway git repo with a commit at a KNOWN committer epoch; synthetic PreToolUse JSON.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

HOOK="${HOOK_UNDER_TEST:-.claude/hooks/adversary-first-gate.py}"
HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"   # absolutize; the probes cd into a temp repo

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" config user.email t@t; git -C "$TMP" config user.name tester
mkdir -p "$TMP/docs" "$TMP/scripts" "$TMP/.claude/state"
: > "$TMP/seed"; git -C "$TMP" add seed
COMMIT_EPOCH=1000000000
GIT_COMMITTER_DATE="@$COMMIT_EPOCH +0000" GIT_AUTHOR_DATE="@$COMMIT_EPOCH +0000" \
  git -C "$TMP" commit -qm seed
SID="testsession"
RECEIPT="$TMP/.claude/state/adversary-$SID.receipt"

probe() {  # <expect-rc> <label> <tool_json>
  local want="$1" label="$2" json="$3" rc
  printf '%s' "$json" | CLAUDE_PROJECT_DIR="$TMP" python3 "$HOOK" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else bad "$label (rc=$rc want $want)"; fi
}
gwrite()   { printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/docs/x.md"}}' "$SID" "$TMP"; }
exemptw()  { printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/CLAUDE.md"}}' "$SID" "$TMP"; }
unguard()  { printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/notes.txt"}}' "$SID" "$TMP"; }
spawn()    { printf '{"session_id":"%s","tool_name":"Agent","tool_input":{"subagent_type":"vks-adversary"}}' "$SID"; }

echo "--- a guarded write needs a review NEWER than HEAD ---"
rm -f "$RECEIPT"
probe 2 "no receipt -> BLOCK"                                   "$(gwrite)"
echo "engaged" > "$RECEIPT"
probe 2 "old content-free 'engaged' receipt -> BLOCK"          "$(gwrite)"
echo "$((COMMIT_EPOCH-100))" > "$RECEIPT"
probe 2 "stale receipt (older than HEAD) -> BLOCK"            "$(gwrite)"
echo "$((COMMIT_EPOCH+100))" > "$RECEIPT"
probe 0 "fresh receipt (newer than HEAD) -> ALLOW"           "$(gwrite)"

echo "--- exempt + unguarded always allowed, even with a stale receipt ---"
echo "$((COMMIT_EPOCH-100))" > "$RECEIPT"
probe 0 "CLAUDE.md exempt -> ALLOW"                          "$(exemptw)"
probe 0 "unguarded path -> ALLOW"                            "$(unguard)"

echo "--- an adversary SPAWN stamps a fresh receipt and re-authorizes ---"
rm -f "$RECEIPT"
probe 0 "adversary spawn -> ALLOW"                           "$(spawn)"
if [ -f "$RECEIPT" ] && python3 -c "import sys; sys.exit(0 if float(open('$RECEIPT').read().strip())>$COMMIT_EPOCH else 1)"; then
  ok "spawn wrote a parseable epoch newer than HEAD"
else bad "spawn did not stamp a fresh epoch receipt"; fi
probe 0 "after spawn, guarded write -> ALLOW"               "$(gwrite)"

echo "--- RE-ARM: a commit AFTER the review invalidates it ---"
R="$(cat "$RECEIPT")"
AFTER="$(python3 -c "print(int(float('$R'))+10)")"
: > "$TMP/f2"; git -C "$TMP" add f2
GIT_COMMITTER_DATE="@$AFTER +0000" GIT_AUTHOR_DATE="@$AFTER +0000" git -C "$TMP" commit -qm after-review
probe 2 "guarded write after a post-review commit -> BLOCK (re-arm works)" "$(gwrite)"

if [ "$fail" -eq 0 ]; then echo "PASS: adversary-first gate re-arms on every commit"
else echo "FAIL: re-arm gate has a hole" >&2; fi
exit "$fail"
