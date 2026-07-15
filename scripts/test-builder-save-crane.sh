#!/usr/bin/env bash
# test-builder-save-crane.sh — a REGRESSION GUARD for the sneakernet builder round-trip. NOT a
# format-difference test.
#
# WHAT IT GUARDS
# ---------------------------------------------------------------------------
# The sneakernet INTERNET box builds the offline Maven builder under CONTAINER_ENGINE (podman default,
# or docker) and `<engine> save`s it to a tarball that the AIR-GAP box pushes with `crane push`
# (scripts/14-builder-build.sh -> scripts/22-builder-push.sh). That `save` -> `crane push` round-trip
# is only ever exercised for PODMAN on the tested path (e2e-sneakernet runs builder-build under the
# host's default engine = podman). This proves it for DOCKER too (and podman, for parity).
#
# HONESTY (do not over-trust this green): both `podman save` and `docker save`, used BARE (no --format,
# exactly as 14-builder-build.sh:90 does), default to the SAME docker-archive format — so there is NO
# format divergence to catch. This test guards that each engine's actual bytes still round-trip through
# the pinned crane, and that a re-save to the same path works (the 14-builder-build.sh `rm -f` re-run
# guard, which is podman-specific). It does NOT prove "docker sneakernet works" end-to-end — that is
# `make e2e-sneakernet CONTAINER_ENGINE=docker` (real builder, real Harbor).
#
# NOT in the offline test-scripts/static-check gate: it needs a running docker, a network-pulled
# registry:2, and the engines under test — none offline. It is a standalone `make test-builder-save-crane`.
# A missing prerequisite SKIPS LOUDLY (printed), never a silent pass. (`registry:2` is an intentional
# test-only external — tag-pinned, not digest-pinned, and deliberately NOT in images.txt / Renovate.)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO" || exit 1
fail=0; ran=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1" >&2; fail=1; }
skip() { printf 'SKIP  %s\n' "$1"; }

CRANE="$(command -v crane || true)"
[ -n "$CRANE" ] || { skip "crane not on PATH (run 'make deps') — cannot test the save->crane round-trip"; exit 0; }
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "docker not usable — needed to host a throwaway registry:2 AND to test the docker save->crane leg"; exit 0
fi

TMP="$(mktemp -d)"; REG_CID=""
# Delete what we create: the throwaway registry container, the per-engine local images, and the tmp dir.
cleanup() {
  [ -n "$REG_CID" ] && docker rm -f "$REG_CID" >/dev/null 2>&1
  for e in docker podman; do command -v "$e" >/dev/null 2>&1 && "$e" rmi -f "save-test:${e}" >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT

# A throwaway plain-HTTP registry:2 on an ephemeral host port (network pull — this is why the test is
# out of the offline gate).
REG_CID="$(docker run -d -P registry:2 2>/dev/null)" || { skip "cannot start registry:2 (image pull failed / offline?) — skipping"; exit 0; }
PORT="$(docker port "$REG_CID" 5000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
[ -n "$PORT" ] || { bad "registry:2 started but no host port maps to 5000/tcp"; exit 1; }
REG="localhost:${PORT}"
# wait for the registry to answer /v2/
ready=0
for _ in $(seq 1 30); do
  if command -v curl >/dev/null 2>&1; then curl -sf "http://${REG}/v2/" >/dev/null 2>&1 && { ready=1; break; }
  else "$CRANE" catalog --insecure "$REG" >/dev/null 2>&1 && { ready=1; break; }; fi
  sleep 1
done
[ "$ready" = 1 ] || { bad "registry:2 at ${REG} never answered /v2/"; exit 1; }

# A >=2-RUN image, so >=2 non-base layers exercise manifest ordering in the docker-archive.
cat > "$TMP/Dockerfile" <<'EOF'
FROM alpine:3
RUN echo layer1 > /l1
RUN echo layer2 > /l2
EOF

for eng in docker podman; do
  command -v "$eng" >/dev/null 2>&1 || { skip "${eng} not present — skipping its save->crane leg"; continue; }
  ref="${REG}/save-test:${eng}"
  tar="$TMP/${eng}.tar"
  if ! "$eng" build -t "save-test:${eng}" -f "$TMP/Dockerfile" "$TMP" >/dev/null 2>&1; then
    bad "${eng}: build failed"; continue
  fi
  rm -f "$tar"
  if ! "$eng" save -o "$tar" "save-test:${eng}" >/dev/null 2>&1; then bad "${eng}: save failed"; continue; fi
  # (C) RE-SAVE to the same path (rm -f + save), mirroring 14-builder-build.sh — guards the podman
  # docker-archive "won't overwrite" re-run bug that a single save cannot show.
  rm -f "$tar"
  if ! "$eng" save -o "$tar" "save-test:${eng}" >/dev/null 2>&1; then bad "${eng}: RE-save (rm -f + save) failed — the 14-builder-build.sh rm-f guard is load-bearing"; continue; fi
  # THE GAP: crane push the docker-archive tarball to the registry, then validate it round-tripped.
  if ! "$CRANE" push --insecure "$tar" "$ref" >/dev/null 2>&1; then bad "${eng}: 'crane push' of the ${eng}-save tarball FAILED"; continue; fi
  if "$CRANE" validate --insecure --remote "$ref" >/dev/null 2>&1; then
    ok "${eng}: build -> '${eng} save' -> 'crane push' -> 'crane validate --remote' round-trip OK"; ran=$((ran+1))
  else
    bad "${eng}: 'crane validate --remote' FAILED after push (the tarball did not round-trip)"
  fi
done

# Order matters: a FAILURE must win over the "nothing ran" skip. `ran` counts only SUCCESSFUL legs, so
# if every leg FAILED, ran==0 AND fail==1 — checking the skip first would exit 0 on a test that printed
# FAIL lines (a self-inflicted false-green the demonstrated-RED caught). Fail-check FIRST.
if [ "$fail" -ne 0 ]; then echo "test-builder-save-crane: FAILED"; exit 1; fi
[ "$ran" -gt 0 ] || { skip "no engine leg ran (neither docker nor podman usable) — nothing proven"; exit 0; }
echo "test-builder-save-crane: OK (${ran} engine leg(s))"
