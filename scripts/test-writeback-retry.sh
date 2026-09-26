#!/usr/bin/env bash
# test-writeback-retry.sh — the Tekton write-back (kaniko-build.yaml, step commit-push) must survive a
# concurrent write-back without ever deploying an OLDER commit over a newer one (B742).
#
# It runs the step's REAL script, extracted from the task YAML, against local git repos: an app repo with
# three linear commits c1 -> c2 -> c3 (the run builds c2, from a --depth 1 clone like git-clone.yaml's),
# and a bare deploy repo that a "competing run" writes to just before ours pushes.
# HOME is a throwaway: the step runs `git config --global`, which must never touch the real config.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK="${SCRIPT_DIR}/../k8s/tekton/tasks/kaniko-build.yaml"
command -v yq >/dev/null || { echo "test-writeback-retry: yq is required (make deps)"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@t; git config --global init.defaultBranch main
rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

step="$(yq -r '.spec.steps[] | select(.name == "commit-push") | .script' "$TASK")"
[ -n "$step" ] || { echo "test-writeback-retry: could not extract step commit-push from ${TASK}"; exit 1; }

# --- the app: c1 -> c2 -> c3 ------------------------------------------------------------------
git init -q "$T/app-src"
for i in 1 2 3; do echo "$i" > "$T/app-src/f"; git -C "$T/app-src" add f; git -C "$T/app-src" commit -qm "c$i"; done
C1="$(git -C "$T/app-src" rev-parse --short HEAD~2)"
C2="$(git -C "$T/app-src" rev-parse --short HEAD~1)"
C3="$(git -C "$T/app-src" rev-parse --short HEAD)"
git clone -q --bare "$T/app-src" "$T/app.git"
git --git-dir="$T/app.git" branch run "$C2"   # the run builds c2; main (c3) exists on the remote

# a deploy repo shaped like deploy/<app>/ (APP_COMMIT sits right above APP_INTERNAL_PORT)
mkdeploy() {
  rm -rf "$T/deploy.git" "$T/seed"
  git init -q "$T/seed"
  printf 'images:\n  - name: app\n    newTag: "NEVER-BUILT-RUN-THE-PIPELINE"\n' > "$T/seed/kustomization.yaml"
  printf 'spec:\n  template:\n    spec:\n      containers:\n        - name: app\n          env:\n            - name: APP_COMMIT\n              value: "unknown"\n            - name: APP_INTERNAL_PORT\n              value: "8080"\n' > "$T/seed/deployment.yaml"
  git -C "$T/seed" add -A; git -C "$T/seed" commit -qm seed
  git clone -q --bare "$T/seed" "$T/deploy.git"
}
# set_values <dir> <tag> <commit> [port]
set_values() {
  sed -i "s/newTag: .*/newTag: \"$2\"/" "$1/kustomization.yaml"
  sed -i "/name: APP_COMMIT/{n;s/value: .*/value: \"$3\"/}" "$1/deployment.yaml"
  [ -z "${4:-}" ] || sed -i "/name: APP_INTERNAL_PORT/{n;s/value: .*/value: \"$4\"/}" "$1/deployment.yaml"
}
# compete <commit> [port] [sed-expr]: another run (or a human) writes back first
compete() {
  rm -rf "$T/other"; git clone -q "$T/deploy.git" "$T/other"
  set_values "$T/other" 0.0.9 "$1" "${2:-}"
  [ -z "${3:-}" ] || sed -i "$3" "$T/other/deployment.yaml"
  git -C "$T/other" commit -qam "ci: deploy app 0.0.9 ($1)"; git -C "$T/other" push -q origin HEAD:main
}
# ours <script>: our run's workspace, cloned BEFORE the competitor pushed, then the step runs
prepare() {
  W="$T/ws"; rm -rf "$W"; mkdir -p "$W"
  git clone -q --depth 1 -b run "file://$T/app.git" "$W/app"   # like git-clone.yaml: shallow, at the run's commit
  git clone -q -b main "$T/deploy.git" "$W/deploy"
  set_values "$W/deploy" 0.1.0 "$C2"
}
runstep() {  # runstep <script> -> sets R, O
  local s="$1"
  s="${s//\$(workspaces.source.path)/$W}"
  s="${s//\$(params.deploy-revision)/main}"
  s="${s//\$(params.subdir)/app}"
  s="${s//\$(params.git-user-name)/ci}"
  s="${s//\$(params.git-user-email)/ci@x}"
  R=0; O="$(TAG=0.1.0 COMMIT="$C2" APP=app sh -c "$s" 2>&1)" || R=$?
}
remote_commit() { git --git-dir="$T/deploy.git" show main:deployment.yaml | awk '/name: APP_COMMIT/{getline; gsub(/.*value: *|"/,""); print; exit}'; }

echo "== no race: pushed =="
mkdeploy; prepare; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "writes ${C2}"; else bad "no race: rc=$R remote=$(remote_commit) $O"; fi

echo "== POSITIVE CONTROL: the old bare push goes red on a race (so the cases below exercise one) =="
old="$(printf '%s\n' "$step" | awk '/git commit -m/{print; print "        git push origin \"HEAD:$(params.deploy-revision)\""; exit} {print}')"
mkdeploy; prepare; compete "$C1"; runstep "$old"
if [ "$R" != 0 ]; then ok "old step: rc=$R on a race"; else bad "old step did not fail on a race — the harness does not create one"; fi

