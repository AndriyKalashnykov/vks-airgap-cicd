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
apps/) AND the operator docs (docs/, README.md) — is BLOCKED unless an adversary has been
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
  - CLAUDE.md and BACKLOG.md — together they ARE the plan/backlog (the backlog moved out of
    CLAUDE.md in f7f6c30, 2026-07-22; see the ROT WATCH note on EXEMPT_FILES below).
  - .claude/ itself — you must be able to fix a hook that is wrong.
  - subagents — they are already denied all writes by subagent-readonly-gate.py.

ESCAPE HATCH: ADVERSARY_GATE_OFF=1 in the environment. A reflex aid, not a security boundary; using
it is a choice on the record.

Exit 0 = allow. Exit 2 = BLOCK (stderr is fed back to the calling agent).
Fails OPEN on anything unexpected: a hook that crashes must never wedge a session.
"""
import json
import math
import os
import re
import subprocess
import sys
import time

GUARDED_PREFIXES = (
    "docs/",
    "README.md",
    "scripts/",
    "jumpbox/",
    "k8s/",
    # "tekton/" was here and was DEAD: `git ls-files tekton` == 0 (measured 2026-08-16). The Tekton
    # manifests live at k8s/tekton/ (9 files), already covered by "k8s/". A guarded prefix matching
    # nothing is not harmless -- it reads as coverage this tuple does not have.
    "apps/",
)
GUARDED_FILES = ("Makefile",)

EXEMPT_PREFIXES = (
    ".claude/",
    ".github/",
)
# ROT WATCH — this tracks THE PLAN/BACKLOG FILE, whatever it is currently called.
#   CLAUDE.md held the backlog until f7f6c30 (2026-07-22, PR #396) moved it out: BACKLOG.md +70,
#   CLAUDE.md -52. This tuple did NOT follow for ~3 weeks, so a bookkeeping commit ("close row B92")
#   re-armed the gate and destroyed a legitimate design review. MEASURED over the last 200 commits:
#   24 are BACKLOG-only, and 25 (12.5%, 1 in 8) stopped stranding a review once BACKLOG.md was added.
#   It is NOT a bypass: a git exclude pathspec is per-FILE, so a MIXED commit (BACKLOG.md + code)
#   still re-arms -- verified by running _last_nonexempt_commit_epoch() with and without the entry
#   over 26 real mixed commits; the boundary was IDENTICAL (8caff30) both ways.
#   RESIDUAL, named not hidden: a backlog row CAN carry a design (72 rows, 46 cite an adversary, 12
#   carry file:line prescriptions), so a design written there is now unreviewed for longer. That was
#   ALREADY true -- writes to BACKLOG.md were never guarded -- and the already-exempt CLAUDE.md is
#   at least as design-carrying. This widens the residual in TIME, it does not create a new kind.
#   If the plan file is renamed again, edit THIS tuple in the same commit.
EXEMPT_FILES = ("CLAUDE.md", "BACKLOG.md")


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
            v = float(f.read().strip())
    except Exception:
        return None
    # ⚠️ MEASURED 2026-09-07: `float("inf")` (and `1e999`) is GREATER THAN EVERY commit epoch, so a
    # THREE-BYTE receipt cleared this gate permanently — it survived every re-arm, forever. `nan`
    # and an empty file already failed closed; `inf` did not. A future-dated receipt is the same
    # defect with a bigger number, so bound the upper end too (60s of clock skew).
    # This closes the class INDEPENDENTLY of any matcher: whatever writes the file, the value must
    # be a plausible past timestamp.
    if not math.isfinite(v) or not (0 < v <= time.time() + 60):
        return None
    return v


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


# The roster, DERIVED from the agents directory — never an enumerated list here, which would rot the
# first time a specialist is added or renamed. An adversary agent TYPE is an identifier; the word
# "adversary" in a sentence is not.
def _roster_pattern():
    """A regex over the installed adversary agent TYPE names, or None if none can be read."""
    names = set()
    for d in (os.path.expanduser("~/.claude/agents"),
              os.path.join(_project_root(), ".claude", "agents")):
        try:
            for f in os.listdir(d):
                if f.endswith(".md") and "adversary" in f.lower():
                    names.add(os.path.splitext(f)[0])
        except Exception:
            continue
    if not names:
        return None
    return re.compile(r"\b(?:" + "|".join(re.escape(n) for n in sorted(names)) + r")\b", re.I)


# A prompt that ASSERTS an adversary role. Used ONLY to widen the Agent arm: `agents.md` PRESCRIBES
# inlining a persona into `general-purpose` when an agent file is too new to dispatch by name, and
# that path minted NOTHING — so doing the documented thing left you blocked. Measured: it catches 2
# such dispatches in this repo's transcripts. It can only turn a block into an allow.
# The floor that separates a pasted PERSONA from a sentence. See the use site for the measurement.
_ROLE_MIN_CHARS = 800
_ROLE = re.compile(
    r"(?:you\s+are\s+(?:a|an|the)\s+[^.\n]{0,60}?adversar(?:y|ial)"
    r"|adversar(?:y|ial)\s+(?:round|review|persona|reviewer)"
    r"|REFUTE\s+(?:this|the|my)\b)", re.I)


# ── THE BASH ARM: the RECEIPT, and nothing else. ─────────────────────────────────────────────────
#
# WHY IT EXISTS. The Edit/Write arm below already refuses a `Write` to the receipt — but the matcher
# had no `Bash`, so `printf 9 > .claude/state/adversary-<session>.receipt` minted a clearance with
# ONE command and every guarded write then sailed through. That SUBSUMES every question about when
# the receipt is minted: it does not matter, if the agent can simply write it.
#
# WHY IT DOES NOT GUARD THE GUARDED PATHS TOO. MEASURED 2026-09-07 over 27,299 real Bash commands
# from this repo's own transcripts: porting the sibling repo's full guarded-path arm matches 652
# (2.38%), of which 85% of the cp-arm catches are `/tmp/*.bak -> scripts/*` RED-PROOF RESTORES,
# while MISSING 2,644 `python3 - <<PY ... open(p,"w")` writes — this repo's DOMINANT editing idiom.
# It blocks the safe half of a mutate/restore cycle and permits the dangerous half, 4.4x more misses
# than catches. That is not a regex-quality problem and a better-aimed regex will not fix it: an
# interpreter body is unbounded. Do NOT "improve" this by widening it to guarded paths.
#
# THE PREDICATE IS A CONJUNCTION, NOT ADJACENCY, AND THAT IS THE WHOLE POINT. Requiring the write
# verb to sit NEXT TO the path is what leaves `R=<path>; echo 9 > "$R"`, `$HOME/...` and
# `cd .claude/state && echo 9 > x.receipt` unreachable — the three classes an adversary round called
# irreducible. Asking instead for "a receipt path ANYWHERE and a write construct ANYWHERE" reaches
# all three, because nothing legitimate does both. MEASURED: 13/13 forge shapes blocked (bare,
# single- AND double-quoted, $VAR, $HOME, python -c, python heredoc, perl, dd, cp, rsync, tee,
# cd-split), 11 of 27,299 commands matched (0.040%) — every one a command investigating this gate —
# and read-only investigation (`cat`/`ls`/`stat`/`grep`/`rm` on the receipt) is untouched, which
# matters because a gate that blocks its own evidence tools is one that gets deleted.
#
# ⚠️ NOT A BOUNDARY. It is a string matcher over shell; an interpreter can compose the path from
# pieces no regex sees. It is a reflex aid against the one-command forge, which is the only shape
# that was actually occurring.
_RCPT_FULL  = re.compile(r"\.claude/state/[^\s'\"]*\.receipt")
_RCPT_DIR   = re.compile(r"\.claude/state\b")
_RCPT_BASE  = re.compile(r"\badversary-[A-Za-z0-9_-]*\.receipt\b")
# ⚠️ THE `\s` THAT USED TO FOLLOW THE REDIRECT WAS A HOLE, and it made my own RED-proof a SUBSET:
# every forge shape I tested happened to put a space after `>`, so `echo 9 >.claude/state/x.receipt`
# — a ONE-COMMAND forge — sailed through a matcher I had just called 13/13. An implementation round
# measured 10 of 15 shapes bypassing. Dropping the `\s` and excluding only the two things a redirect
# can be that are NOT a write to a file takes it to 20/20 at ZERO extra cost: measured 0 false blocks
# on 10 legitimate read-only commands and the SAME 11 hits in 27,299 real commands (0.040%).
#   (?!\s*&)          `2>&1`, `>&2` — an fd DUP, not a file write.
#   (?!\s*/dev/null)  `cat <receipt> 2>/dev/null` is READING one; blocking it would take out the
#                     investigation tools, which is how a gate gets deleted.
_RCPT_WRITE = re.compile(
    r"(?<!-)>>?\|?(?!\s*&|\s*/dev/null)"   # (?<!-) keeps `git commit -m 'a -> b'` out
    r"|\btee\b|\bsponge\b|\btruncate\b"
    r"|\bsed\b[^|;&\n]*-i|\bperl\b[^|;&\n]*\s-\w*i"
    r"|\b(?:cp|mv|install|ln|rsync|dd)\s"
    r"|\bopen\s*\(|\bwrite_text\b|\bwriteFileSync\b|\bFile\.write\b|\bfputs?\b", re.I)


def _bash_forges_receipt(cmd: str) -> str:
    """The receipt path this command names, IF it also writes something. Empty string otherwise."""
    cmd = cmd or ""
    if not _RCPT_WRITE.search(cmd):
        return ""
    m = _RCPT_FULL.search(cmd)
    if m:
        return m.group(0)
    if _RCPT_DIR.search(cmd):             # the path split by a `cd`
        m = _RCPT_BASE.search(cmd)
        if m:
            return m.group(0)
    return ""


def _is_adversary_spawn(data: dict) -> bool:
    ti = data.get("tool_input") or {}
    tool = data.get("tool_name")
    roster = _roster_pattern()
    if tool == "Agent":
        st = str(ti.get("subagent_type", ""))
        if "adversary" in st.lower():
            return True
        # The PRESCRIBED inline-persona path (see _ROLE) — but a LENGTH floor, because the first
        # version of this arm reopened on `Agent` the exact prose self-mint that was just closed on
        # `Workflow`: MEASURED, `REFUTE this claim: kaniko needs root.` (37 chars, an ordinary
        # research prompt) minted a full clearance with no review and no shell. A pasted roster
        # persona is kilobytes. MEASURED on this repo's real dispatches: the two genuine inline
        # personas are 4308 and 4606 chars; the largest prose probe is 38. Any floor in (38, 4308]
        # separates them — 800 is 21x above the probes and 5x below the real personas.
        _blob = f"{ti.get('description','')}\n{ti.get('prompt','')}"
        return bool(_ROLE.search(_blob)) and len(_blob) >= _ROLE_MIN_CHARS
    if tool == "Workflow":
        blob = f"{ti.get('script','')}{ti.get('name','')}{ti.get('prompt','')}"
        # ⚠️ MEASURED 2026-09-07 over this repo's 11 real Workflow dispatches: the old test was a
        # BARE SUBSTRING over agent-authored prose, so `summarise the adversary findings` MINTED a
        # clearance with no review — a self-mint needing no shell at all, in a tool this hook
        # already matches. In every REAL round the word appears as a roster agent TYPE
        # (`agent: 'adversary-k8s'`), never as prose. Keying on the roster mints 10/11 — IDENTICAL
        # to the substring, so nothing legitimate was lost — while refusing both prose probes.
        # Fall back to the old behaviour if the roster cannot be read: a gate that cannot be
        # cleared blocks all work, and this is a reflex aid, not a boundary.
        if roster is not None:
            return bool(roster.search(blob))
        return "adversary" in blob.lower()
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

    _tool = data.get("tool_name")
    _ti = data.get("tool_input") or {}

    if _tool == "Bash":
        # A shell write that NAMES the receipt. `rel` is set to the receipt's own path so this falls
        # into the SAME receipt clause the Edit/Write arm uses below — one gate, not two.
        _hit = _bash_forges_receipt(str(_ti.get("command", "")))
        if not _hit:
            return 0
        rel = ".claude/state/" + os.path.basename(_hit)
        if not rel.endswith(".receipt"):
            rel += ".receipt"
    elif _tool in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
        # NotebookEdit carries `notebook_path`, NOT `file_path` — reading only the latter left every
        # notebook write resolving to an empty path, which fell through every arm below to return 0.
        path = _ti.get("file_path") or _ti.get("notebook_path") or ""
        if not path:
            return 0
        root = _project_root()
        try:
            rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root))
        except Exception:
            return 0
        rel = rel.replace(os.sep, "/")
    else:
        return 0

    if rel.startswith("../"):          # outside the project — not ours to police
        return 0
    # ⚠️ THE RECEIPT ITSELF IS GUARDED, even though `.claude/` is exempt. MEASURED 2026-08-23 in THIS
    #    repo: a plain `Write` to .claude/state/adversary-<session>.receipt returned rc=0, so the agent
    #    could FORGE ITS OWN CLEARANCE and the next guarded write sailed through. The filename is
    #    discoverable with `ls .claude/state/`. This clause exists in nested-vsphere-lab since
    #    2026-07-27 and was never ported here; the docstring's "the override belongs to the human" was
    #    FALSE in this repo until this line. Ported after an adversary round graded it CRITICAL.
    #    KNOWN RESIDUAL, declared not hidden: this arm is consulted on Edit/Write ONLY. This repo's
    #    matcher has NO `Bash` arm at all, so `printf x > .claude/state/*.receipt` still mints. That is
    #    the same F1 the lab repo hit on 2026-07-29; closing it here needs the Bash arm, which the same
    #    round REFUTED as a string matcher (17-18% false blocks, on running our own gates) in favour of
    #    a git pre-commit chokepoint. Tracked, not fixed here.
    if "/.claude/state/" in "/" + rel and rel.endswith(".receipt"):
        pass                                # fall through to the gate below — do NOT return 0
    elif rel.startswith(EXEMPT_PREFIXES) or rel in EXEMPT_FILES:
        return 0
    elif not (rel.startswith(GUARDED_PREFIXES) or rel in GUARDED_FILES):
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
