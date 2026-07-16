#!/usr/bin/env python3
"""
adversary-first-gate.py — a PreToolUse hook that makes RULE ZERO (trigger 2) MECHANICAL.

WHY THIS EXISTS (2026-07-14).

CLAUDE.md's RULE ZERO already says, in bold: "BEFORE you implement — the moment you have a DESIGN,
a DECISION, a root-cause CLAIM, or a plan ... Always *before* writing the code."

It was ignored. A session designed "carry the whole toolchain across the air gap", wrote the code,
built a test, and reported it GREEN — with no adversary anywhere. The user had to type "spin
adversary" by hand. The adversaries then immediately found real, shipped-in defects.

WHAT IT DOES. Writing to the operator-facing product — the code (scripts/, Makefile, jumpbox/, k8s/,
tekton/, apps/) AND the operator docs (docs/, README.md) — is BLOCKED unless an adversary has been
engaged SINCE THE LAST COMMIT.

RE-ARM ON COMMIT (2026-07-14, second correction). The first version cleared the gate for the WHOLE
SESSION the instant any adversary ran once — so a design review of task A authorized the unrelated
implementation of task B, three tasks later, that no adversary ever saw. That is exactly how a batch
of provenance-doc facts got re-graded and rewritten with zero review: three opening design reviews
had written a session-lifetime receipt, and every write after that sailed through a gate that was
mechanically satisfied and substantively blind.

The fix: the receipt records the WALL-CLOCK TIME of the adversary engagement, and a guarded write is
allowed only when that time is NEWER than the repo's HEAD commit. Committing therefore invalidates
the receipt — the next unit of work needs its own adversary pass. "Reviewed the design three commits
ago" no longer authorizes "the code I am typing now".

Residual this deliberately does NOT close (named, not hidden): within a single commit's worth of work
one review authorizes every edit, including unrelated ones (scoping the receipt to the reviewed files
would close it — not built yet); CLAUDE.md is exempt (you must be able to write the plan first); and
no gate can verify the review was actually INTEGRATED, only that it happened.

WHAT IT DELIBERATELY DOES NOT GATE:
  - CLAUDE.md — it IS the plan/backlog.
  - .claude/ itself — you must be able to fix a hook that is wrong.
  - subagents — they are already denied all writes by subagent-readonly-gate.py.

ESCAPE HATCH: ADVERSARY_GATE_OFF=1 in the environment. A reflex aid, not a security boundary; using
it is a choice on the record.

Exit 0 = allow. Exit 2 = BLOCK (stderr is fed back to the calling agent).
Fails OPEN on anything unexpected: a hook that crashes must never wedge a session.
"""
import json
import os
import subprocess
import sys
import time

GUARDED_PREFIXES = (
    "docs/",
    "README.md",
    "scripts/",
    "jumpbox/",
    "k8s/",
    "tekton/",
    "apps/",
)
GUARDED_FILES = ("Makefile",)

EXEMPT_PREFIXES = (
    ".claude/",
    ".github/",
)
EXEMPT_FILES = ("CLAUDE.md",)


def _project_root() -> str:
    return os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def _receipt_path(session_id: str) -> str:
    d = os.path.join(_project_root(), ".claude", "state")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"adversary-{session_id or 'nosession'}.receipt")


def _receipt_epoch(session_id: str):
    """The wall-clock time of the last adversary engagement this session, or None if there is no
    valid receipt (missing, or an old content-free 'engaged' receipt from before the re-arm fix)."""
    try:
        with open(_receipt_path(session_id)) as f:
            return float(f.read().strip())
    except Exception:
        return None