echo "== race, upstream NEWER (c3): must yield, not write =="
mkdeploy; prepare; compete "$C3"; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C3" ] && printf '%s' "$O" | grep -q SUPERSEDED; then ok "yields to ${C3}"
else bad "newer upstream: rc=$R remote=$(remote_commit) $O"; fi

echo "== race, upstream OLDER (c1): ours goes on top =="
mkdeploy; prepare; compete "$C1"; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "overwrites ${C1} with ${C2}"; else bad "older upstream: rc=$R remote=$(remote_commit) $O"; fi

echo "== race, upstream SAME commit: nothing to write =="
mkdeploy; prepare; compete "$C2"; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "same commit -> rc 0"; else bad "same: rc=$R remote=$(remote_commit) $O"; fi

echo "== race, upstream names a commit the app repo does not have (reseeded): ours is written =="
mkdeploy; prepare; compete deadbee; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "unresolvable upstream -> ours"; else bad "unresolvable: rc=$R remote=$(remote_commit) $O"; fi

# A concurrent edit near our lines must NEVER be silently lost: either it survives next to ours,
# or the step refuses. Two shapes: a line two below APP_COMMIT (git merges it), and the line right
# after APP_COMMIT's value, inside the conflicting hunk, where -X theirs would take ours wholesale.
edit_survives() {  # edit_survives <label> <grep-pattern-of-the-edit>
  local have; have="$(git --git-dir="$T/deploy.git" show main:deployment.yaml)"
  if printf '%s' "$have" | grep -q "$2"; then
    if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "$1: merged — the edit survives and ${C2} is written"
    elif [ "$R" != 0 ] && printf '%s' "$O" | grep -q 'more than newTag'; then ok "$1: refused — the edit survives"
    else bad "$1: rc=$R remote=$(remote_commit) $O"; fi
  else bad "$1: the concurrent edit was LOST (rc=$R) $O"; fi
}
echo "== race with an edit two lines below APP_COMMIT (the port) and an older commit =="
mkdeploy; prepare; compete "$C1" 9090; runstep "$step"; edit_survives "port edit" 'value: "9090"'
echo "== race with an edit on the line RIGHT AFTER APP_COMMIT's value, and an older commit =="
mkdeploy; prepare; compete "$C1" "" 's/- name: APP_INTERNAL_PORT/- name: APP_INTERNAL_PORT_RENAMED/'; runstep "$step"
edit_survives "adjacent edit" 'APP_INTERNAL_PORT_RENAMED'

echo "test-writeback-retry: yq is required (make deps)"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@t; git config --global init.defaultBranch main
rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

step="$(yq -r '.spec.steps[] | select(.name == "commit-push") | .script' "$TASK")"
[ -n "$step" ] || { echo "test-writeback-retry: could not extract step commit-push from ${TASK}"; exit 1; }

# --- the app: c1 -> c2 -> c3 ------------------------------------------------------------------
git init -q "$T/app-src"
for i in 1 2 3; do echo "$i" > "$T/app-src/f"; git -C "$T/app-src" add f; git -C "$T/app-src" commit -qm "c$i"; done
C1="$(git -C "$T/app-src" rev-parse --short HEAD~2)"
C2="$(git -C "$T/app-src" rev-parse --short HEAD~1)"
C3="$(git -C "$T/app-src" rev-parse --short HEAD)"
git clone -q --bare "$T/app-src" "$T/app.git"
git --git-dir="$T/app.git" branch run "$C2"   # the run builds c2; main (c3) exists on the remote

