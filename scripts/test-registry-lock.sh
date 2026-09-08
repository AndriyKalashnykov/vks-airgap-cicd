#!/usr/bin/env bash
# ci-tier: fast
#
# Pins the registry lock's PATH DERIVATION (`_registry_common_dir` + `with_registry_lock`, lib/os.sh).
#
# The defect this exists for (B521): the lock path was `${REPO_ROOT}/.registry.lock`, and a git
# WORKTREE has its own REPO_ROOT — so two worktrees of one repo held two different FILES and flock
# granted BOTH. Measured before the fix: main held inode 30176617 while a worktree ACQUIRED inode
# 80249353, with the same-file control correctly REFUSED. `e2e-kind` reaches this lock transitively
# (install-all -> mirror -> mirror-push) and KIND_CLUSTER_NAME is FIXED, so both worktrees drive the
# same kind cluster and the same Harbor — the 2026-07-13 blob-store incident shape, re-enabled.
#
# ⚠️ THE WORKTREE FIXTURE IS HAND-BUILT, NOT `git worktree add`. test-namespace-gates.sh:19-22
# records why: worktrees share `.git/worktrees/` (a prune-race across concurrent `make test-scripts`)
# and `git worktree add` is blocked by the subagent read-only hook. Per gitrepository-layout(5) a
# linked worktree is just three plain files, so we write them directly — offline, hook-safe, no race.
#
# ⚠️ AND THIS CONTROL HAD NO TEST AT ALL until 2026-09-08, despite its absence having caused a
# documented incident. That is the reason for the first case: a gate nobody has seen fail is a gate.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh 2>/dev/null || { echo "cannot source lib/os.sh"; exit 1; }

_pass=0; _fail=0
ok()  { _pass=$((_pass+1)); printf '  ok    %s\n' "$1"; }
bad() { _fail=$((_fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$T/repo/.git"                                   # a "main checkout"
mkdir -p "$T/repo/.git/worktrees/fake"                    # ...and a linked worktree of it
printf '%s\n' "$T/repo/.git/worktrees/fake" > "$T/repo/.git/worktrees/fake/gitdir"
printf '../..\n'                                          > "$T/repo/.git/worktrees/fake/commondir"
printf 'ref: refs/heads/x\n'                              > "$T/repo/.git/worktrees/fake/HEAD"
mkdir -p "$T/wt"
printf 'gitdir: %s\n' "$T/repo/.git/worktrees/fake"       > "$T/wt/.git"
mkdir -p "$T/nothing"                                     # not a repo, no parent repo
mkdir -p "$T/repo/deep/deeper/deepest"                    # NOT a repo, nested INSIDE one

_same() { [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$2" 2>/dev/null && pwd -P)" ]; }

# 1. THE DEFECT ITSELF: a worktree must resolve to the SAME shared git dir as its main checkout.
_m="$(_registry_common_dir "$T/repo"  || true)"
_w="$(_registry_common_dir "$T/wt"    || true)"
if [ -n "$_m" ] && [ -n "$_w" ] && _same "$_m" "$_w"; then
  ok "a linked worktree resolves to the SAME shared git dir as its main checkout"
else
  bad "worktree and main checkout resolve DIFFERENTLY ([$_m] vs [$_w]) — two locks again, and flock
      grants both. This is B521 exactly."
fi

# 2. ...and flock must actually REFUSE across the two, which is the property the paths only imply.
#    (flock keys on the INODE, so the worktree's unnormalised `.../worktrees/fake/../..` form is the
#    same file as the plain `.git` — assert it, do not reason about it.)
(
  exec 9>"$_m/vks-registry.lock" || exit 3
  flock -n 9 || exit 3
  if ( exec 8>"$_w/vks-registry.lock" && flock -n 8 ) 2>/dev/null; then exit 1; else exit 0; fi
)
case $? in
  0) ok "...and flock REFUSES the worktree while the main checkout holds it" ;;
  3) bad "the harness could not take the first lock — this case measured NOTHING" ;;
  *) bad "flock GRANTED both. The paths agree but the file does not — the fix does not hold." ;;
esac

