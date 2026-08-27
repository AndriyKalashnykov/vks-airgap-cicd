#!/usr/bin/env bash
# worktree-status.sh — report which git worktrees and branches look prunable, and PRINT the exact
# commands. IT DELETES NOTHING, AND THAT IS DELIBERATE.
#
# WHY A PRINTER AND NOT A `make prune-worktrees` THAT ACTS. An acting target was designed and
# REFUTED by an idea-round on 2026-08-27, on four measured grounds:
#
#   1. `git worktree remove` IS BLIND TO GITIGNORED FILES. Its cleanliness check runs
#      `git status --porcelain --ignore-submodules=none`, which does NOT list ignored paths.
#      MEASURED end-to-end in a throwaway repo: a gitignored secrets/f was DELETED with no
#      --force, no prompt, and the clean-check printing nothing. In this repo lib/os.sh resolves
#      REPO_ROOT to the WORKTREE, so every worktree where a lab target ran holds
#      secrets/{vks,supervisor}.kubeconfig, harbor-robot.env and a multi-GB bundle/. Per
#      CLAUDE.md RULE ZERO-A0 a tenant CANNOT self-recover a Harbor robot credential.
#      (This was not hypothetical: removing one such worktree by hand destroyed its secrets/
#      before the mechanism was understood. The loss happened to be throwaway KinD material.)
#   2. `gh pr list` FAILS OPEN. On network or auth failure it exits 1 with EMPTY stdout, so the
#      natural `$(gh ... --jq)` idiom reads "no PR exists" and would delete an unmerged branch.
#   3. MERGED does not mean every commit is on main, and `git cherry` alone settles only ~55% of
#      cases — 9 of the last 20 merged PRs here were multi-commit, and a squashed patch-id
#      matches none of its inputs.
#   4. `git worktree remove` has NO current-directory guard. Every worktree contains this
#      Makefile, so running the target from inside one is the likely invocation; afterwards the
#      `pwd` builtin still returns the stale path and `ls .` exits 0, so self-checks lie.
#
# An acting gate could safely automate ~55% while carrying three fail-open surfaces whose worst
# case is unrecoverable. A printer covers 100% with no worst case: the operator pastes what they
# accept. Same precedent as scripts/handoff-status.sh, which prints and never gates.
#
# ALWAYS EXITS 0, including on its own errors. It is not a gate and must never fail a pipeline.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || { echo "not a git repo"; exit 0; }
HERE="$(git rev-parse --show-toplevel 2>/dev/null)"
# --git-common-dir may be RELATIVE (".git"), so dirname would yield "." and the main worktree
# would never match. Resolve it absolutely.
MAIN_WT="$(cd "$(dirname "$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd)")" && pwd)"

printf '=== worktrees ===\n'

# -z: `worktree list --porcelain` does NOT quote paths, so a space would split a plain read.
# Records are NUL-terminated groups of NUL-terminated "key value" lines.
mapfile -d '' -t _fields < <(git worktree list --porcelain -z 2>/dev/null)

wt=""; br=""; locked=0
emit() {
  [ -n "$wt" ] || return 0
  local label="${br#refs/heads/}"
  local cmds=""

  if [ "$wt" = "$MAIN_WT" ]; then
    printf '  %-52s  MAIN WORKTREE — never prunable\n' "$wt"; return 0
  fi
  if [ "$locked" -eq 1 ]; then
    printf '  %-52s  LOCKED (a live agent?) — skipped\n' "$wt"; return 0
  fi
  if [ "$HERE" = "$wt" ]; then
    printf '  %-52s  YOU ARE INSIDE THIS ONE — refuse; git has no cwd guard\n' "$wt"; return 0
  fi
  if [ ! -d "$wt" ]; then
    printf '  %-52s  gone from disk — git worktree prune would drop the record\n' "$wt"; return 0
  fi

  # THE CHECK THAT MATTERS: --ignored, because remove's own check is blind to these.
  local ign; ign="$(git -C "$wt" status --porcelain --ignored 2>/dev/null | grep -c '^!!' || true)"
  local dirty; dirty="$(git -C "$wt" status --porcelain 2>/dev/null | grep -c . || true)"

  # Reachability BEFORE the network: an empty/all-`-` cherry clears a branch regardless of PR state.
  local uniq="?"
  [ -n "$label" ] && uniq="$(git cherry origin/main "$label" 2>/dev/null | grep -c '^+' || true)"

  # gh with its rc read on its OWN line -- rc!=0 is "could not ask", never "no PR".
  local prstate="unknown" prhead="" out rc
  if [ -n "$label" ]; then
    out="$(gh pr list --head "$label" --state all --json state,headRefOid 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then prstate="COULD-NOT-ASK"
    elif [ "$out" = "[]" ]; then prstate="no-PR"
    else
      prstate="$(printf '%s' "$out" | jq -r '.[0].state' 2>/dev/null)"
      prhead="$(printf '%s' "$out" | jq -r '.[0].headRefOid' 2>/dev/null)"
    fi
  fi

  local tip; tip="$(git rev-parse "$label" 2>/dev/null || true)"
  local verdict
  if   [ "$dirty" -gt 0 ];                       then verdict="HOLD — uncommitted changes"
  elif [ "$ign"   -gt 0 ];                       then verdict="HOLD — ${ign} gitignored path(s); remove WOULD DELETE THEM"
  elif [ "$prstate" = "COULD-NOT-ASK" ];         then verdict="HOLD — gh failed; absence of a PR is NOT proven"
  elif [ "$uniq" = "0" ];                        then verdict="PRUNABLE — 0 commits absent from main"
  elif [ "$prstate" = "MERGED" ] && [ -n "$tip" ] && [ "$prhead" = "$tip" ];
                                                 then verdict="PRUNABLE — PR MERGED and tip matches headRefOid"
  elif [ "$prstate" = "MERGED" ];                then verdict="HOLD — PR MERGED but local tip != headRefOid (commits pushed after the merge?)"
  else                                           verdict="HOLD — PR ${prstate}, ${uniq} commit(s) absent from main"
  fi

  printf '  %-52s  %s\n' "$wt" "$verdict"
  printf '  %-52s  branch=%s  ignored=%s dirty=%s cherry+=%s pr=%s\n' "" "$label" "$ign" "$dirty" "$uniq" "$prstate"
  case "$verdict" in
    PRUNABLE*) cmds="    git worktree remove ${wt}\n    git branch -D ${label}   # tip ${tip:0:8} — note it before deleting\n" ;;
  esac
  # %b, not a variable format string (SC2059): cmds carries deliberate \n escapes.
  [ -n "$cmds" ] && printf "%b" "$cmds"
}

for f in "${_fields[@]}"; do
  case "$f" in
    worktree\ *) emit; wt="${f#worktree }"; br=""; locked=0 ;;
    branch\ *)   br="${f#branch }" ;;
    locked*)     locked=1 ;;
    "")          ;;
  esac
done
emit

printf '\n=== branches with no worktree ===\n'
git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | while read -r b; do
  case "$b" in main|master) continue ;; esac
  git worktree list --porcelain 2>/dev/null | grep -qx "branch refs/heads/$b" && continue
  u="$(git cherry origin/main "$b" 2>/dev/null | grep -c '^+' || true)"
  printf '  %-40s  %s commit(s) absent from main\n' "$b" "$u"
done

printf '\nThis printed only. Nothing was deleted. Read each HOLD before pasting anything.\n'
exit 0