# a deploy repo shaped like deploy/<app>/ (APP_COMMIT sits right above APP_INTERNAL_PORT)
mkdeploy() {
  rm -rf "$T/deploy.git" "$T/seed"
  git init -q "$T/seed"
  printf 'images:\n  - name: app\n    newTag: "NEVER-BUILT-RUN-THE-PIPELINE"\n' > "$T/seed/kustomization.yaml"
  printf 'spec:\n  template:\n    spec:\n      containers:\n        - name: app\n          env:\n            - name: APP_COMMIT\n              value: "unknown"\n            - name: APP_INTERNAL_PORT\n              value: "8080"\n' > "$T/seed/deployment.yaml"
  git -C "$T/seed" add -A; git -C "$T/seed" commit -qm seed
  git clone -q --bare "$T/seed" "$T/deploy.git"
}
# set_values <dir> <tag> <commit> [port]
set_values() {
  sed -i "s/newTag: .*/newTag: \"$2\"/" "$1/kustomization.yaml"
  sed -i "/name: APP_COMMIT/{n;s/value: .*/value: \"$3\"/}" "$1/deployment.yaml"
  [ -z "${4:-}" ] || sed -i "/name: APP_INTERNAL_PORT/{n;s/value: .*/value: \"$4\"/}" "$1/deployment.yaml"
}
# compete <commit> [port] [sed-expr]: another run (or a human) writes back first
compete() {
  rm -rf "$T/other"; git clone -q "$T/deploy.git" "$T/other"
  set_values "$T/other" 0.0.9 "$1" "${2:-}"
  [ -z "${3:-}" ] || sed -i "$3" "$T/other/deployment.yaml"
  git -C "$T/other" commit -qam "ci: deploy app 0.0.9 ($1)"; git -C "$T/other" push -q origin HEAD:main
}
# ours <script>: our run's workspace, cloned BEFORE the competitor pushed, then the step runs
prepare() {
  W="$T/ws"; rm -rf "$W"; mkdir -p "$W"
  git clone -q --depth 1 -b run "file://$T/app.git" "$W/app"   # like git-clone.yaml: shallow, at the run's commit
  git clone -q -b main "$T/deploy.git" "$W/deploy"
  set_values "$W/deploy" 0.1.0 "$C2"
}
runstep() {  # runstep <script> -> sets R, O
  local s="$1"
  s="${s//\$(workspaces.source.path)/$W}"
  s="${s//\$(params.deploy-revision)/main}"
  s="${s//\$(params.subdir)/app}"
  s="${s//\$(params.git-user-name)/ci}"
  s="${s//\$(params.git-user-email)/ci@x}"
  R=0; O="$(TAG=0.1.0 COMMIT="$C2" APP=app sh -c "$s" 2>&1)" || R=$?
}
remote_commit() { git --git-dir="$T/deploy.git" show main:deployment.yaml | awk '/name: APP_COMMIT/{getline; gsub(/.*value: *|"/,""); print; exit}'; }

echo "== no race: pushed =="
mkdeploy; prepare; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "writes ${C2}"; else bad "no race: rc=$R remote=$(remote_commit) $O"; fi

echo "== POSITIVE CONTROL: the old bare push goes red on a race (so the cases below exercise one) =="
old="$(printf '%s\n' "$step" | awk '/git commit -m/{print; print "        git push origin \"HEAD:$(params.deploy-revision)\""; exit} {print}')"
mkdeploy; prepare; compete "$C1"; runstep "$old"
if [ "$R" != 0 ]; then ok "old step: rc=$R on a race"; else bad "old step did not fail on a race — the harness does not create one"; fi

echo "== race, upstream NEWER (c3): must yield, not write =="
mkdeploy; prepare; compete "$C3"; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C3" ] && printf '%s' "$O" | grep -q SUPERSEDED; then ok "yields to ${C3}"
else bad "newer upstream: rc=$R remote=$(remote_commit) $O"; fi

echo "== race, upstream OLDER (c1): ours goes on top =="
mkdeploy; prepare; compete "$C1"; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "overwrites ${C1} with ${C2}"; else bad "older upstream: rc=$R remote=$(remote_commit) $O"; fi

echo "== race, upstream SAME commit: nothing to write =="
mkdeploy; prepare; compete "$C2"; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "same commit -> rc 0"; else bad "same: rc=$R remote=$(remote_commit) $O"; fi

echo "== race, upstream names a commit the app repo does not have (reseeded): ours is written =="
mkdeploy; prepare; compete deadbee; runstep "$step"
if [ "$R" = 0 ] && [ "$(remote_commit)" = "$C2" ]; then ok "unresolvable upstream -> ours"; else bad "unresolvable: rc=$R remote=$(remote_commit) $O"; fi

echo "== race with an ADJACENT edit (port) and an older commit: must refuse, not revert it =="
mkdeploy; prepare; compete "$C1" 9090; runstep "$step"
port="$(git --git-dir="$T/deploy.git" show main:deployment.yaml | awk '/APP_INTERNAL_PORT/{getline; gsub(/.*value: *|"/,""); print; exit}')"
if [ "$R" != 0 ] && [ "$port" = 9090 ] && printf '%s' "$O" | grep -q 'more than newTag'; then ok "refuses; the concurrent port edit survives"
else bad "adjacent edit: rc=$R port=$port $O"; fi

echo "test-writeback-retry: ${checks} checks, rc=$rc"
exit "$rc"
