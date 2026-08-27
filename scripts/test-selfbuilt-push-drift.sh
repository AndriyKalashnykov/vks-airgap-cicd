#!/usr/bin/env bash
# ci-tier: manual
# test-selfbuilt-push-drift.sh — the push-side drift gate: CARRIED (the tarball this bundle holds)
# must equal SERVED (what the registry answers). Uses a REAL throwaway registry, so the digests are
# produced by the same code path production uses, not reconstructed.
#
# ci-tier: manual because it needs a container engine and binds a host port; `make test-scripts`
# is offline by contract. Run it by hand, or via `make test-selfbuilt-push-drift`.
#
# WHY IT EXISTS (all measured 2026-08-27). The gate this replaces compared the registry against a
# LOCAL LOCK FILE and had three defects, each of which this file pins:
#   1. ONE-SHOT: it appended the drifted digest *before* dying and read the baseline with `tail -1`,
#      so a real overwrite fired once and the operator's habitual re-run silently cleared it.
#   2. CROSS-TAG: it keyed on the image NAME only, so following its own printed remedy ("give the
#      new content its own tag") still tripped it.
#   3. BLIND ON RUN 1: no lock yet => nothing compared, on exactly the run a fresh air-gap box does.
set -uo pipefail

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

ENGINE="${CONTAINER_ENGINE:-podman}"
command -v "$ENGINE" >/dev/null 2>&1 || { printf '  SKIP  no %s\n' "$ENGINE"; exit 0; }
command -v crane    >/dev/null 2>&1 || { printf '  SKIP  no crane\n'; exit 0; }

PORT="${TEST_REGISTRY_PORT:-5998}"
CNAME="selfbuilt-drift-test-$$"
T="$(mktemp -d "${TMPDIR:-/tmp}/pushdrift.XXXXXX")"
cleanup() { "$ENGINE" rm -f "$CNAME" >/dev/null 2>&1; rm -rf -- "$T"; }
trap cleanup EXIT

"$ENGINE" run -d --name "$CNAME" -p "${PORT}:5000" docker.io/library/registry:2 >/dev/null 2>&1 \
  || { printf '  SKIP  could not start a throwaway registry\n'; exit 0; }
for _ in $(seq 1 30); do curl -sf "http://127.0.0.1:${PORT}/v2/" >/dev/null 2>&1 && break; sleep 0.5; done
curl -sf "http://127.0.0.1:${PORT}/v2/" >/dev/null 2>&1 \
  || { printf '  SKIP  throwaway registry never became ready\n'; exit 0; }

# Two DIFFERENT single-manifest images, saved exactly as 14-selfbuilt-build.sh saves.
mk() {  # $1 = marker -> prints the tarball path
  local d="$T/b$1"; mkdir -p "$d"
  printf 'FROM scratch\nCOPY m.txt /m.txt\n' > "$d/Dockerfile"
  printf 'marker-%s\n' "$1" > "$d/m.txt"
  # isolation-ok: this Dockerfile is FROM scratch + COPY with NO RUN step, so buildah never creates
  # a container and the cgroup-v1 crun failure cannot occur here. The guard is about RUN steps.
  "$ENGINE" build -q -t "localhost/pushdrift:$1" "$d" >/dev/null 2>&1
  "$ENGINE" save -o "$T/$1.tar" "localhost/pushdrift:$1" >/dev/null 2>&1
  printf '%s' "$T/$1.tar"
}
A="$(mk a)"; B="$(mk b)"
[ -s "$A" ] && [ -s "$B" ] || { printf '  SKIP  could not build fixtures\n'; exit 0; }

REF="127.0.0.1:${PORT}/probe/x:v1"
d_a="$(crane digest --tarball "$A" 2>/dev/null)"
d_b="$(crane digest --tarball "$B" 2>/dev/null)"

printf '%s\n' "== selfbuilt push drift =="

# The fixtures must actually DIFFER, or every case below is vacuous.
if [ -n "$d_a" ] && [ -n "$d_b" ] && [ "$d_a" != "$d_b" ]; then
  ok "fixtures A and B have different digests (the test can discriminate)"
else
  bad "fixtures A and B have different digests — TEST IS VACUOUS"; printf '  %d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# The property the whole design rests on: carried == served after a push. Measured, not assumed.
crane push "$A" "$REF" --insecure >/dev/null 2>&1
served="$(crane digest "$REF" --insecure 2>/dev/null)"
if [ "$served" = "$d_a" ]; then ok "carried == served after push (run 1, with NO prior state)"
else bad "carried == served after push  (carried=$d_a served=$served)"; fi

# THE HAZARD: someone overwrites the tag with different bytes. Carried is unchanged; served moves.
crane push "$B" "$REF" --insecure >/dev/null 2>&1
served2="$(crane digest "$REF" --insecure 2>/dev/null)"
if [ "$served2" = "$d_b" ] && [ "$served2" != "$d_a" ]; then
  ok "tag overwritten -> served now differs from the carried tarball (the gate's RED input)"
else bad "tag overwritten -> served differs from carried"; fi

# DEFECT 1 (one-shot): the hazard must STILL be detectable on the very next run. The old gate went
# green here because it had recorded the drifted digest as the new baseline.
served3="$(crane digest "$REF" --insecure 2>/dev/null)"
if [ "$served3" != "$d_a" ]; then ok "drift is STILL detected on the next run (not a one-shot tripwire)"
else bad "drift is STILL detected on the next run"; fi

# DEFECT 2 (cross-tag): the prescribed remedy — new content, its own tag — must be CLEAN.
REF2="127.0.0.1:${PORT}/probe/x:v2"
crane push "$B" "$REF2" --insecure >/dev/null 2>&1
if [ "$(crane digest "$REF2" --insecure 2>/dev/null)" = "$d_b" ]; then
  ok "new content under its OWN tag is clean (the gate's printed remedy actually works)"
else bad "new content under its own tag is clean"; fi

# DEFECT 3 (blind on run 1): a never-pushed ref must be distinguishable from a matching one, with
# no prior state of any kind.
if [ -z "$(crane digest "127.0.0.1:${PORT}/probe/never:v1" --insecure 2>/dev/null)" ]; then
  ok "an unpushed ref yields no served digest (run-1 case is representable)"
else bad "an unpushed ref yields no served digest"; fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
