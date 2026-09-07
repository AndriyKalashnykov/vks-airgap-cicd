#!/usr/bin/env bash
# ci-tier: fast — offline; reads the git index and apps/registry.tsv. No network, no cluster.
#
# check-app-gitignore.sh — EVERY app directory must carry a TRACKED .gitignore (B535).
#
# WHY. `scripts/50-seed-gitea-repos.sh` force-pushes each app directory VERBATIM into a fresh Gitea
# repo (push_repo: cp -a -> git init -> git add -A -> push -f). The ROOT .gitignore cannot protect
# that repo: its build-output rules are `apps/**/`-anchored, and at the fresh repo's root there is
# no `apps/` prefix left to match. MEASURED 2026-09-07 on a built box: of 911 staged files, the
# outer repo ignores 845 and the fresh-repo anchoring ignored 3 — 0.35%.
#
# gitignore(5): "these patterns match relative to the location of the .gitignore file". So a file in
# the app directory anchors IDENTICALLY in both repos. That property is why this is the fix and why
# translating the root rules (or the .dockerignore) is not — see BACKLOG.md `## B535`.
#
# WHY IT ASSERTS *TRACKED*, NOT PRESENT. The defect is untracked local build output, so a CI
# checkout has none of it and any gate over the junk itself is VACUOUS there (measured: 61 files, 0
# flagged, on a fresh worktree). The .gitignore is a TRACKED artifact, so this gate is meaningful on
# a clean checkout — which is the only place `static-check` ever runs. It is also why `git ls-files`
# is the right instrument and `test -f` is not: a file present-but-untracked never reaches the
# operator, and `cp -a` would still copy it, so the two states are NOT equivalent.
#
# WHAT THIS DELIBERATELY DOES NOT DO: check the CONTENT. Which patterns each app needs is a
# judgement call and an enumerated list that would rot. This gate answers "does the mechanism
# exist"; `make app-gitignore-show` PRINTS the rules beside the root's so a human can judge them.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

# ⚠️ THE REGISTRY IS PARSED BY app_rows(), NOT BY A HAND-ROLLED `while read < file`. Three reasons,
# each a measured defect in the hand-rolled version this replaced:
#   1. a registry with NO TRAILING NEWLINE silently loses its LAST row, and the gate then reports
#      "OK — all 5 app(s)" having never looked at the app that contributes 236 of the 845 files.
#      `read` returns non-zero on the final unterminated line, so the loop body never runs for it.
#   2. it hardcoded the path and ignored APPS_REGISTRY — the ONLY lever
#      `test-registry-fail-open.sh` has. A gate that cannot be pointed at a broken registry cannot
#      be proven to fail closed on one, and wiring it into that harness would have made every case
#      read the REAL registry and report PASS: a vacuous green inside the anti-vacuity harness.
#   3. TAB is IFS-*whitespace*, so consecutive tabs collapse and an empty middle field shifts every
#      later field LEFT. app_rows/app_field are the forms the rest of the repo already uses.
# app_rows() dies when the registry is missing, so the explicit existence check is redundant here.

# ⚠️ THIS GATE ASSERTS THE INDEX **AND** THE DISK, and it needs both — they are DIFFERENT SETS.
#   `git ls-files` answers "will the operator receive it"; `[ -f ]` answers "will `cp -a` copy it".
#   push_repo does `cp -a "$src/."`, i.e. it reads the DISK. So:
#     tracked but DELETED locally -> ls-files says yes, cp -a copies nothing -> the ELF ships
#     present but UNTRACKED       -> cp -a copies it, nobody else ever receives it
#   MEASURED: with `apps/go/gowebapp/.gitignore` deleted-but-still-in-the-index, the index-only
#   form returned rc=0 and printed "the seeded repos are protected" while staging the tree the way
#   push_repo does stages `gowebapp`, the 15,269,674-byte ELF. And the blind state is the SEEDING
#   state: it cannot happen in CI (a fresh checkout makes index == disk) and it is exactly a dirty
#   working tree, which is where `make platform` / `make seed-gitea` actually run.
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die \
  "check-app-gitignore: ${REPO_ROOT} is not a git repository. This gate asserts INDEX membership,
  so it cannot run on an unpacked tarball copy — it would report every app as missing a file that
  is sitting right there. That is a wrong-cause message, which is why it refuses instead."

missing=""; n=0; ok=0
while IFS=$'\t' read -r name _lang src _rest; do
  [ -n "${name:-}" ] || continue
  [ -n "${src:-}" ]  || continue
  n=$((n + 1))
  if git -C "$REPO_ROOT" ls-files --error-unmatch "${src}/.gitignore" >/dev/null 2>&1 \
     && [ -f "${REPO_ROOT}/${src}/.gitignore" ]; then
    ok=$((ok + 1))
  else
    missing="${missing}${src}"$'\n'   # NEWLINE-delimited: a src containing a space must stay ONE path
  fi
done < <(app_rows)

[ "$n" -gt 0 ] || die "check-app-gitignore: parsed ZERO apps from registry.tsv — the gate looked at
  nothing. That is a broken gate, not a clean repo."

if [ -n "$missing" ]; then
  log_error "check-app-gitignore: these app dir(s) have no TRACKED .gitignore:"
  # NOT `for d in $missing` — unquoted word-splitting turns "apps/java/my app" into two
  # nonexistent paths and sends the operator to create phantom files.
  while IFS= read -r d; do [ -n "$d" ] && log_error "    ${d}/.gitignore"; done <<< "$missing"
  log_error "  Each app dir is force-pushed VERBATIM into a fresh Gitea repo, where the root"
  log_error "  .gitignore's apps/**-anchored rules DO NOT APPLY. Without one, the operator's local"
  log_error "  build output ships: measured 601 files for nodejs, 236 for dotnet, and a 15 MB ELF"
  # ⚠️ The message below is deliberately APP-AGNOSTIC. A shared file may not name a specific app
  # (`check-app-hardcodes`), and the concrete case belongs here, in a comment, not in operator
  # output: apps/go/gowebapp/.dockerignore carries a BARE binary-name token, which as a gitignore
  # line would also exclude cmd/<name>/ and internal/<name>/ — so that file uses an ANCHORED
  # `/<name>` instead. That is the grammar trap; it is not specific to any one app.
  log_error "  for a compiled binary. Write it BY HAND — do NOT copy the .dockerignore: a BARE"
  log_error "  binary-name token there would also exclude cmd/<name>/ and internal/<name>/, so the"
  log_error "  gitignore form must be ANCHORED (/<name>). Run 'make app-gitignore-show' first."
  die "check-app-gitignore: ${ok} of ${n} app(s) carry a tracked .gitignore"
fi
log_info "check-app-gitignore: OK — all ${n} app(s) carry a tracked .gitignore (the seeded repos are protected)"
