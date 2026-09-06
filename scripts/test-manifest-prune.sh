#!/usr/bin/env bash
# ci-tier: fast — pure filesystem logic, no network, no registry, no cluster.
#
# test-manifest-prune.sh — RED-proof for mirror_prune_manifests (lib/mirror.sh).
#
# THE DEFECT IT PINS (B700, MEASURED 2026-09-06 on the real lab):
#   10-mirror-pull.sh writes version-stamped manifests (tekton-pipelines-${VER}.yaml)
#   and NEVER deleted the superseded ones. mirror_collect_images greps EVERY file in
#   that directory, so the wanted-set grew monotonically: three concurrent pipeline
#   versions + three triggers + two dashboard = 25 stale artifacts = 5.85 GB = 47% of
#   the entire mirror, permanently TAGGED and therefore permanently un-GC-able.
#   Harbor's GC could not reclaim one byte of it — `delete_untagged` had nothing to
#   delete because every artifact carries a tag.
#
# Case 2 is not padding: it pins the `((pruned++))` trap. `((x++))` evaluates to the
# value BEFORE incrementing, so with pruned=0 it returns rc=1 and, under `set -e`,
# kills the script on the FIRST prune — i.e. exactly when there is nothing to prune,
# the commonest state. The function uses `pruned=$((pruned + 1))` for that reason.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# Stub the logging the lib expects, so this stays a unit test with no os.sh dependency.
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$*" >&2; }
die() { log_error "$*"; exit 1; }

# shellcheck source=scripts/lib/mirror.sh
. scripts/lib/mirror.sh 2>/dev/null || { echo "FAIL  cannot source lib/mirror.sh" >&2; exit 1; }
declare -F mirror_prune_manifests >/dev/null \
  || { echo "FAIL  mirror_prune_manifests is not defined — the lib changed shape" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- case 1: THE REAL DEFECT — superseded versions must go, pinned must stay -------
d="$TMP/c1"; mkdir -p "$d"
for f in tekton-pipelines-v1.4.0.yaml tekton-pipelines-v1.14.0.yaml \
         tekton-triggers-v0.34.0.yaml tekton-dashboard-v0.70.0.yaml; do : > "$d/$f"; done
for f in tekton-pipelines-v1.15.0.yaml tekton-triggers-v0.37.0.yaml \
         tekton-dashboard-v0.71.0.yaml gateway-api-v1.5.1.yaml; do : > "$d/$f"; done
mirror_prune_manifests "$d" \
  tekton-pipelines-v1.15.0.yaml tekton-triggers-v0.37.0.yaml \
  tekton-dashboard-v0.71.0.yaml gateway-api-v1.5.1.yaml
rc=$?
[ "$rc" -eq 0 ] || bad "case1: rc=$rc, want 0"
left="$(find "$d" -maxdepth 1 -name '*.yaml' -printf '%f\n' | sort | tr '\n' ' ')"
want="gateway-api-v1.5.1.yaml tekton-dashboard-v0.71.0.yaml tekton-pipelines-v1.15.0.yaml tekton-triggers-v0.37.0.yaml "
if [ "$left" = "$want" ]; then ok "case1: 4 superseded pruned, 4 pinned kept"
else bad "case1: left=[$left] want=[$want]"; fi

# ---- case 2: NOTHING to prune — pins the ((pruned++)) rc=1 trap --------------------
d="$TMP/c2"; mkdir -p "$d"; : > "$d/tekton-pipelines-v1.15.0.yaml"
mirror_prune_manifests "$d" tekton-pipelines-v1.15.0.yaml; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$d/tekton-pipelines-v1.15.0.yaml" ]; then
  ok "case2: no-op prune returns 0 and keeps the pinned file"
else bad "case2: rc=$rc (want 0), file present=$([ -f "$d/tekton-pipelines-v1.15.0.yaml" ] && echo yes || echo NO)"; fi

# ---- case 3: directory absent — must not crash ------------------------------------
mirror_prune_manifests "$TMP/does-not-exist" some-file.yaml; rc=$?
if [ "$rc" -eq 0 ]; then ok "case3: absent dir returns 0"; else bad "case3: rc=$rc, want 0"; fi

# ---- case 4: EMPTY keep-set prunes everything (a caller bug must not silently no-op) --
d="$TMP/c4"; mkdir -p "$d"; : > "$d/a.yaml"; : > "$d/b.yaml"
mirror_prune_manifests "$d"; rc=$?
n="$(find "$d" -maxdepth 1 -name '*.yaml' | wc -l)"
if [ "$rc" -eq 0 ] && [ "$n" -eq 0 ]; then ok "case4: empty keep-set prunes all"
else bad "case4: rc=$rc remaining=$n"; fi

# ---- case 5: non-.yaml and awkward names are untouched / handled ------------------
d="$TMP/c5"; mkdir -p "$d"
: > "$d/keep.yaml"; : > "$d/notes.txt"; : > "$d/-dash-lead.yaml"; : > "$d/with space.yaml"
mirror_prune_manifests "$d" keep.yaml; rc=$?
if [ "$rc" -eq 0 ] && [ -f "$d/keep.yaml" ] && [ -f "$d/notes.txt" ] \
   && [ ! -f "$d/-dash-lead.yaml" ] && [ ! -f "$d/with space.yaml" ]; then
  ok "case5: .txt untouched; leading-dash and spaced names pruned safely"
else bad "case5: rc=$rc keep=$([ -f "$d/keep.yaml" ] && echo y || echo n) txt=$([ -f "$d/notes.txt" ] && echo y || echo n) dash=$([ -f "$d/-dash-lead.yaml" ] && echo STILL || echo gone) space=$([ -f "$d/with space.yaml" ] && echo STILL || echo gone)"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