def _head_commit_epoch() -> int:
    """HEAD's committer timestamp, or 0 if it cannot be determined (empty repo / no git). 0 means a
    valid receipt always passes — we fail OPEN on git uncertainty, and fail CLOSED (below) only on a
    receipt that is missing, unparseable, or provably older than a real commit."""
    try:
        out = subprocess.run(
            ["git", "-C", _project_root(), "log", "-1", "--format=%ct"],
            capture_output=True, text=True, timeout=5,
        )
        return int(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip() else 0
    except Exception:
        return 0


def _is_adversary_spawn(data: dict) -> bool:
    ti = data.get("tool_input") or {}
    tool = data.get("tool_name")
    if tool == "Agent":
        return "adversary" in str(ti.get("subagent_type", "")).lower()
    if tool == "Workflow":
        blob = f"{ti.get('script','')}{ti.get('name','')}{ti.get('prompt','')}".lower()
        return "adversary" in blob
    return False


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0  # fail OPEN

    if os.environ.get("ADVERSARY_GATE_OFF") == "1":
        return 0

    # Subagents are handled by subagent-readonly-gate.py (they may not write at all).
    if data.get("agent_id") or data.get("agent_type"):
        return 0

    session = str(data.get("session_id") or "")

    # Engaging an adversary STAMPS the receipt with the current time. This is what a later guarded
    # write is checked against: valid only until the next commit moves HEAD past it.
    if _is_adversary_spawn(data):
        try:
            open(_receipt_path(session), "w").write(f"{time.time()}\n")
        except Exception:
            pass  # fail OPEN: never block a legitimate spawn because we could not write a file
        return 0

    if data.get("tool_name") not in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        return 0

    path = (data.get("tool_input") or {}).get("file_path") or ""
    root = _project_root()
    try:
        rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root))
    except Exception:
        return 0
    rel = rel.replace(os.sep, "/")

    if rel.startswith("../"):          # outside the project — not ours to police
        return 0
    if rel.startswith(EXEMPT_PREFIXES) or rel in EXEMPT_FILES:
        return 0
    if not (rel.startswith(GUARDED_PREFIXES) or rel in GUARDED_FILES):
        return 0

    # The gate: a guarded write needs an adversary engaged SINCE the HEAD commit.
    rc_epoch = _receipt_epoch(session)
    if rc_epoch is not None and rc_epoch > _head_commit_epoch():
        return 0

    committed_since = rc_epoch is not None  # a receipt exists but a commit moved past it
    sys.stderr.write(
        "BLOCKED by adversary-first-gate: "
        + ("you have COMMITTED since the last adversary review.\n"
           if committed_since else
           "no adversary has been engaged since the last commit.\n")
        + f"  refused: write to {rel}\n"
        "\n"
        "This is CLAUDE.md RULE ZERO, trigger 2, made mechanical AND re-armed per commit: a review\n"
        "authorizes writes only until the next commit. 'Reviewed the design three commits ago' does\n"
        "NOT authorize the code you are typing now — that is the exact hole that let a batch of\n"
        "provenance facts get rewritten unreviewed on the back of a design review from three tasks\n"
        "earlier.\n"
        "\n"
        "Before you write operator-flow code:\n"
        "  1. DERIVE THE CONTRACT FROM THE CODE (grep it, do not recall it). If this change alters\n"
        "     what one side must provide to another, enumerate every consumer and mark each\n"
        "     carried / provisioned / MISSING. Print the denominator.\n"
        "  2. RUN THE ADVERSARY ON THIS CHANGE:\n"
        "       vks-adversary     — VKS/K8s/ArgoCD/Harbor/Istio/Tekton, the REAL LAB\n"
        "       adversary-docker  — docker/podman/containerd/registry trust, the DAEMON and a COLD box\n"
        "       (+ global roster: adversary-java, adversary-bash-git-cli, adversary-go, adversary-k8s, adversary-identity-auth, adversary-security-secrets)\n"
        "     Use a Workflow (schema-forced) or a SYNCHRONOUS Agent (run_in_background: false).\n"
        "     A fire-and-forget background agent delivers nothing: measured 0/4.\n"
        "  3. Then write the code — before your next commit.\n"
        "\n"
        "CLAUDE.md is NOT gated — write the plan there first. Override (on the record): ADVERSARY_GATE_OFF=1\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
