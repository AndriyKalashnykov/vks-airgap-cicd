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

# mtime + size + path, NOT a content hash -- and the reason is the SIZE OF THE HOLE, not the cost.
# MEASURED: sha256 over the same 3074 files is 0.286s against 0.016s, i.e. 18x but still 0.04% of an
# 11-minute run, so a cost argument would not discriminate. What does: mtime is nanosecond-precision
# here and every editor, `git checkout` and redirect moves it, so a content-identical-but-rewritten
# file is not a realistic miss. The genuine misses are that `-type f` sees no directory create or
# remove, and no MODE change -- and this repo does gate the `+x` bit.
#
# ⚠️ THE PRUNES ARE NAME-BASED, NOT PATH-ANCHORED, and `.claude` is the one that matters most.
#
# `-path ./node_modules` matches only the ROOT one. MEASURED on this checkout, all of it INSIDE the
# scope a root-anchored list leaves in: 1210 files under `apps/rust/rustwebapp/target`, 601 under
# `apps/nodejs/nodejswebapp/node_modules`, 63 dotnet `obj`+`bin`, 17 under `app/target`. A
# rust-analyzer / tsserver / dotnet LSP writes into those CONTINUOUSLY, needing no `make` at all, so
# an 11-minute run would false-fire for a reason the operator cannot act on. A control that fires on
# a clean run is a control that gets deleted.
#
# ⚠️ THE `.claude` EXCLUSION IS PATH-ANCHORED, and a `-name .claude` version of it OVERSHOT: it
# blinded the TWO TRACKED files under there -- `.claude/settings.json` and
# `.claude/hooks/adversary-first-gate.py`, the BLOCKING control that gates every write in this repo.
# `static-check` genuinely reads the latter: `test-adversary-gate-rearm.sh` carries no `# ci-tier:`
# line, so it is in TEST_OFFLINE, so it runs inside `test-scripts`, and it EXECUTES the hook, parses
# its source and awks it. MEASURED: touching that file mid-run reported `OK — 467 file(s) unchanged`,
# rc=0, while touching `scripts/tree-stability.sh` on the same tree gave rc=1 -- so the detector
# certified a run whose security-control input had been rewritten underneath it. Unlike
# `node_modules`, the two classes that actually false-fire are ROOT-anchored, so a path prune is both
# safe and sufficient here.
#
# Those two classes are what THIS REPO'S OWN MANDATED WORKFLOW writes. Rule Zero requires
# `isolation:"worktree"` on every adversary, which nests a 467-file checkout under
# `.claude/worktrees/`; and `adversary-first-gate.py` writes a receipt into `.claude/state/` on EVERY
# adversary spawn -- 31 are already in this checkout. Rule Zero-0's own hook demands you start an
# adversary in the same turn as a long background job, i.e. exactly during a `static-check`.
# MEASURED, both, against the real script: touching a file in an agent worktree, and one real receipt
# write, each produced a false RED. THE PRECEDENT WAS ALREADY IN THIS REPO AND WAS NOT INHERITED --
# `trivy config .` (Makefile) carries `--skip-dirs .claude`, and CLAUDE.md documents the class
# verbatim. This was 1 of 2 raw tree-walkers excluding it.
#
# `secrets/` holds `.env.make` and `.env.state.make`, REGENERATED by the Makefile
# (`regen_overlay_mk`) on EVERY invocation -- measured firing on a clean run before this prune.
#
# ⚠️ DO NOT "SIMPLIFY" THIS TO `git ls-files`. That drops gitignored files, and the gitignored
# `./.env` is the ONLY thing this detector has ever actually caught.
_snapshot() {
  find . \
    -name .git -prune -o \
    -path ./.claude/worktrees -prune -o \
    -path ./.claude/state -prune -o \
    -path ./.claude/settings.local.json -prune -o \
    -name secrets -prune -o \
    -name bundle -prune -o \
    -name node_modules -prune -o \
    -name target -prune -o \
    -name obj -prune -o \
    -name bin -prune -o \
    -name '.env.state' -prune -o \
    -name '*.tsbuildinfo' -prune -o \
    -type f -printf '%p\t%T@\t%s\n' 2>/dev/null | LC_ALL=C sort
}
# ⚠️ PATH FIRST, AND SORTED BY IT. A first version emitted `mtime size path` and sorted the whole
# line, so touching a file moved its SORT POSITION and the diff reported it as one removal plus one
# addition plus a modification -- the same file named three times, which reads as three problems.
# TAB-separated so a path containing spaces still parses as one field.

