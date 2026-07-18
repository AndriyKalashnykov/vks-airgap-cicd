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
engaged SINCE THE LAST NON-EXEMPT COMMIT (B45 — an exempt-only docs/handoff/CI/plan commit does not re-arm).

RE-ARM ON COMMIT (2026-07-14, second correction). The first version cleared the gate for the WHOLE
SESSION the instant any adversary ran once — so a design review of task A authorized the unrelated
implementation of task B, three tasks later, that no adversary ever saw. That is exactly how a batch
of provenance-doc facts got re-graded and rewritten with zero review: three opening design reviews
had written a session-lifetime receipt, and every write after that sailed through a gate that was
mechanically satisfied and substantively blind.

The fix: the receipt records the WALL-CLOCK TIME of the adversary engagement, and a guarded write is
allowed only when that time is NEWER than the repo's most recent NON-EXEMPT commit (B45). Committing
GUARDED (or neither) work therefore invalidates the receipt — the next unit needs its own adversary
pass — while an EXEMPT-only commit (.claude/, .github/, CLAUDE.md — the ritual "refresh the HANDOFF,
commit, continue") does NOT re-arm, so it no longer strands a still-valid code review. "Reviewed the
design three commits ago" no longer authorizes "the code I am typing now".

Residual this deliberately does NOT close (named, not hidden): within a unit of work — now spanning any
intervening EXEMPT-only commits (B45) — one review authorizes every guarded edit, including unrelated
ones. Guarded code still enters HISTORY only via a non-exempt commit (the re-arm event), so no
unreviewed guarded code SHIPS on a stale receipt; the window is only wider in TIME, not in kind.
Scoping the receipt to the reviewed FILES would close it, but a prompt-file-scoped receipt was REFUTED
2026-07-16 (the prompt that names a file authorises it) — do not attempt it. CLAUDE.md is exempt (you
must be able to write the plan first); and no gate can verify the review was INTEGRATED, only that it
happened.

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


def _last_nonexempt_commit_epoch() -> int:
    """The committer time of the most recent commit that touched a NON-EXEMPT path — the boundary a
    guarded-write receipt is checked against (B45). A commit whose diff is ENTIRELY exempt (.claude/,
    .github/, CLAUDE.md — a handoff / CI / plan commit) does NOT re-arm the gate: it is not new guarded
    design, so it must not strand a code review from before it. The re-arm still fires for any commit
    touching a guarded OR neither path, and guarded code enters history ONLY via such a commit — so no
    unreviewed guarded code can SHIP on a stale receipt (the residual is a wider WRITE window within a
    unit of work, unchanged in KIND from the note above; the file-scoped receipt that would close it was
    REFUTED 2026-07-16, so do not attempt it). This keys on git's OWN recorded file-list, NOT any prompt
    — an agent can choose what to commit but cannot make git record `scripts/x.sh` as an exempt path, so
    it does not re-enter the refuted prompt-authorises-the-file trap. The exclude pathspec is DERIVED
    from EXEMPT_PREFIXES/EXEMPT_FILES, never hand-typed. Falls back to _head_commit_epoch() (conservative
    — identical to pre-B45) on an empty result or git failure."""
    excludes = [f":(exclude){p.rstrip('/')}" for p in EXEMPT_PREFIXES] + [f":(exclude){f}" for f in EXEMPT_FILES]
    try:
        out = subprocess.run(
            ["git", "-C", _project_root(), "log", "-1", "--format=%ct", "--", ".", *excludes],
            capture_output=True, text=True, timeout=5,
        )
        if out.returncode == 0 and out.stdout.strip():
            return int(out.stdout.strip())
    except Exception:
        pass
    return _head_commit_epoch()


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
    # write is checked against: valid only until the next NON-EXEMPT commit moves the boundary past it (B45).
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

    # The gate: a guarded write needs an adversary engaged SINCE the last NON-EXEMPT commit (B45 — an
    # exempt-only docs/handoff/CI/plan commit does not re-arm).
    rc_epoch = _receipt_epoch(session)
    if rc_epoch is not None and rc_epoch > _last_nonexempt_commit_epoch():
        return 0

    committed_since = rc_epoch is not None  # a receipt exists but a commit moved past it
    sys.stderr.write(
        "BLOCKED by adversary-first-gate: "
        + ("you have COMMITTED since the last adversary review.\n"
           if committed_since else
           "no adversary has been engaged since the last non-exempt commit.\n")
        + f"  refused: write to {rel}\n"
        "\n"
        "This is CLAUDE.md RULE ZERO, trigger 2, made mechanical AND re-armed per NON-EXEMPT commit: a\n"
        "review authorizes writes only until the next non-exempt commit (an exempt-only docs/CI/plan\n"
        "commit does not re-arm). 'Reviewed the design three commits ago' does\n"
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
