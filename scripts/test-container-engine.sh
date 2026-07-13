#!/usr/bin/env bash
# test-container-engine.sh — PODMAN IS THE DEFAULT. Prove it, offline.
#
# "podman preferred" was written in four places and tested in NONE. A preference nobody asserts is a
# comment, not a behaviour: any edit to container_engine()'s `if have podman ... elif have docker`
# order would silently flip every jump box to docker, and every gate in this repo would stay green.
#
# It also guards the claim the air-gap story rests on: THE REAL-LAB FLOW NEEDS NO DOCKER. `make deps`
# installs podman and never docker, and the mirror runs on crane (a static binary, no daemon). Docker
# is required ONLY by the KinD stand-in, which reaches into the kind Docker network and `docker exec`s
# into the node containers. If a docker dependency ever leaks into an operator-flow script, an
# air-gapped jump box that followed our own prerequisites would fail at that step — so that is a gate,
# not a doc note.
#
# Offline by construction: `have` is a PATH lookup. Nothing is executed, no engine is contacted.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export REPO_ROOT="$PWD"
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Fake BOTH engines on PATH — the only state in which a preference is observable at all. (With just
# one installed, any implementation "passes"; that is why this must be tested with both present.)
for e in podman docker; do printf '#!/bin/sh\nexit 0\n' > "${tmp}/${e}"; chmod +x "${tmp}/${e}"; done

# `container_engine` reads CONTAINER_ENGINE from the env, so unset it: an operator (or a stray
# .env) exporting it would make this test measure their box instead of the code.
# /bin/bash by ABSOLUTE path: a PATH of one directory has no `bash` on it either.
engine_with_path() { env -u CONTAINER_ENGINE PATH="$1" /bin/bash -c '. scripts/lib/os.sh; container_engine'; }

# 1. BOTH present -> podman. The whole claim.
got="$(engine_with_path "${tmp}:${PATH}")"
if [ "$got" = podman ]; then
  ok "podman and docker BOTH installed -> podman (it is the DEFAULT, not a suggestion)"
else
  bad "both engines installed and container_engine() chose '${got}' — podman is supposed to be the default"
fi

# 2. Only docker -> docker. The fallback still works (podman-default must not become podman-only).
#    The PATH must hold NOTHING ELSE: leaving /usr/bin on it re-exposes the real podman and the
#    fixture measures this box instead of the code. (`have` is `command -v`, a builtin — a PATH of
#    exactly one directory is enough, and it is the only way to actually simulate "podman absent".)
only_docker="$(mktemp -d)"; cp "${tmp}/docker" "${only_docker}/"
# os.sh needs a few real tools at source time (id/dirname/date/...). Link exactly those — NOT the
# whole of /usr/bin, which is where the real podman lives. A bare one-entry PATH "works" but makes
# os.sh spray `command not found`, and a test that prints errors while passing trains you to ignore it.
for t in id dirname date sed grep cat mktemp tr uname readlink basename sudo; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "${only_docker}/${t}"
done
got="$(engine_with_path "${only_docker}")"
if [ "$got" = docker ]; then
  ok "podman absent -> docker (the fallback is intact)"
else
  bad "with only docker present, container_engine() returned '${got}'"
fi
rm -rf "$only_docker"

# 3. The explicit override wins. Docker is not forbidden — it is just not the default.
got="$(CONTAINER_ENGINE=docker bash -c '. scripts/lib/os.sh; container_engine')"
if [ "$got" = docker ]; then
  ok "CONTAINER_ENGINE=docker overrides the default (docker is a choice, never a requirement)"
else
  bad "CONTAINER_ENGINE=docker was ignored — got '${got}'"
fi

# 4. CONTAINER_ENGINE must stay COMMENTED in .env.example. Uncommented, load_env's `set -a` re-sources
#    it AFTER make has put a per-run override in the environment, pinning the engine and killing both
#    the auto-detection above and the override in 3. (check-env-clobber enforces the class; this
#    asserts the specific variable, because it is the one that decides which engine builds your image.)
if grep -qE '^[[:space:]]*CONTAINER_ENGINE=' .env.example; then
  bad ".env.example has an UNCOMMENTED CONTAINER_ENGINE= — it will clobber auto-detection and any per-run override"
else
  ok "CONTAINER_ENGINE is commented in .env.example (unset ⇒ the podman-first default applies)"
fi

# 5. NO OPERATOR-FLOW SCRIPT MAY REQUIRE DOCKER.
#    This is the air-gap claim as a gate: a jump box that ran `make deps` has podman and NOT docker,
#    so a docker dependency anywhere in the real-lab flow is a broken prerequisite, discovered on the
#    lab. Docker belongs ONLY to the KinD stand-in and the local test harnesses.
#    Allowlist = the KinD/local-only scripts, each of which is genuinely docker-bound: they use the
#    kind Docker network, `docker exec` into node containers, or build the jump-box test image.
KIND_ONLY='05-kind-up.sh|06-install-harbor.sh|07-install-argocd.sh|kind-down.sh|e2e-.*\.sh|test-.*\.sh|jumpbox.*\.sh|bootstrap-test\.sh'
offenders=""
for f in scripts/[0-9][0-9]-*.sh scripts/lib/*.sh scripts/creds.sh scripts/argocd-password.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  printf '%s' "$b" | grep -qE "^(${KIND_ONLY})$" && continue
  # lib/os.sh DEFINES container_engine() — its `have docker` IS the fallback, not a requirement.
  # (My first draft flagged it: the gate cannot treat the abstraction's definition as a violation
  # of the abstraction. It is the one file allowed to name docker.)
  [ "$b" = os.sh ] && continue
  # comments stripped first: a gate that matches the comment EXPLAINING it is a gate that lies
  # (this repo has shipped that bug twice — check-java-alignment and test-kind-down-safety).
  if sed 's/#.*//' "$f" | grep -qE '(require_cmd|command -v|have)[[:space:]]+docker|docker (exec|cp|network|run|build)|docker\.sock'; then
    offenders="${offenders} ${b}"
  fi
done
if [ -z "$offenders" ]; then
  ok "no operator-flow script requires docker (the real-lab path is podman + crane; \`make deps\` installs neither docker nor a daemon)"
else
  bad "operator-flow script(s) require docker:${offenders} — an air-gapped jump box that ran \`make deps\` has podman only, so this breaks ON THE LAB"
fi

if [ "$fail" = 0 ]; then
  echo "test-container-engine: OK"
  exit 0
fi
echo "test-container-engine: FAILED" >&2
exit 1
