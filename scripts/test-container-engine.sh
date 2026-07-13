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
#    The verb list USED to be `docker (exec|cp|network|run|build)`. That gate went GREEN on the very
#    commit that added a bare `docker info` to an operator script — a gate that passes on the change
#    it forbids is not a gate. Match the BINARY INVOCATION (`docker <subcommand>`), not a verb menu.
KIND_ONLY='05-kind-up\.sh|06-install-harbor\.sh|07-install-argocd\.sh|kind-down\.sh'
# The glob below can only ever yield NN-*.sh / lib/*.sh / the two named scripts, so an allowlist entry
# for e2e-*/test-*/jumpbox* would be DEAD — it would advertise coverage we do not have. They are
# genuinely docker-bound and genuinely out of the operator flow, so they are simply not scanned; say
# so rather than pretending an exemption.
offenders=""; scanned=0
for f in scripts/[0-9][0-9]-*.sh scripts/lib/*.sh scripts/creds.sh scripts/argocd-password.sh \
         scripts/app-run.sh scripts/app-test.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  printf '%s' "$b" | grep -qE "^(${KIND_ONLY})$" && continue
  # lib/os.sh DEFINES container_engine() — its `have docker` IS the fallback, not a requirement.
  # (My first draft flagged it: the gate cannot treat the abstraction's definition as a violation
  # of the abstraction. It is the one file allowed to name docker.)
  [ "$b" = os.sh ] && continue
  scanned=$((scanned + 1))
  # Comments stripped first: a gate that matches the comment EXPLAINING it is a gate that lies
  # (this repo has shipped that bug twice — check-java-alignment and test-kind-down-safety).
  #
  # ...but stripping comments is NOT enough: `docker` also appears in PROSE inside STRINGS and DATA
  # ("install podman or docker manually" in a log_warn; "requires docker specifically" in the
  # check-tools table). A naive /docker[[:space:]]+[a-z]/ flags those — the same lie, one level down.
  # So match docker only at a COMMAND POSITION: line-start, or after | && ; $( , or after run/sudo.
  # Prose reaches `docker` preceded by an ordinary word ("or docker", "requires docker") and is skipped.
  # NOTE a bare `(` is deliberately NOT a command position: English parentheses contain prose
  # ("(docker is only a fallback)" in the check-tools table) and matching them re-introduces the bug.
  # `$(` IS matched, which is the only form a real invocation takes here.
  # An EXPLICIT, REASONED exemption: a line ending `# docker-ok: <why>` is skipped. This is for a
  # docker command that runs ONLY on a branch the operator reached by CHOOSING docker
  # (CONTAINER_ENGINE=docker) — there, docker exists by construction, so the line is not a docker
  # REQUIREMENT. The marker is per-LINE and must carry a reason: an exemption you cannot read is an
  # exemption you cannot audit, and a by-filename allowlist would hide the next real dependency.
  # NOTE the marker DELETES THE WHOLE LINE (`/d`), it does not just strip the comment: the docker call
  # sits BEFORE the `#`, so blanking only the comment would leave the call behind and the exemption
  # would silently do nothing. (First draft did exactly that — caught by the RED test, not by reading.)
  if sed '/#[[:space:]]*docker-ok:/d' "$f" | sed 's/#.*//' | grep -qE \
       '(require_cmd|command -v|have|run|sudo)[[:space:]]+docker([[:space:]]|$)|(^|[;&|]|\$\()[[:space:]]*docker[[:space:]]+[a-z]|docker\.sock'; then
    offenders="${offenders} ${b}"
  fi
done
if [ -z "$offenders" ]; then
  ok "no docker dependency in ${scanned} operator-flow scripts (real-lab path = podman + crane; \`make deps\` installs neither docker nor a daemon)"
else
  bad "operator-flow script(s) invoke/require docker:${offenders} — an air-gapped jump box that ran \`make deps\` has podman ONLY, so this breaks ON THE LAB"
fi

# 6. ALL THREE engine implementations must agree that podman is first.
#    container_engine() is not the only chooser: the Makefile has its own `command -v podman ... ||
#    echo docker` (it drives `make diagrams`), and jumpbox-run.sh has a third. Checks 1-3 above test
#    ONLY os.sh — so flipping the Makefile's `&&`/`||` order leaves this gate green while every
#    `make diagrams` silently switches engine. Assert each chooser puts podman BEFORE docker.
impls=0
check_impl() { # file, human name
  [ -f "$1" ] || return 0
  line="$(sed 's/#.*//' "$1" | grep -nE 'command -v podman|have podman' | head -1)"
  if [ -z "$line" ]; then bad "$2: no podman-first engine detection found (did it move?)"; return; fi
  impls=$((impls + 1))
  # podman must be the FIRST engine named on that line — `podman ... || ... docker`, never the reverse.
  if printf '%s' "$line" | grep -qE 'podman.*docker'; then
    ok "$2: podman is chosen before docker"
  else
    bad "$2: engine detection does not put podman first: ${line}"
  fi
}
check_impl Makefile                "Makefile CONTAINER_ENGINE ?="
check_impl scripts/jumpbox-run.sh  "jumpbox-run.sh JUMPBOX_ENGINE"
[ "$impls" -eq 2 ] || bad "expected 2 non-os.sh engine implementations, found ${impls} — a new one appeared, or one moved (the gate must cover EVERY chooser)"
ok "engine choosers covered: os.sh (checks 1-3) + ${impls} others"

if [ "$fail" = 0 ]; then
  echo "test-container-engine: OK"
  exit 0
fi
echo "test-container-engine: FAILED" >&2
exit 1
