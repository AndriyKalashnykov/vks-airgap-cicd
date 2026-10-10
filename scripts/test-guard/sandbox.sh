#!/usr/bin/env bash
# ============================================================================
# scripts/test-guard/sandbox.sh — the ONE fence a unit test puts between itself and this machine.
#
# A test sources it THROUGH scripts/lib/test-sandbox.sh (a one-line pointer to this file; that file
# says why the code is not there):
#
#   # shellcheck source=scripts/lib/test-sandbox.sh
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
#
# Source it FIRST, before lib/os.sh and before the test builds anything of its own.
#
# WHY IT EXISTS. A test that runs a real script from scripts/ inherits everything that script
# reads: the operator's .env, the .env.state overlay holding discovered passwords, the Supervisor
# kubeconfig resolver (which defaults to a sibling lab's REAL kubeconfig under $HOME), $KUBECONFIG,
# and every tool on PATH. Each test used to assemble its own subset of the pins that close those,
# and a test that forgot one was a `ci-tier: fast` unit test making live calls to a real
# Supervisor (the header of test-harbor-admin-robot-guard.sh records one). This file is the whole
# set, in one place; scripts/test-sandbox-coverage.sh is the gate that every test which runs such
# a script either sources this or says why not.
#
# WHAT IT PINS (all exported, so every child inherits them):
#   REPO_ROOT                  a throwaway directory holding a COPY of .env.example, an EMPTY
#                              secrets/, and a symlink to every other top-level entry of the real
#                              repo -- so a script finds scripts/, docs/, images/ ... and finds NO
#                              .env, .env.state, .env.kind, bundle/ or secrets/supervisor.kubeconfig.
#                              ⚠️ `find "$REPO_ROOT/scripts"` sees a SYMLINK and descends nothing. A
#                              test that walks the tree uses $TEST_REAL_REPO, or keeps the real root
#                              with `TEST_SANDBOX_REPO_ROOT=keep` set before sourcing this.
#   SKIP_DOTENV=1              .env is not sourced. ⚠️ A test that WRITES a .env into its own
#                              sandbox root and wants it read passes SKIP_DOTENV=0 on that child.
#   VKS_STATE_FILE             UNSET, so the overlay is "$REPO_ROOT/.env.state" -- which does not
#                              exist in the sandbox root. (The overlay is sourced even under
#                              SKIP_DOTENV=1, so it needs closing separately from .env.)
#                              ⚠️ NOT a fixed absent path, and that was tried first. MEASURED: it
#                              diverted the overlay of 19 tests that own their root and expect it
#                              at <their root>/.env.state -- one went red, 18 stayed GREEN while
#                              reading and writing a different file than the one they assert on.
#   VKS_LAB_STATE_DIR          /nonexistent-lab   -- resolver candidate 4, the sibling lab.
#   VKS_SUPERVISOR_KUBECONFIG  /nonexistent       -- resolver candidate 1.
#   ARGOCD_KUBECONFIG          unset              -- resolver candidate 3, if the caller exported it.
#   KUBECONFIG                 UNSET, as in CI. The default a script then picks is under the
#                              sandbox REPO_ROOT or the sandbox HOME, where there is none.
#                              ⚠️ NOT /dev/null, and that was tried first. MEASURED: load_env reads
#                              a SET KUBECONFIG as the operator's explicit selection, so /dev/null
#                              sent 16 tests down that arm while they stayed green, and turned
#                              three that assert on the DEFAULT path red.
#   HOME                       an empty directory (the real one is kept in TEST_REAL_HOME).
#   TMPDIR                     inside the sandbox, so a test's own mktemp lands there.
#   http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy   UNSET (no_proxy is left).
#   (and the sandbox REPO_ROOT does NOT link the checkout's gitignored top-level state:
#   .registry.lock, out, .jumpbox, .claude, .deps-failed, links.md, token.md.)
#   PATH                       scripts/test-guard/bin FIRST: refusing stand-ins for the tools that
#                              reach a cluster, a registry, an engine or another machine. The
#                              test's own stub dir still goes in front of it.
#
# WHAT IT LEAVES ALONE: the test's working directory, its own variables, and any pin the test sets
# AFTER sourcing this -- a later assignment wins, exactly as before.
#
# LIFTING A PIN, for a root the test owns. Two lifts are in use and the coverage gate PRINTS every
# test that makes one, so the list cannot grow unseen:
#   export SKIP_DOTENV=0           (after sourcing) the test writes its OWN .env into a throwaway
#                                  root and needs load_env to read it. Safe while every root the
#                                  test uses is a sandbox: the operator's .env is in none of them.
#   TEST_SANDBOX_REPO_ROOT=keep    (BEFORE sourcing) REPO_ROOT is left alone -- neither set nor
#                                  exported. For a test that copies scripts/ into its own root and
#                                  lets lib/os.sh derive REPO_ROOT from the copy, and for a test
#                                  that assigns REPO_ROOT itself as a plain variable. (Without
#                                  `keep`, that plain assignment would update the EXPORTED value,
#                                  and every child would inherit the test's root instead of
#                                  deriving its own -- which is not what the test did before.) ⚠️ WHAT THIS RE-OPENS, asserted in
#                                  test-test-sandbox.sh: a child that sources the REAL lib/os.sh
#                                  derives the REAL root, so resolver candidate 2
#                                  (<repo>/secrets/supervisor.kubeconfig), the .env.state overlay,
#                                  the legacy .env.kind and the default <repo>/secrets/vks.kubeconfig
#                                  are reachable again. Use it only where every script the test
#                                  runs is the copy.
#
# CLEAN-UP COMPOSES WITH THE TEST'S OWN TRAP. Nearly every test does `trap 'rm -rf "$T"' EXIT`,
# which would REPLACE a trap set here. So `trap` is wrapped: an EXIT handler the test registers is
# recorded; at exit this file KILLS what the test left running, THEN runs the test's handler, then
# removes the sandbox. (Kill first: the handler deletes the stub dir a live child still has on PATH.) The wrapper acts only in the shell that sourced this file; a subshell's
# `trap ... EXIT` is passed straight through, so a `( ... )` exiting never removes the sandbox.
#
# WHAT IT IS NOT. Not a security boundary: a test can still name an absolute path, unset a pin or
# call a tool by full path. It closes the DEFAULTS, which is where every measured incident came
# from. And it cannot fence a dial made without a guarded tool (bash /dev/tcp, openssl, python).
#
# Exposed to the test:
#   TEST_SANDBOX          the sandbox directory (removed at exit)
#   TEST_SANDBOX_ROOT     the sandbox REPO_ROOT -- built in `keep` mode too, where it is not exported
#                         as REPO_ROOT, so a test can still pass it to one child explicitly
#   TEST_REAL_REPO        the real repository root, for READING fixtures and scripts
#   TEST_REAL_HOME        the caller's HOME before the pin
#   test_sandbox_repo [dir]   build another sandbox root (same shape) and print its path
# ============================================================================
# shellcheck shell=bash