# ⚠️ VALIDATE THE SECOND ARGUMENT. It used to be read as a bare `${2:-}` comparison, so a TYPO --
# measured with `--requred` -- was silently ignored and the missing-snapshot path then printed
# "(invoked by hand)" and exited 0. That is fail-OPEN, from the recipe, in the one place this script
# exists to fail closed.
_required=0
case "${2:-}" in
  --required) _required=1 ;;
  '')         ;;
  *)          printf 'tree-stability: unknown argument %s\n' "$2" >&2
              printf 'usage: tree-stability.sh record | verify [--required]\n' >&2
              exit 2 ;;
esac

case "${1:-}" in
  record)
    # ⚠️ REAP OLD SNAPSHOTS. `verify` deliberately KEEPS the snapshot on a RED -- it is the only
    # evidence of what the tree looked like when the run started -- so nothing removed them and they
    # accumulated: MEASURED, 364 KB across 4 files, one of them a leaked run from earlier the same
    # day. Bounded three ways so this cannot become a `rm -rf` in someone's TMPDIR: -maxdepth 1, the
    # full literal prefix, and older than a day (today's RED stays inspectable). Failures ignored --
    # a reaper must never be able to fail the gate it runs inside.
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name '.tree-stability-*' -type f -mtime +0 -delete 2>/dev/null || true
    _snapshot > "$SNAP" 2>/dev/null
    exit 0 ;;
  verify)
    if [ ! -s "$SNAP" ]; then
      # ⚠️ A VERIFY WITH NO SNAPSHOT MUST NOT READ AS "VERIFIED" -- that is the vacuous green this
      # file exists to prevent, one level up. It is only benign when a HUMAN invokes it by hand; from
      # the gate's own recipe it means the record never ran, or ran under a different key, and the
      # honest answer there is a FAILURE, not a shrug. Hence --required, which the recipe passes.
      printf 'tree-stability: NO SNAPSHOT was taken, so nothing was verified.\n' >&2
      printf '                expected: %s\n' "$SNAP" >&2
      if [ "$_required" = 1 ]; then
        printf '                This was invoked BY THE GATE, so the record should have run. Its\n' >&2
        printf '                verdict cannot be trusted; failing rather than passing silently.\n' >&2
        exit 1
      fi
      printf '                (invoked by hand: run the gate through its own target)\n' >&2
      exit 0
    fi
    now="$(mktemp)"; trap 'rm -f "$now"' EXIT
    _snapshot > "$now" 2>/dev/null
    if cmp -s "$SNAP" "$now"; then
      # PRINT THE DENOMINATOR. A gate that cannot tell you what it looked at cannot be trusted to
      # have looked -- and this one is silent by nature, so its green would otherwise be
      # indistinguishable from its not having run at all.
      # ⚠️ COUNT RECORDS, NOT LINES. `find -printf '%p'` does not escape a newline in a filename, so
      # `wc -l` over-counts: MEASURED, 3 files reported as 4. The verdict is unaffected (`cmp` is
      # byte-exact) -- but the DENOMINATOR is the only number this control prints, and a denominator
      # that can disagree with reality is exactly what this repo keeps getting caught by. Each record
      # carries two TABs, and a spilled continuation line carries none.
      printf 'tree-stability: OK — %s file(s) unchanged for the whole run\n' \
        "$(grep -c "$(printf '\t')" "$SNAP" | tr -d ' ')"
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
    # ⚠️ KEEP THE SNAPSHOT ON FAILURE. Deleting it destroys the only evidence of what the tree looked
    # like when the run started, so a RED could not be re-inspected -- and a control whose failure
    # cannot be examined is one people stop believing.
    printf '\n                the starting snapshot is kept for inspection: %s\n' "$SNAP" >&2
    exit 1 ;;
  *)
    printf 'usage: tree-stability.sh record | verify [--required]\n' >&2
    exit 2 ;;
esac
