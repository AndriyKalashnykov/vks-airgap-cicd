#!/usr/bin/env python3
"""
no-gate-in-commit-chain.py — refuse a Bash command that runs a GATE and a git COMMIT/PUSH in the SAME
statement.

WHY. The portfolio rules call this "the single most-violated rule": a gate's result is ONLY its own `rc`,
captured on its own line. Any pipe, `grep`, `tail`, `&&` or `||` between the gate and the commit decision
lets a FAILED gate produce a green-looking commit:

    make ci 2>&1 | tail -3 && git commit -m ...      # commits on TAIL's status. `make ci` FAILED.
    npm run lint | grep -i error || echo clean && git commit ...   # `grep || echo` always exits 0
    make test; rc=$?; [ $rc -ne 0 ] && grep ... ; git add . && git commit ...   # the `&&` fires anyway

It has recurred five times across five sessions, INCLUDING immediately after being written down. Prose
demonstrably does not stop it. This does.

THE RULE IT ENFORCES — the mechanical form, copy-paste, no improvisation:

    <gate> > /tmp/g.log 2>&1; rc=$?          # gate ALONE, on its own line
    [ $rc -eq 0 ] || { echo FAILED; tail -20 /tmp/g.log; exit 1; }
    # ONLY past this point may git add/commit/push appear, as SEPARATE statements.

Exit 0 = allow. Exit 2 = BLOCK. Fails OPEN on unexpected input.
Override (on the record): GATE_CHAIN_OFF=1
"""
import json
import os
import re
import sys

# Things whose exit code is a VERDICT you are about to act on.
GATE = re.compile(
    r"""(?:^|[;&|`]|\$\()\s*
        (?:sudo\s+)?
        (?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*
        (?:
            make\s+(?:ci|check|test|lint|static-check|docs-lint|sec|validate|verify|e2e[\w-]*|[\w-]*check[\w-]*)
          | (?:npm|pnpm|yarn)\s+(?:run\s+)?(?:test|lint|build|check)
          | (?:pytest|tox|go\s+test|cargo\s+test|dotnet\s+test|mvn\s+(?:test|verify)|gradle\s+\w*test)
          | shellcheck | markdownlint | yamllint | hadolint | trivy | gitleaks | actionlint
        )\b
    """,
    re.VERBOSE | re.IGNORECASE,
)

# The decision you must not couple to it.
COMMIT = re.compile(
    r"""(?:^|[;&|`]|\$\()\s*
        (?:sudo\s+)?
        (?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\$\([^)]*\)|\S*)\s+)*
        (?:/\S*/)?
        (?:
            git(?:\s+(?:-C\s+\S+|-c\s+\S+|--git-dir=\S+))*\s+(?:commit|push|merge|tag)
          | gh\s+(?:pr\s+(?:create|merge)|release\s+create)
        )\b
    """,
    re.VERBOSE | re.IGNORECASE,
)

# A commit MESSAGE is DATA, not command structure. `git commit -m "make ci && git commit"` is ONE
# commit, not a chain — the gate/commit tokens inside the message must not be matched. Strip the
# argument of every message-bearing flag (-m/--message string, -F/--file operand, combined shorts
# like -am) BEFORE the GATE/COMMIT search. A gate token that survives is a real execution; one that
# was inside a message is correctly erased.
MESSAGE_ARG = re.compile(
    r"""(?:^|\s)
        (?:--message|--file|-[A-Za-z]*[mF])   # --message/--file, or a short cluster ending in m/F (-m,-am,-F)
        (?:=|\s+)
        (?:"[^"]*"|'[^']*'|\S+)               # quoted string or a bare token
    """,
    re.VERBOSE,
)


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # fail OPEN

    if os.environ.get("GATE_CHAIN_OFF") == "1":
        return 0
    if data.get("tool_name") != "Bash":
        return 0

    command = (data.get("tool_input") or {}).get("command") or ""

    # A heredoc body is DATA, not commands — a commit message quoting `make ci && git commit` must not
    # trip the gate. Strip heredoc bodies before matching.
    stripped = re.sub(r"<<-?\s*'?\w+'?\n.*?\n\w+\n", "\n", command, flags=re.DOTALL)

    # ...and strip commit-message arguments, so a message that QUOTES `make ci && git commit` is not
    # read as a chain (the live false-positive this hook shipped with — it blocked its own bug report).
    stripped = MESSAGE_ARG.sub(" ", stripped)

    gate = GATE.search(stripped)
    commit = COMMIT.search(stripped)
    if not (gate and commit):
        return 0

    sys.stderr.write(
        "BLOCKED by no-gate-in-commit-chain: a GATE and a COMMIT are in the SAME shell statement.\n"
        f"  gate:   ...{stripped[max(0, gate.start()-10):gate.end()+30].strip()}...\n"
        f"  commit: ...{stripped[max(0, commit.start()-10):commit.end()+30].strip()}...\n"
        "\n"
        "A gate's result is ONLY its own `rc`, captured on its own line. A pipe, `grep`, `tail`, `&&` or\n"
        "`||` between the gate and the commit lets a FAILED gate produce a green-looking commit — this has\n"
        "recurred FIVE times across five sessions, including right after it was written down.\n"
        "\n"
        "Split it. Run the gate alone, read its rc, and only then commit — as SEPARATE tool calls:\n"
        "\n"
        "    <gate> > /tmp/g.log 2>&1; rc=$?\n"
        "    [ $rc -eq 0 ] || { echo 'GATE FAILED'; tail -20 /tmp/g.log; exit 1; }\n"
        "    # ...then, in the NEXT command: git add / git commit / git push\n"
        "\n"
        "Override (on the record): GATE_CHAIN_OFF=1\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