# 3. The control for case 2: a genuinely different repository must NOT be blocked.
# WARN THE FIRST LOCK MUST BE HELD FOR THE DURATION. Without that this only proves "an unrelated
#    file is lockable", which is true even if the helper returns ONE GLOBAL dir for every repo --
#    measured: a global-dir mutation left this case ok while three OTHER cases went red.
mkdir -p "$T/other/.git"
_o="$(_registry_common_dir "$T/other" || true)"
if ( exec 9>"$_m/vks-registry.lock"; flock -n 9 || exit 3
     ( exec 7>"$_o/vks-registry.lock" && flock -n 7 ) 2>/dev/null ) ; then
  ok "a DIFFERENT repository is not blocked (the lock is not global)"
else
  bad "a different repo was refused — over-blocking; every clone would serialize against every other"
fi

# 4. A non-repo returns 1, so the caller falls back to the pre-2026-09-08 path rather than dying.
if _registry_common_dir "$T/nothing" >/dev/null 2>&1; then
  bad "a NON-repo was treated as a repo — the lock would land somewhere unrelated"
else
  ok "a non-repo returns 1 (the caller falls back to \${REPO_ROOT}/.registry.lock)"
fi

# 5. THE REASON THIS IS PURE SHELL. `git rev-parse --git-common-dir` returns `../../../.git` with
#    rc=0 from here, so a git-based implementation anchors the lock into the PARENT repository — and
#    if that repo is unwritable, `exec 9>` fails and a working `make mirror-push` becomes a hard die.
_d="$(_registry_common_dir "$T/repo/deep/deeper/deepest" || true)"
if [ -z "$_d" ]; then
  ok "a non-repo NESTED inside a repo returns 1 — it cannot walk up into a stranger's .git"
else
  bad "a nested non-repo resolved to [$_d] — the lock would be taken in the PARENT repo. That is the
      exact failure mode that made the git-based implementation unusable."
fi

# 6. GIT_DIR/GIT_COMMON_DIR silently override `git -C`; a pure-shell reader is immune. Measured on
#    the git implementation: GIT_DIR pointed it at a foreign repo AND a --show-toplevel guard passed.
_g="$(GIT_DIR="$T/other/.git" GIT_COMMON_DIR="$T/other/.git" _registry_common_dir "$T/repo" || true)"
if [ -n "$_g" ] && _same "$_g" "$T/repo/.git"; then
  ok "GIT_DIR/GIT_COMMON_DIR in the environment cannot redirect the lock"
else
  bad "GIT_DIR redirected the lock to [$_g] — an env var now decides which registry is serialized"
fi

# 7. The explicit operator override must still win, untouched.
# WARN CALL THE REAL FUNCTION. The first version read back a variable it had just assigned in a
#    subshell and touched no code from os.sh at all -- measured VACUOUS: deleting the
#    REGISTRY_LOCK_FILE branch from with_registry_lock entirely left this case ok.
( REPO_ROOT="$T/repo" REGISTRY_LOCK_FILE="$T/override.lock" \
    with_registry_lock "override-probe" true ) >/dev/null 2>&1
if grep -q 'override-probe pid=' "$T/override.lock" 2>/dev/null; then
  ok "REGISTRY_LOCK_FILE remains the operator's escape hatch (the label landed in THAT file)"
else
  bad "REGISTRY_LOCK_FILE no longer overrides -- the lock went somewhere else entirely"
fi

# 8. No new binary on the air-gap floor: 22-builder-push.sh:8-10 states that box's toolchain as
#    "tar + curl + sha256sum + the carried crane", and it is one of this lock's four callers.
# ⚠️ MATCH THE BINARY AT A COMMAND POSITION, NOT THE WORD. `\bgit\b` also matches the `.git` in
#    every path this function reads, so the first version of this case FALSE-RED over correct code —
#    a grep that finds the string but the wrong KIND of thing.
# ⚠️ HERESTRING, NOT A PIPE. `producer | grep -q PAT` under `pipefail` reports a FOUND pattern as
#    ABSENT when grep exits early and the producer takes SIGPIPE — and in a scan gate that direction
#    is a FALSE CLEAN, i.e. this case would go `ok` over a body that DOES call git. The repo's
#    check-grep-q-pipe gate caught exactly this line.
_gitre='(^|[;&|`]|\$\()[[:space:]]*(sudo[[:space:]]+)?git[[:space:]]'
_body="$(sed -n '/^_registry_common_dir() {/,/^}/p' scripts/lib/os.sh)"
# THE POSITIVE CONTROL, which the first version CLAIMED to have and did not: prove the matcher can
# still flag a real invocation. Without it a rename or a brace reformat empties $_body and this case
# passes forever over anything at all.
if ! grep -qE "$_gitre" <<< "$(printf 'x() {\n  git rev-parse --git-common-dir\n}\n')"; then
  bad "case 8's matcher is DEAD -- it no longer flags a plain 'git ' call, so its verdict is noise"
