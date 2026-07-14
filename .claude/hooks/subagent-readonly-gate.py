#!/usr/bin/env python3
"""
subagent-readonly-gate.py — a PreToolUse hook that makes SUBAGENTS mechanically read-only.

WHY THIS EXISTS (2026-07-13). Both adversary agents are told "READ-ONLY, never commit/push" in
their system prompts. They ignored it: one ran `git checkout --` and DESTROYED a caller's
uncommitted work; another ran `git commit` + `git push` + `gh pr create` and opened a PR unbidden.

A PROMPT IS NOT A SANDBOX. This is the sandbox.

Note that `isolation: "worktree"` does NOT solve this on its own: a worktree shares the same remote
and the same credentials, so a subagent can still push from inside one. The CAPABILITY has to go.

HOW IT DISCRIMINATES. PreToolUse's stdin JSON carries `agent_id` / `agent_type` ONLY for subagents
(https://code.claude.com/docs/en/hooks.md). The main agent has neither — so it keeps full git/gh
access, which it needs, while every subagent is denied the mutating verbs.

Exit 0 = allow. Exit 2 = BLOCK (the reason on stderr is fed back to the calling agent).
Fails OPEN on malformed input: a hook that crashes must not wedge the session. It is a safety net
for a mistake, not a security boundary against a hostile actor.
"""
import json
import re
import sys

# Mutating verbs. Matched at a COMMAND POSITION (line start, or after ; | && || $( ` ) so that
# prose inside a quoted string — `echo "do not git push"` — is not matched, and so that a
# mutation hidden mid-chain (`grep -q x && git push`) IS. Read-only git (log/diff/show/status/
# rev-parse/ls-remote/cat-file/grep/blame/worktree list) is deliberately NOT here: it is the
# adversary's primary evidence tool and removing it is what makes the review worthless.
BLOCKED = re.compile(
    r"""(?:^|[;&|`]|\$\()\s*
        (?:sudo\s+)?
        (?:
            git\s+(?:commit|push|checkout|switch|reset|restore|stash|rebase|merge|cherry-pick
                     |am|apply|clean|rm|mv|add|tag|branch\s+-[dDmM]|update-ref|gc|prune
                     |filter-branch|worktree\s+(?:add|remove|prune))
          | gh\s+(?:pr\s+(?:create|edit|merge|close|reopen|comment|review|ready)
                  | release\s+(?:create|edit|delete|upload)
                  | issue\s+(?:create|edit|close|comment)
                  | repo\s+(?:create|delete|edit|fork|sync)
                  | api\s+.*?-X\s*(?:POST|PATCH|PUT|DELETE)
                  | workflow\s+run
                  | run\s+(?:rerun|cancel|delete))
        )\b
    """,
    re.VERBOSE | re.IGNORECASE,
)

# `gh api` with an explicit mutating method is caught above; a bare `gh api -f k=v` POSTs implicitly.
GH_API_IMPLICIT_POST = re.compile(
    r"""(?:^|[;&|`]|\$\()\s*(?:sudo\s+)?gh\s+api\b(?=.*(?:\s-f\s|\s-F\s|\s--field\s|\s--raw-field\s))""",
    re.VERBOSE | re.IGNORECASE,
)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # fail OPEN — never wedge the session on a parse error

    # Present ONLY for subagents. The main agent must keep git/gh: it is the one that ships.
    if not (data.get("agent_id") or data.get("agent_type")):
        return 0

    tool = data.get("tool_name")

    # THE HOLE THIS HOOK SHIPPED WITH (found 2026-07-14, the hard way). It matched ONLY `Bash`, so it
    # blocked a subagent's `git push` and cheerfully allowed it to rewrite the working tree with the
    # FILE TOOLS. That is exactly what happened: two adversary agents, both briefed READ-ONLY, edited
    # scripts/11-bundle.sh, scripts/20-bundle-load.sh, scripts/46-install-istio.sh, .env.example and
    # .gitignore via Edit/Write while this "sandbox" was installed and green. A sandbox with a door in
    # it is not a sandbox — and worse, it produced FALSE CONFIDENCE that the tree was protected.
    #
    # A reviewer's deliverable is a REPORT. It has no legitimate reason to write a file, ever. (One of
    # them also edited a script WHILE the main agent had a job executing it — bash reads scripts
    # incrementally, so the running job executed a fragment and died with a nonsense error.)
    if tool in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        who = data.get("agent_type") or data.get("agent_id") or "subagent"
        path = (data.get("tool_input") or {}).get("file_path") or "<unknown>"
        sys.stderr.write(
            f"BLOCKED by subagent-readonly-gate: '{who}' is READ-ONLY and may not write files.\n"
            f"  refused: {tool} {path}\n"
            f"\n"
            f"You are a REVIEWER. Your deliverable is your REPORT, not a patch.\n"
            f"Findings expressed as code are NOT a deliverable: they arrive unreviewed, they can\n"
            f"clobber the caller's in-flight work, and editing a script the caller is currently\n"
            f"executing corrupts that run.\n"
            f"\n"
            f"Instead, for each finding give: FILE:LINE, the defect, the failure it causes, and the\n"
            f"exact edit you would make. The caller will apply and verify it.\n"
        )
        return 2

    if tool != "Bash":
        return 0

    command = (data.get("tool_input") or {}).get("command") or ""
    if not (BLOCKED.search(command) or GH_API_IMPLICIT_POST.search(command)):
        return 0

    who = data.get("agent_type") or data.get("agent_id") or "subagent"
    sys.stderr.write(
        f"BLOCKED by subagent-readonly-gate: '{who}' is READ-ONLY and may not mutate the repo.\n"
        f"  refused: {command.strip()[:200]}\n"
        f"\n"
        f"You are a REVIEWER. Your deliverable is your REPORT, not a commit.\n"
        f"If you believe a change is needed, DESCRIBE IT (file:line + the exact edit) and let the\n"
        f"calling agent make it. Do not retry, and do not look for a way around this.\n"
        f"\n"
        f"Read-only git/gh is still available to you: log, diff, show, status, blame, ls-remote,\n"
        f"gh search, gh pr view/checks, gh run view, gh api (GET).\n"
        f"\n"
        f"(This gate exists because two adversaries previously destroyed uncommitted work and\n"
        f"opened a PR unbidden, despite being told READ-ONLY in their prompts.)\n"
    )
    return 2  # 2 = block, and feed stderr back to the agent


if __name__ == "__main__":
    sys.exit(main())