# Sourced twice in one shell (a test sourcing a helper that also sources this): keep the first.
[ -n "${__TEST_SANDBOX_PID:-}" ] && [ "${__TEST_SANDBOX_PID}" = "$$" ] && [ -d "${TEST_SANDBOX:-/nonexistent}" ] && return 0
__TEST_SANDBOX_PID="$$"

TEST_REAL_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_REAL_HOME="${HOME:-}"
export TEST_REAL_REPO TEST_REAL_HOME

# mise locates its installs from HOME. Pin where they ARE before HOME moves, so a shim on the
# caller's PATH (jq, yq) still resolves; it is a tool locator and carries no lab state.
if [ -n "${HOME:-}" ]; then
  export MISE_DATA_DIR="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}"
  export MISE_CACHE_DIR="${MISE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mise}"
  export MISE_STATE_DIR="${MISE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mise}"
fi

TEST_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/vks-test-sandbox.XXXXXX")" || {
  printf 'test-sandbox: could not create a sandbox directory -- refusing to run unfenced\n' >&2
  exit 1
}
export TEST_SANDBOX
mkdir -p "$TEST_SANDBOX/home" "$TEST_SANDBOX/tmp" || exit 1

# test_sandbox_repo [dir] — a sandbox REPO_ROOT: .env.example COPIED, secrets/ EMPTY, every other
# top-level entry of the real repo a symlink. What is deliberately NOT carried: .env and every
# .env.* (the operator's values and discovered state), secrets/ and bundle/ (credentials, 12 GB),
# .git (a symlinked git dir would let a script write the real index).
test_sandbox_repo() {
  local d="${1:-}" e b
  [ -n "$d" ] || d="$(mktemp -d "$TEST_SANDBOX/repo.XXXXXX")" || return 1
  mkdir -p "$d/secrets" || return 1
  for e in "$TEST_REAL_REPO"/* "$TEST_REAL_REPO"/.[!.]*; do
    [ -e "$e" ] || continue
    b="${e##*/}"
    case "$b" in
      .git|.env|.env.*|secrets|bundle) continue ;;
      # GITIGNORED STATE a run leaves at the top level: a link to it would let a write through
      # "$REPO_ROOT/out" (or the lock, or the jump-box kubeconfig dir, or the harness's own
      # worktrees) land in the checkout. An explicit list: what is TRACKED cannot be asked at run
      # time without git (the bundle on an air-gapped box has none), and these are the top-level
      # names .gitignore gives to state, as opposed to build output inside a tracked directory.
      .registry.lock|out|.jumpbox|.claude|.deps-failed|links.md|token.md) continue ;;
    esac
    [ -e "$d/$b" ] || ln -s "$e" "$d/$b" || return 1
  done
  [ ! -f "$TEST_REAL_REPO/.env.example" ] || cp "$TEST_REAL_REPO/.env.example" "$d/.env.example" || return 1
  printf '%s' "$d"
}

