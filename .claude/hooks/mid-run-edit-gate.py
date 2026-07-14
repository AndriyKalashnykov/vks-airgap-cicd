#!/usr/bin/env python3
"""
mid-run-edit-gate.py — refuse to EDIT a file that a RUNNING process is currently EXECUTING.

WHY (2026-07-14, and it cost a 12 GB rebuild). `bash` reads a script INCREMENTALLY — it does not slurp
the file, it seeks. So editing a shell script while a job is running it makes the running shell read the
NEW bytes at its OLD offset. It then executes a fragment of a line, and dies with an error that points
nowhere:

    ./scripts/11-bundle.sh: line 185: none.: command not found

I did exactly this: backgrounded `make bundle`, then edited `scripts/11-bundle.sh` while it ran. I spent
the next several minutes debugging `none.` as if it were a code bug. The rule "never edit a script
mid-run" was already written down. Prose did not stop it; this does.

The same applies to a Makefile being executed, a python script under a running interpreter, and a config
file a live process re-reads.

HOW IT DETECTS: scan /proc for a process whose command line references this file AND whose argv[0] is an
interpreter/build tool (bash, sh, make, python, ...). That combination is what "a process is executing
this file" looks like. A `grep` or an editor mentioning the path is NOT matched (argv[0] filter), and the
hook excludes its own process tree.

Exit 0 = allow. Exit 2 = BLOCK. Fails OPEN on anything unexpected — a hook that crashes must not wedge a
session, and this is a safety net, not a security boundary.
"""
import json
import os
import sys

INTERPRETERS = ("bash", "sh", "dash", "zsh", "make", "python", "python3", "node", "perl", "ruby")

WATCHED_SUFFIXES = (".sh", ".py", ".mk", ".bash", ".mjs", ".js")
WATCHED_NAMES = ("Makefile", "makefile", "GNUmakefile")


def _ppid(pid: int) -> int:
    """Parent pid, read from /proc/<pid>/stat (field 4, after the possibly-space-containing comm)."""
    try:
        with open(f"/proc/{pid}/stat", "r") as f:
            data = f.read()
        return int(data[data.rindex(")") + 2:].split()[1])
    except Exception:
        return 0


def _ancestors() -> set:
    """Every pid from us up to init. THE SELF-MATCH IS THE BUG THIS PREVENTS.

    The shell that invoked this hook has the edited file's path IN ITS OWN COMMAND LINE (the agent's
    Bash call mentions it), and its argv[0] is `bash` — so a naive scan sees "a bash process executing
    this file" and blocks every edit, forever. That is the classic self-matching-pgrep trap, and the
    first version of this gate walked straight into it: it returned BLOCKED with nothing running.
    """
    seen, p = set(), os.getpid()
    while p and p not in seen:
        seen.add(p)
        p = _ppid(p)
    return seen


def _executing_pids(path_abs: str, path_rel: str):
    """PIDs whose argv[0] is an interpreter AND that carry this file as a STANDALONE argv element."""
    hits = []
    skip = _ancestors()
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        p = int(pid)
        if p in skip:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
        except Exception:
            continue
        if not argv:
            continue
        exe = os.path.basename(argv[0])
        # argv[0] must be an interpreter/build tool — `grep foo scripts/x.sh` must NOT match.
        if not any(exe == i or exe.startswith(i) for i in INTERPRETERS):
            continue
        # The file must be an ARGUMENT, not a substring of some longer string (e.g. an -c script body
        # that merely mentions the path). This is what separates "executing it" from "talking about it".
        args = argv[1:]
        if any(a == path_abs or a == path_rel or os.path.basename(a) == os.path.basename(path_abs)
               and (a.endswith(path_rel) or a.endswith(path_abs)) for a in args):
            hits.append((p, exe, " ".join(argv)[:120]))
    return hits


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # fail OPEN

    if os.environ.get("MID_RUN_EDIT_GATE_OFF") == "1":
        return 0

    if data.get("tool_name") not in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        return 0

    path = (data.get("tool_input") or {}).get("file_path") or ""
    if not path:
        return 0

    base = os.path.basename(path)
    if not (path.endswith(WATCHED_SUFFIXES) or base in WATCHED_NAMES):
        return 0  # only files something can EXECUTE

    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    path_abs = os.path.abspath(path)
    try:
        path_rel = os.path.relpath(path_abs, os.path.abspath(root))
    except Exception:
        path_rel = base

    try:
        hits = _executing_pids(path_abs, path_rel)
    except Exception:
        return 0  # fail OPEN

    if not hits:
        return 0

    who = "\n".join(f"    pid {p}  {exe}  {cmd}" for p, exe, cmd in hits[:4])
    sys.stderr.write(
        f"BLOCKED by mid-run-edit-gate: a RUNNING process is executing this file RIGHT NOW.\n"
        f"  refused: {data.get('tool_name')} {path_rel}\n"
        f"  running:\n{who}\n"
        f"\n"
        f"bash reads a script INCREMENTALLY. Editing it now makes the running shell read your NEW bytes\n"
        f"at its OLD byte offset: it executes a FRAGMENT of a line and dies with an error that names\n"
        f"nothing real (e.g. `line 185: none.: command not found`). You will then debug the wrong thing.\n"
        f"\n"
        f"Wait for the job to finish, or kill it, THEN edit.\n"
        f"Override only if you know why: MID_RUN_EDIT_GATE_OFF=1\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
