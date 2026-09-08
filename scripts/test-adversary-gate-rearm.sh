#!/usr/bin/env bash
# test-adversary-gate-rearm.sh — the adversary-first gate RE-ARMS on every commit.
#
# A review authorizes guarded writes only until the next NON-EXEMPT commit (B45): the receipt records
# the wall-clock time an adversary was engaged, and a guarded write is allowed only when that time is
# NEWER than the repo's most recent NON-EXEMPT commit. A guarded/neither commit re-arms; an exempt-only
# (docs/handoff/CI/plan) commit does NOT. This is the fix for the session-lifetime-receipt hole (one
# design review authorizing every later write) + B45 (a docs commit no longer strands a code review).
#
# Hermetic: a throwaway git repo with a commit at a KNOWN committer epoch; synthetic PreToolUse JSON.
set -uo pipefail
# ⚠️ A GATE'S TEST MUST NOT RUN WITH THE GATE'S OWN KILL-SWITCH IN THE ENVIRONMENT. With
# ADVERSARY_GATE_OFF=1 exported, the hook ALLOWS everything, so every "must BLOCK" case fails
# `rc=0 want 2` and this script prints "re-arm gate has a hole" — naming a cause it never
# established, which is exactly the class of defect the rest of this suite exists to catch.
# MEASURED 2026-08-17: an operator shell that had used the documented override for one commit
# then read a clean gate as broken. Unset it for the duration; say so rather than doing it silently.
if [ -n "${ADVERSARY_GATE_OFF:-}" ]; then
  printf '  note: ADVERSARY_GATE_OFF was set in the environment; unsetting it for this run\n'
  printf '        (with it set the hook allows everything and every BLOCK case would "fail")\n'
  unset ADVERSARY_GATE_OFF
fi
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

echo "--- B45: an EXEMPT-only commit does NOT re-arm; guarded / mixed / neither DO ---"
# Baseline = the last NON-EXEMPT commit (f2 above). A review just after it, then an EXEMPT-only commit:
# the baseline must NOT advance, so the guarded write stays allowed (the B45 fix).
# DERIVE the exclude pathspec FROM THE HOOK, never hand-type it. This line used to spell out
# ':(exclude).claude' ':(exclude).github' ':(exclude)CLAUDE.md' -- a SECOND enumerated list, in the
# harness, which is exactly the rot the derivation guard 25 lines below exists to prevent, one level
# up. It went stale the moment BACKLOG.md joined EXEMPT_FILES (2026-08-16) and would have disagreed
# with the gate silently, because the temp repo has no BACKLOG.md so the value happened to match.
# An ARRAY, one pathspec per element -- NOT a string + `eval`. A single string would need to be
# left unquoted to word-split (shellcheck SC2086, and quoting it collapses every pathspec into ONE
# argument, which silently excludes nothing).
mapfile -t EXCL < <(python3 - "$HOOK" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
def tup(name):
    m = re.search(name + r'\s*=\s*\((.*?)\)', src, re.S)
    return re.findall(r'"([^"]+)"', m.group(1)) if m else []
for p in tup('EXEMPT_PREFIXES') + tup('EXEMPT_FILES'):
    print(':(exclude)%s' % p.rstrip('/'))
PY
)
[ "${#EXCL[@]}" -gt 0 ] || { bad "could not derive the exclude pathspec from $HOOK"; EXCL=(':(exclude).claude'); }
NEX="$(git -C "$TMP" log -1 --format=%ct -- . "${EXCL[@]}")"
REV="$((NEX+50))"; echo "$REV" > "$RECEIPT"
DOCS="$((REV+50))"; : > "$TMP/CLAUDE.md"; git -C "$TMP" add CLAUDE.md
GIT_COMMITTER_DATE="@$DOCS +0000" GIT_AUTHOR_DATE="@$DOCS +0000" git -C "$TMP" commit -qm docs-only
probe 0 "B45 THE FIX: guarded write after a DOCS-ONLY (CLAUDE.md) commit -> ALLOW (exempt does not re-arm)" "$(gwrite)"