elif [ -z "$_body" ]; then
  bad "case 8 extracted ZERO bytes -- the '_registry_common_dir() {' anchor drifted, so this case
      measured NOTHING and would pass forever."
elif grep -qE "$_gitre" <<< "$_body"; then
  bad "_registry_common_dir invokes git — but git is NOT in the air-gap box's stated toolchain, and
      three of this lock's four callers run there."
else
  ok "_registry_common_dir uses no git (sed/cat only — both already required by lib/os.sh)"
fi

# 9. THE FUNCTION ITSELF, not just its path helper. Until 2026-09-08 this suite named
#    with_registry_lock only in a comment, and that gap is exactly what let a CRITICAL ship: the
#    legacy-lock line was `exec 8>"$legacy" 2>/dev/null`, and `exec` with no command makes EVERY
#    redirection PERMANENT -- so stderr went to /dev/null for the rest of the process. Measured: the
#    refusal path printed NOTHING while exiting 1, and all four callers re-exec themselves as "$@",
#    so an entire mirror-push ran blind. Every offline gate in the repo was green over it.
_e="$T/stderr.probe"
( REPO_ROOT="$T/repo" with_registry_lock "stderr-probe" \
    bash -c 'echo MARKER-THE-OPERATOR-NEEDS >&2' ) >/dev/null 2>"$_e"
if grep -q 'MARKER-THE-OPERATOR-NEEDS' "$_e" 2>/dev/null; then
  ok "with_registry_lock does not swallow the payload's stderr"
else
  bad "the payload's stderr VANISHED. Something in with_registry_lock redirects fd 2 permanently --
      look for a bare 'exec' carrying a '2>' redirection; it must be scoped with braces."
fi

# 10. --separate-git-dir: the MAIN checkout's .git is a FILE whose external git dir has NO
#     commondir, while its worktree's commondir points at that same dir. Returning 1 for the main
#     checkout sent it to the per-worktree legacy lock while the worktree took the shared one, and
#     flock granted BOTH -- B521 re-opened, measured, with the ordinary-repo control REFUSED.
#     HAND-BUILT, like the worktree fixture above and for the same reasons -- and because
#     `git worktree add` needs a commit, which would put a committing command in this file. The
#     layout below was captured from a REAL `git init --separate-git-dir` on 2026-09-08:
#       work/.git                 -> "gitdir: <ext>"          (absolute)
#       <ext>/commondir           -> ABSENT                    <- the whole defect
#       wt/.git                   -> "gitdir: <ext>/worktrees/wt"
#       <ext>/worktrees/wt/commondir -> "../.."
mkdir -p "$T/ext/worktrees/wt" "$T/sgd" "$T/sgdwt"
printf 'gitdir: %s\n' "$T/ext"              > "$T/sgd/.git"
printf 'gitdir: %s\n' "$T/ext/worktrees/wt" > "$T/sgdwt/.git"
printf '../..\n'                            > "$T/ext/worktrees/wt/commondir"
printf 'ref: refs/heads/x\n'                 > "$T/ext/worktrees/wt/HEAD"
_sm="$(_registry_common_dir "$T/sgd"   2>/dev/null || true)"
_sw="$(_registry_common_dir "$T/sgdwt" 2>/dev/null || true)"
if [ -n "$_sm" ] && [ -n "$_sw" ] && _same "$_sm" "$_sw"; then
  ok "a --separate-git-dir checkout and its worktree share one lock"
else
  bad "--separate-git-dir main=[$_sm] worktree=[$_sw] -- they disagree, so flock grants both. That
      is B521 for a layout the first fix did not cover."
fi

printf '\n  %s passed, %s failed\n' "$_pass" "$_fail"
[ "$_fail" -eq 0 ] || { echo "registry-lock FAILED"; exit 1; }
echo "SUCCESS — one repository, one registry lock, from every worktree"