# The sandbox root is ALWAYS built and named in TEST_SANDBOX_ROOT, so a test in `keep` mode can
# still hand it to the one child that runs a real script:  REPO_ROOT="$TEST_SANDBOX_ROOT" bash ...
TEST_SANDBOX_ROOT="$(test_sandbox_repo "$TEST_SANDBOX/repo")" || {
  printf 'test-sandbox: could not build the sandbox REPO_ROOT -- refusing to run unfenced\n' >&2
  rm -rf "$TEST_SANDBOX"; exit 1
}
export TEST_SANDBOX_ROOT
if [ "${TEST_SANDBOX_REPO_ROOT:-sandbox}" != keep ]; then
  REPO_ROOT="$TEST_SANDBOX_ROOT"
  export REPO_ROOT
fi

export SKIP_DOTENV=1
unset VKS_STATE_FILE
export VKS_LAB_STATE_DIR=/nonexistent-lab
export VKS_SUPERVISOR_KUBECONFIG=/nonexistent
unset ARGOCD_KUBECONFIG
unset KUBECONFIG
export HOME="$TEST_SANDBOX/home"
export TMPDIR="$TEST_SANDBOX/tmp"
# A proxy named in the environment sends a "loopback" request of ANY tool somewhere else, and the
# guard reads only what is on a command line. (no_proxy is left: it can only take hosts OUT.)
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy

