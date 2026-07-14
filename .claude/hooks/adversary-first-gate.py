#!/usr/bin/env python3
"""
adversary-first-gate.py — a PreToolUse hook that makes RULE ZERO (trigger 2) MECHANICAL.

WHY THIS EXISTS (2026-07-14).

CLAUDE.md's RULE ZERO already says, in bold: "BEFORE you implement — the moment you have a DESIGN,
a DECISION, a root-cause CLAIM, or a plan ... Always *before* writing the code."

It was ignored. A session designed "carry the whole toolchain across the air gap", wrote the code,
built a test, and reported it GREEN — with no adversary anywhere. The user had to type "spin
adversary" by hand. The adversaries then immediately found, among other things:
  - the bundle carried helm (62 MB) and ZERO CHARTS, so the DEFAULT ingress could never install
    on the air-gapped box;
  - the new test was a FALSE GREEN (`docker run` without `-i` -> bash read an empty script,
    exited 0, and every assertion was silently skipped);
and a plain enumeration found `awk` missing from Photon, `envsubst` missing from the bootstrap, and
a no-internet box that retried for >2 MINUTES before failing with an error naming the wrong thing.

Every one of those was findable BEFORE the first line of code. That is the whole point of the rule,
and prose did not make it happen. This does.

WHAT IT DOES. Writing to the operator-flow code (scripts/, Makefile, jumpbox/, k8s/, tekton/) is
BLOCKED until an adversary has been engaged in this session. Spawning one clears the gate for the
rest of the session (it is a "did you think before you typed" gate, not a per-edit tax).

WHAT IT DELIBERATELY DOES NOT GATE:
  - docs/, README, CLAUDE.md, .env.example, diagrams — prose and config are where you WRITE UP the
    plan; gating them would make the rule unfollowable.
  - subagents — they are already denied all writes by subagent-readonly-gate.py.
  - .claude/ itself — you must be able to fix the hook when it is wrong.

ESCAPE HATCH: ADVERSARY_GATE_OFF=1 in the environment. Deliberately trivial: this is a reflex aid,
not a security boundary, and a gate you cannot turn off when it is wrong is a gate people rip out.
Using it is a choice you are making on the record.

Exit 0 = allow. Exit 2 = BLOCK (stderr is fed back to the calling agent).
Fails OPEN on anything unexpected: a hook that crashes must never wedge a session.
"""
import json
import os
import sys

# The operator-flow code: the things that RUN on a machine we may not be able to reach again.
# A mistake here is a mistake on someone's air-gapped jump box. That is what earns the gate.
GUARDED_PREFIXES = (
    "scripts/",
    "jumpbox/",
    "k8s/",
    "tekton/",
    "apps/",
)
GUARDED_FILES = ("Makefile",)

# Prose/config: NOT gated. This is where the thinking gets written down.
EXEMPT_PREFIXES = (
    "docs/",
    ".claude/",
    ".github/",
)


def _receipt_path(session_id: str) -> str:
    root = os.environ.get("CLAUDE_PROJECT_DIR") or "."
    d = os.path.join(root, ".claude", "state")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"adversary-{session_id or 'nosession'}.receipt")


def _is_adversary_spawn(data: dict) -> bool:
    """An Agent spawn whose subagent_type is an adversary, or a Workflow that runs one."""
    ti = data.get("tool_input") or {}
    tool = data.get("tool_name")
    if tool == "Agent":
        return "adversary" in str(ti.get("subagent_type", "")).lower()
    if tool == "Workflow":
        # A workflow script that spawns adversary agents counts — it is the sanctioned way to run
        # them (schema-forced output; a fire-and-forget background Agent delivers nothing).
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
    tool = data.get("tool_name")

    # 1. Engaging an adversary CLEARS the gate for this session.
    if _is_adversary_spawn(data):
        try:
            open(_receipt_path(session), "w").write("engaged\n")
        except Exception:
            pass  # fail OPEN: never block a legitimate spawn because we could not write a file
        return 0

    if tool not in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        return 0

    path = (data.get("tool_input") or {}).get("file_path") or ""
    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    try:
        rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root))
    except Exception:
        return 0
    rel = rel.replace(os.sep, "/")

    if rel.startswith("../"):          # outside the project — not ours to police
        return 0
    if rel.startswith(EXEMPT_PREFIXES):
        return 0
    if not (rel.startswith(GUARDED_PREFIXES) or rel in GUARDED_FILES):
        return 0

    if os.path.exists(_receipt_path(session)):
        return 0

    sys.stderr.write(
        "BLOCKED by adversary-first-gate: no adversary has been run in this session.\n"
        f"  refused: write to {rel}\n"
        "\n"
        "This is CLAUDE.md RULE ZERO, trigger 2, made mechanical: the adversary reviews the DESIGN,\n"
        "BEFORE the code exists. It is a gate because prose did not hold — the last session that\n"
        "skipped it shipped a bundle whose default ingress could never install, and a test that\n"
        "passed while executing NOTHING.\n"
        "\n"
        "Before you write operator-flow code:\n"
        "  1. DERIVE THE CONTRACT FROM THE CODE, do not recall it. If this change alters what one\n"
        "     side must provide to the other (the air gap, a wire format, an API), enumerate every\n"
        "     consumer and everything it invokes -- grep for the binaries, the `helm repo add`s, the\n"
        "     https:// fetches -- and mark each one carried / provisioned / MISSING. Print the\n"
        "     denominator. A list written from memory is not a contract; a grep is.\n"
        "  2. RUN THE ADVERSARY ON THAT DESIGN:\n"
        "       vks-adversary     — VKS/K8s/ArgoCD/Harbor/Istio/Tekton, the REAL LAB\n"
        "       docker-adversary  — docker/podman/containerd/registry trust, the DAEMON and a COLD box\n"
        "     Use a Workflow (schema-forced) or a SYNCHRONOUS Agent (run_in_background: false).\n"
        "     A fire-and-forget background agent delivers nothing: measured 0/4.\n"
        "  3. Then write the code.\n"
        "\n"
        "Docs, README, CLAUDE.md and .env.example are NOT gated — write the plan there first.\n"
        "Override (on the record): ADVERSARY_GATE_OFF=1\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
