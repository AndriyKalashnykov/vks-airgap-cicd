#!/usr/bin/env bash
# tree-stability.sh — refuse to report a gate's verdict if the TREE CHANGED WHILE THE GATE RAN.
#
# WHY THIS EXISTS. `make static-check` takes minutes and reads the working tree CONTINUOUSLY. Editing
# that tree mid-run makes the verdict measure a MIXTURE of two states, and it is silent in BOTH
# directions. MEASURED, three times in one session (2026-08-28):
#
#   GREEN THAT MEASURED NOTHING — two runs reported `115 test(s) run, 0 failed` for trees that no
#     longer existed. One was seconds from being quoted as evidence on a PR.
#   RED NAMING THE WRONG CAUSE — the parallel shellcheck pass read the pre-edit file and the serial
#     re-run read the post-edit one, so the gate reported "the PARALLEL pass failed but the SERIAL
#     pass found nothing ... the parallel invocation itself is broken (suspect nproc/-P/xargs)" over
#     a tree where nothing was wrong with xargs at all. That message sent the diagnosis into the
#     wrong file, which this repo treats as worse than a crash.
#
# Same defect as `bash` reading a script incrementally while you rewrite it, one level up: the
# artifact under measurement changed during the measurement.
#
# ⚠️ WHY NOT A WRAPPER THAT RUNS THE GATE IN A DETACHED WORKTREE. That was designed, drafted and
# REFUTED by an adversary round, and the refutation is worth keeping so it is not rebuilt:
#   * an EXPORTED `REPO_ROOT` defeats the isolation completely -- `lib/os.sh` resolves it only when
#     unset and then exports it, so the wrapper builds a pristine worktree, announces "your checkout
#     is not read", and reads the DIRTY main tree. Measured: `load_env` inside the worktree returned
#     the main checkout's HARBOR_URL.
#   * a detached worktree has NO untracked files by construction, so `make sec`'s working-tree
#     gitleaks leg -- the one that exists to catch a secret you are ABOUT TO COMMIT -- is
#     structurally blind there. Measured on a real gitignored file: `git status --porcelain` empty,
#     `gitleaks --no-git` finds 1.
#   * `.registry.lock` is per-REPO_ROOT, so per-worktree: the host-level serialization this repo
#     relies on is silently defeated (filed separately).
#   * it needs a COMMIT first, which re-arms the adversary-first gate, so the natural edit->gate->fix
#     loop becomes edit->commit->gate->BLOCKED.
# This costs 0.023s over 464 files -- 0.006% of an 11-minute run -- catches the three incidents that
# actually happened on a plain `make static-check`, needs no commit, keeps the gitignored coverage,
# works in CI unchanged, and NAMES the files that moved.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
cd "$ROOT" || exit 1

# Keyed on the ROOT so two worktrees do not overwrite each other's snapshot, and on the invoking
# make's PID so two runs in the same tree do not either. TMPDIR, not the repo: this file must never
# be something a gate can see, or it becomes its own mid-run change.
_key="$(printf '%s' "$ROOT" | cksum | tr -d ' \t' )"
SNAP="${TMPDIR:-/tmp}/.tree-stability-${_key}-${TREE_STABILITY_ID:-${PPID}}"

# mtime + size + path. NOT a content hash: this must be cheap enough that nobody is tempted to turn
# it off, and mtime+size catches every edit a human or an editor makes. `.git` is excluded because
# the gate itself runs git; build output and the state overlay are excluded because a gate is
# ALLOWED to write those -- flagging them would train people to ignore the warning, which is how a
# control dies.
_snapshot() {
  find . \
    -path ./.git -prune -o \
    -path ./bundle -prune -o \
    -path ./node_modules -prune -o \
    -name '.env.state' -prune -o \
    -path './secrets' -prune -o \
    -name '*.tsbuildinfo' -prune -o \
    -type f -printf '%p\t%T@\t%s\n' 2>/dev/null | LC_ALL=C sort
}
# ⚠️ PATH FIRST, AND SORTED BY IT. A first version emitted `mtime size path` and sorted the whole
# line, so touching a file moved its SORT POSITION and the diff reported it as one removal plus one
# addition plus a modification -- the same file named three times, which reads as three problems.
# TAB-separated so a path containing spaces still parses as one field.

case "${1:-}" in
  record)
    _snapshot > "$SNAP" 2>/dev/null
    exit 0 ;;
  verify)
    if [ ! -s "$SNAP" ]; then
      # ⚠️ SAY SO. A verify with no snapshot must not read as "verified" -- that is the vacuous green
      # this whole file exists to prevent, one level up.
      printf 'tree-stability: NO SNAPSHOT was taken, so nothing was verified.\n' >&2
      printf '                (run the gate through its own target, not by invoking this directly)\n' >&2
      exit 0
    fi
    now="$(mktemp)"; trap 'rm -f "$now"' EXIT
    _snapshot > "$now" 2>/dev/null
    if cmp -s "$SNAP" "$now"; then
      rm -f "$SNAP"
      exit 0
    fi
    printf '\n' >&2
    printf 'tree-stability: THE TREE CHANGED WHILE THIS GATE RAN — its verdict is NOT usable.\n' >&2
    printf '                It read a MIXTURE of two states, so a green measured nothing and a red\n' >&2
    printf '                may name the wrong cause. Re-run it against a tree you are not editing.\n' >&2
    printf '\n                what moved:\n' >&2
    # Field 3 is the path; a file that is added, removed, or touched all show up here.
    diff <(cut -f1 "$SNAP") <(cut -f1 "$now") 2>/dev/null \
      | grep -E '^[<>]' | sed 's/^< /                   removed: /; s/^> /                     added: /' >&2
    # Only files present in BOTH can be "modified"; join on the path, compare mtime+size.
    # Show WHAT changed, not just that something did: a bare filename sends the reader to guess.
    join -t "$(printf '\t')" -j 1 -o 0,1.2,1.3,2.2,2.3 "$SNAP" "$now" 2>/dev/null \
      | awk -F'\t' '$2 != $4 || $3 != $5 {
            printf "                  modified: %s   (mtime %s->%s, size %s->%s)\n", $1, $2, $4, $3, $5
          }' >&2
    rm -f "$SNAP"
    exit 1 ;;
  *)
    printf 'usage: tree-stability.sh record|verify\n' >&2
    exit 2 ;;
esac