# The guard goes first ONCE: run-test-set.sh has usually put it there already, and a second copy
# would only lengthen PATH.
__test_guard_bin="$TEST_REAL_REPO/scripts/test-guard/bin"
# ⚠️ FAIL CLOSED ON A GUARD THAT CANNOT RUN. A stand-in that lost its mode bit (a patch applied
# without modes, a checkout with core.fileMode off) is simply NOT FOUND by a PATH lookup, so the
# real tool behind it would answer and nothing would say so.
__test_guard_ok=1
if [ ! -x "$__test_guard_bin/kubectl" ] || [ ! -x "$__test_guard_bin/curl" ] || [ ! -x "$__test_guard_bin/../refuse.sh" ]; then __test_guard_ok=0; fi
# EVERY stand-in, not the two named above: one added later (tkn) arrives by patch with no mode bit.
for __test_guard_f in "$__test_guard_bin"/*; do
  if [ -f "$__test_guard_f" ] && [ ! -x "$__test_guard_f" ]; then __test_guard_ok=0; fi
done
unset __test_guard_f
if [ "$__test_guard_ok" -ne 1 ]; then
  printf 'test-sandbox: the test guard is missing or not executable: %s\n' "$__test_guard_bin" >&2
  printf '  refusing to run unfenced -- restore scripts/test-guard/ and make its files executable (chmod +x).\n' >&2
  rm -rf "$TEST_SANDBOX"; exit 1
fi
case ":$PATH:" in
  *":$__test_guard_bin:"*) : ;;
  *) PATH="$__test_guard_bin:$PATH" ;;
esac
export PATH
export TEST_GUARD_TEST="${TEST_GUARD_TEST:-$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-$0}")}"

# ---- clean-up that composes ------------------------------------------------------------------
__test_sandbox_user_exit=""

# Every live descendant of this shell, deepest first -- minus the subshell that is asking and its
# own children (the `ps` and `awk` below). `ps` is read ONCE, so the list is a snapshot: a child
# forked after it is missed, which is why the caller asks twice.
__test_sandbox_descendants() {
  # shellcheck disable=SC2016  # the awk program's $1/$2 are awk fields, not shell
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$__TEST_SANDBOX_PID" -v self="$BASHPID" '
    { pp[$1] = $2 }
    END {
      for (p in pp) {
        q = p; depth = 0; mine = 0
        while ((q in pp) && q != root && q != 1 && depth < 64) {
          if (q == self) { mine = 1; break }
          q = pp[q]; depth++
        }
        if (!mine && q == root && p != root) print depth, p
      }
    }' | sort -rn | awk '{ print $2 }'
}

# TERM every live descendant, a short grace, then KILL what remains.
__test_sandbox_killtree() {
  local __p __left
  # Forget the job table FIRST. The shell used to exit right after the test's own handler; now
  # more commands follow, and at the next one bash prints a "Killed  <command line>" notice for
  # every background job that ended -- into the test's own output. MEASURED: eight such lines
  # appeared in test-harbor-ca-refetch-advice.sh.
  disown -a 2>/dev/null
  __left="$(__test_sandbox_descendants || true)"
  [ -n "$__left" ] || return 0
  for __p in $__left; do kill -TERM "$__p" 2>/dev/null; done
  sleep 0.2
  for __p in $(__test_sandbox_descendants || true); do kill -KILL "$__p" 2>/dev/null; done
  return 0
}

# The LAST thing the owning shell does: kill anything the test's own handler started, then
# remove the sandbox.
__test_sandbox_final() {
  [ "$BASHPID" = "$__TEST_SANDBOX_PID" ] || return 0
  builtin trap - EXIT
  set +e
  __test_sandbox_killtree
  if [ -n "${TEST_SANDBOX:-}" ] && [ "${TEST_SANDBOX_KEEP:-0}" != 1 ]; then rm -rf "$TEST_SANDBOX"; fi
  return 0
}

__test_sandbox_setrc() { return "$1"; }

__test_sandbox_exit() {
  local __rc=$?
  [ "$BASHPID" = "$__TEST_SANDBOX_PID" ] || return 0
  # errexit off from here: the shell is on its way out, and a failing `kill` in the test's own
  # handler must not stop the rest of the clean-up.
  set +e
  builtin trap - EXIT
  # ⚠️ KILL FIRST -- BEFORE THE TEST'S OWN HANDLER, not after it. That handler is nearly always
  # `rm -rf "$T"`, and "$T" holds the stub dir. A child the test left running (a backgrounded
  # script still in its wait loop) would resolve its next fresh `kubectl` lookup from whatever is
  # left on PATH in the gap between that rm and a kill placed after it. MEASURED: with the kill
  # after the handler, test-test-sandbox.sh caught one such lookup landing on the guard.
  __test_sandbox_killtree
  # Then the test's own handler, with the test's exit status in $?, as if it were the only trap.
  # Its own `kill "$pid"` now finds nothing to kill, which every handler in the suite tolerates.
  if [ -n "$__test_sandbox_user_exit" ]; then
    # ⚠️ A handler may call `exit` itself (`trap 'rm -rf "$T"; exit "$rc"' EXIT`), and that would
    # end the shell before the clean-up below. MEASURED: an EXIT trap installed from inside an EXIT
    # handler is NOT run by that `exit`, so re-arming the trap does not help. `exit` is therefore
    # wrapped for the duration of the handler: the clean-up runs, then the real exit, same status.
    # shellcheck disable=SC2317,SC2329  # reached only if the test's handler calls `exit`
    exit() { local __c="${1:-$__rc}"; __test_sandbox_final; builtin exit "$__c"; }
    __test_sandbox_setrc "$__rc"
    eval "$__test_sandbox_user_exit"
    unset -f exit
  fi
  __test_sandbox_final
  return 0
}

# ⚠️ NO SIGNAL TRAPS HERE, DELIBERATELY. MEASURED: bash runs the EXIT trap by itself when TERM or
# HUP kills it, and dies at once. A TERM *handler* would instead be DEFERRED until the foreground
# child returns, so a killed test would linger for as long as the script it was running.
# shellcheck disable=SC2064  # every `builtin trap "$@"` below PASSES THROUGH the caller's own words
trap() {
  # Not the shell that owns the sandbox (a subshell, a function run in `$( )`): untouched.
  if [ "$BASHPID" != "${__TEST_SANDBOX_PID:-}" ]; then builtin trap "$@"; return; fi
  # bash reads a signal name in ANY case (`trap … Exit` sets the EXIT trap: MEASURED), so the
  # comparisons below are made on the upper-cased word. Spelled `exit` only, `Exit` replaced ours.
  local __a __is_exit=0 __n=0
  for __a in "$@"; do
    __n=$((__n + 1))
    [ "$__n" -gt 1 ] || continue
    case "${__a^^}" in EXIT|0) __is_exit=1 ;; esac
  done
  # `trap -p`, `trap -l`, a bare `trap`, or a handler for other signals only: not ours to touch.
  case "${1:-}" in -p|-l) builtin trap "$@"; return ;; esac
  [ "$#" -gt 0 ] || { builtin trap; return; }
  # `trap EXIT` (one argument) RESETS the handler: forget the test's, keep ours.
  if [ "$#" -eq 1 ]; then
    case "${1^^}" in EXIT|0) __test_sandbox_user_exit=""; return 0 ;; esac
    builtin trap "$@"; return
  fi
  if [ "$__is_exit" -eq 0 ]; then builtin trap "$@"; return; fi
  # An EXIT handler: record it (`-` and '' both mean "none"), keep ours installed, and hand any
  # OTHER signals named in the same call to the real builtin with the handler the test asked for.
  local __h="$1"; shift
  [ "$__h" != "--" ] || { __h="${1:-}"; shift; }
  case "$__h" in -|'') __test_sandbox_user_exit="" ;; *) __test_sandbox_user_exit="$__h" ;; esac
  local __rest=()
  for __a in "$@"; do case "${__a^^}" in EXIT|0) : ;; *) __rest+=("$__a") ;; esac; done
  [ "${#__rest[@]}" -eq 0 ] || builtin trap -- "$__h" "${__rest[@]}"
  builtin trap __test_sandbox_exit EXIT
}

# AN EXIT HANDLER THE TEST SET BEFORE IT SOURCED THIS FILE is kept, not replaced: the line below
# would otherwise drop it without a word. `trap -p EXIT` prints it re-readable (`trap -- '<handler>'
# EXIT`), so the handler is its third word. (Source this file FIRST all the same: the coverage
# gate asks for that, and a handler set earlier ran unfenced until here.)
__test_sandbox_prev="$(builtin trap -p EXIT 2>/dev/null || true)"
if [ -n "$__test_sandbox_prev" ]; then
  eval "__test_sandbox_prev=(${__test_sandbox_prev})"
  # shellcheck disable=SC2128  # after the eval it IS an array; index 2 is the handler
  [ "${#__test_sandbox_prev[@]}" -lt 4 ] || __test_sandbox_user_exit="${__test_sandbox_prev[2]}"
fi
unset __test_sandbox_prev
builtin trap __test_sandbox_exit EXIT