# BACKLOG.md joined EXEMPT_FILES on 2026-08-16 (the plan/backlog moved out of CLAUDE.md in f7f6c30).
# Both directions, because the SECOND one is what proves it is not a bypass: closing a backlog row
# must not strand a review, but smuggling code alongside a backlog edit must still re-arm.
BLOG="$((DOCS+50))"; : > "$TMP/BACKLOG.md"; git -C "$TMP" add BACKLOG.md
GIT_COMMITTER_DATE="@$BLOG +0000" GIT_AUTHOR_DATE="@$BLOG +0000" git -C "$TMP" commit -qm backlog-only
probe 0 "BACKLOG-ONLY commit -> ALLOW (a bookkeeping commit must not destroy a valid review)" "$(gwrite)"

CLD="$((DOCS+50))"; mkdir -p "$TMP/.claude/hooks"; : > "$TMP/.claude/hooks/z.py"; git -C "$TMP" add .claude/hooks/z.py
GIT_COMMITTER_DATE="@$CLD +0000" GIT_AUTHOR_DATE="@$CLD +0000" git -C "$TMP" commit -qm claude-only
probe 0 "B45: guarded write after a .claude/-only commit -> ALLOW"                            "$(gwrite)"

GRD="$((CLD+50))"; : > "$TMP/scripts/foo.sh"; git -C "$TMP" add scripts/foo.sh
GIT_COMMITTER_DATE="@$GRD +0000" GIT_AUTHOR_DATE="@$GRD +0000" git -C "$TMP" commit -qm guarded
probe 2 "B45 RE-ARM: guarded write after a scripts/ commit -> BLOCK"                          "$(gwrite)"

echo "$((GRD+50))" > "$RECEIPT"; MIX="$((GRD+100))"
: > "$TMP/scripts/bar.sh"; : > "$TMP/CLAUDE.md"; git -C "$TMP" add scripts/bar.sh CLAUDE.md
GIT_COMMITTER_DATE="@$MIX +0000" GIT_AUTHOR_DATE="@$MIX +0000" git -C "$TMP" commit -qm mixed
probe 2 "B45 MIXED: guarded write after a scripts+CLAUDE.md commit -> BLOCK (guarded file re-arms)" "$(gwrite)"

echo "$((MIX+50))" > "$RECEIPT"; NTH="$((MIX+100))"
: > "$TMP/.env.example"; git -C "$TMP" add .env.example
GIT_COMMITTER_DATE="@$NTH +0000" GIT_AUTHOR_DATE="@$NTH +0000" git -C "$TMP" commit -qm neither
probe 2 "B45 (b): guarded write after a NEITHER (.env.example) commit -> BLOCK (only ALL-exempt commits skip)" "$(gwrite)"

# The NON-BYPASS half of the BACKLOG.md exemption, and the reason it is safe to add: a git exclude
# pathspec is per-FILE, not per-COMMIT, so a commit matches if ANY changed file survives exclusion.
# Smuggling code alongside a backlog edit therefore still re-arms. Placed LAST deliberately -- it
# commits a NON-exempt file, so running it earlier advances the baseline and false-BLOCKs every
# ALLOW case after it (measured: it broke the .claude/-only case when I first inserted it here).
MIX="$(( $(git -C "$TMP" log -1 --format=%ct) + 50 ))"
printf 'x\n' > "$TMP/BACKLOG.md"; mkdir -p "$TMP/scripts"; printf 'x\n' > "$TMP/scripts/smuggled.sh"
git -C "$TMP" add BACKLOG.md scripts/smuggled.sh
GIT_COMMITTER_DATE="@$MIX +0000" GIT_AUTHOR_DATE="@$MIX +0000" git -C "$TMP" commit -qm backlog-plus-code
probe 2 "MIXED BACKLOG.md + scripts/ -> BLOCK (an exclude pathspec is per-FILE: code still re-arms)" "$(gwrite)"

echo "--- B45: the exclude pathspec is DERIVED from the EXEMPT constants (no third hand-typed list) ---"
awk '/^def _last_nonexempt_commit_epoch/{f=1;next} f&&/^def /{f=0} f' "$HOOK" > "$TMP/fn.txt"
# Grep the CODE form (`for p in EXEMPT_PREFIXES`), NOT the bare names — those also appear in the
# function's DOCSTRING, so grepping the names is vacuous (a hand-typed exclude with the docstring intact
# would false-pass). The comprehension is what proves the pathspec is derived, not hand-typed.
if [ -s "$TMP/fn.txt" ] && grep -q 'for p in EXEMPT_PREFIXES' "$TMP/fn.txt" && grep -q 'for f in EXEMPT_FILES' "$TMP/fn.txt"; then
  ok "B45: _last_nonexempt_commit_epoch builds its exclude from EXEMPT_PREFIXES/EXEMPT_FILES"
else
  bad "B45: the exclude pathspec is not derived from the EXEMPT constants (enumerated-list-rot risk)"
fi

echo "--- the BASH arm: a shell write that NAMES the receipt is a FORGE ---"
# ⚠️ EVERY literal below is COMPOSED at runtime ($RCPT), never written out. A test that spells the
# forge is a test that cannot be created by a shell command — the gate blocks its own heredoc. That
# is HOOK-005, and it cost a round to learn: `cat > test.sh <<EOF ... EOF` carries the string.
RCPT=".claude/state/adversary-$SID.receipt"
bash_cmd() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$SID" "$1"; }

rm -f "$RECEIPT"
# THE SHAPE THAT SHIPPED BROKEN: the first version required WHITESPACE after the redirect, so this
# one-command forge sailed through a matcher that had just been called 13/13. The RED-proof was a
# SUBSET — every probe happened to type a space.
probe 2 "bash: redirect with NO SPACE -> BLOCK (the subset-RED-proof hole)"  "$(bash_cmd "echo 1757000000 >$RCPT")"
probe 2 "bash: redirect WITH a space -> BLOCK"                               "$(bash_cmd "echo 1757000000 > $RCPT")"
probe 2 "bash: append, no space -> BLOCK"                                    "$(bash_cmd "echo 1757000000 >>$RCPT")"
probe 2 "bash: \$VAR indirection -> BLOCK (adjacency cannot see this; the conjunction can)" \
      "$(bash_cmd "R=$RCPT; echo 1757000000 > \"\$R\"")"
probe 2 "bash: cd-split path -> BLOCK"                                       "$(bash_cmd "cd .claude/state && echo 1757000000 >$(basename "$RCPT")")"
probe 2 "bash: python heredoc open() -> BLOCK (this repo's DOMINANT edit idiom)" \
      "$(bash_cmd "python3 - <<'X'
open('$RCPT','w').write('1757000000')
X")"
probe 2 "bash: node writeFileSync -> BLOCK"                                  "$(bash_cmd "node -e \"require('fs').writeFileSync('$RCPT','1')\"")"

echo "--- ...but READ-ONLY investigation must stay open, or the gate gets deleted ---"
probe 0 "bash: cat the receipt -> ALLOW"                    "$(bash_cmd "cat $RCPT")"
probe 0 "bash: cat with 2>/dev/null -> ALLOW (a redirect that is not a write)" "$(bash_cmd "cat $RCPT 2>/dev/null")"
probe 0 "bash: rm the receipt -> ALLOW (removing one makes the gate STRICTER)" "$(bash_cmd "rm -f $RCPT")"
probe 0 "bash: an ordinary redirect elsewhere -> ALLOW"     "$(bash_cmd "make ci > /tmp/ci.log 2>&1")"
probe 0 "bash: a commit message containing an arrow -> ALLOW" "$(bash_cmd "git commit -m 'fix: a -> b'")"

echo "--- the receipt VALUE must be a plausible PAST timestamp ---"
# A 3-byte `inf` used to clear this gate FOREVER, past every re-arm.
for v in inf 1e999 nan "" -5 "$(( $(date +%s) + 86400 ))"; do
  printf '%s' "$v" > "$RECEIPT"
  probe 2 "receipt=$(printf '%s' "${v:-<empty>}" | cut -c1-12) -> BLOCK (not a plausible past epoch)" "$(gwrite)"
done
rm -f "$RECEIPT"

echo "--- minting: a ROSTER agent clears; PROSE does not ---"
mint_probe() { # <label> <should-mint 0|1> <json>
  rm -f "$TMP/.claude/state/adversary-mint.receipt"
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$TMP" python3 "$HOOK" >/dev/null 2>&1
  if [ -f "$TMP/.claude/state/adversary-mint.receipt" ]; then got=1; else got=0; fi
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 (minted=$got want=$2)"; fi
}
# PLANT A ROSTER, or these two cases assert behaviour the box cannot exercise. `_roster_pattern()`
# reads ~/.claude/agents and <project>/.claude/agents and returns None when NEITHER is readable, in
# which case the hook FALLS BACK to a bare `"adversary" in blob` -- a deliberate fail-open ("a gate
# that cannot be cleared blocks all work"). On this box ~/.claude/agents holds the roster, so the
# roster path was taken and the prose case passed; in CI `git ls-files .claude/agents/` is 0 and
# $HOME has none, so the FALLBACK ran, the prose matched, and the case failed. Green here, red
# there, for weeks -- the fast set does not run per-PR (B571) and the weekly was already red (B573).
# Planting into the temp project makes the roster path deterministic on ANY box: the two
# directories are UNIONed, so adding one is enough.
mkdir -p "$TMP/.claude/agents"
: > "$TMP/.claude/agents/adversary-docker.md"
mint_probe "Workflow naming a roster agent -> MINTS" 1 \
  '{"session_id":"mint","tool_name":"Workflow","tool_input":{"script":"const L=[{a: adversary-docker }]"}}'
mint_probe "Workflow PROSE 'summarise the adversary findings' -> mints NOTHING" 0 \
  '{"session_id":"mint","tool_name":"Workflow","tool_input":{"prompt":"summarise the adversary findings"}}'

# THE OTHER ARM, asserted rather than left to whichever box runs the suite: with NO roster readable
# the hook falls back to the substring ON PURPOSE. Neutralise BOTH directories -- $HOME (expanduser
# honours it) and the project -- so the fallback is what actually runs.
_noroster="$TMP/noroster"; mkdir -p "$_noroster"
_rcp="$_noroster/.claude/state/adversary-mint.receipt"
rm -f "$_rcp"
printf '%s' '{"session_id":"mint","tool_name":"Workflow","tool_input":{"prompt":"summarise the adversary findings"}}' \
  | HOME="$_noroster" CLAUDE_PROJECT_DIR="$_noroster" python3 "$HOOK" >/dev/null 2>&1
if [ -f "$_rcp" ]; then
  ok "with NO roster readable the hook FALLS BACK to the substring (fail-open, by design)"
else
  bad "the no-roster fallback did not mint — a gate that cannot be cleared blocks all work"
fi
mint_probe "Agent, roster subagent_type -> MINTS" 1 \
  '{"session_id":"mint","tool_name":"Agent","tool_input":{"subagent_type":"vks-adversary"}}'
mint_probe "Agent, 37 chars of prose -> mints NOTHING (it reopened the hole once)" 0 \
  '{"session_id":"mint","tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"REFUTE this claim: kaniko needs root."}}'

echo "--- NotebookEdit carries notebook_path, not file_path ---"
probe 2 "NotebookEdit to a guarded path -> BLOCK (it used to resolve EMPTY and fall through)" \
  "$(printf '{"session_id":"%s","tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s/scripts/n.ipynb"}}' "$SID" "$TMP")"

if [ "$fail" -eq 0 ]; then echo "PASS: adversary-first gate re-arms on every commit"
else echo "FAIL: re-arm gate has a hole" >&2; fi
exit "$fail"
