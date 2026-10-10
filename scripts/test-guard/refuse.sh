#!/usr/bin/env bash
# ============================================================================
# scripts/test-guard/refuse.sh — the body of every stand-in under scripts/test-guard/bin/.
#
#   refuse.sh <tool> [argv...]
#
# WHAT THIS IS. scripts/run-test-set.sh (and scripts/lib/test-sandbox.sh) put scripts/test-guard/bin
# FIRST on PATH, so a unit test that reaches for a tool that can change a cluster, a registry, a
# container engine or another machine gets THIS instead of the real one: it says so, exits 97, and
# (when TEST_GUARD_LOG names a file) appends one line. A test that needs the tool puts its OWN stub
# dir in front, exactly as before -- a stub earlier on PATH wins and this is never reached.
#
# WHY IT IS A COMMITTED DIRECTORY and not something a helper builds in mktemp: a mktemp guard is
# deleted by the test's own `trap 'rm -rf "$T"' EXIT`, and a child the test backgrounded then
# outlives it and finds the REAL tool on PATH (MEASURED, BACKLOG B751). This directory exists
# before the first test and after the last, and no test's trap can remove it.
#
# OPT IN to the real tool, per test, by name:
#   export TEST_GUARD_ALLOW="docker kind"      # space-separated; this stand-in then execs the
#                                              # next `docker` on PATH that is not a stand-in
# DECLARE an expected refusal (still refused, not logged):
#   export TEST_GUARD_QUIET="kubectl"
# The rc is 97 on purpose: no tool it stands in for uses it, so "the guard fired" is
# distinguishable from "the tool failed" in a test log.
# ============================================================================
set -u

tool="${1:-}"; [ "$#" -gt 0 ] && shift
[ -n "$tool" ] || { printf 'test-guard: refuse.sh needs a tool name\n' >&2; exit 97; }

# The next executable of this name on PATH that is not one of the stand-ins.
_guard_next() {
  local d oldifs="$IFS"
  IFS=:
  for d in $PATH; do
    IFS="$oldifs"
    [ -n "$d" ] || continue
    # Skip EVERY guard directory, not only this one: a test that runs from a COPY of the repo has
    # two on PATH, and skipping only "mine" makes the two exec each other for ever (MEASURED).
    [ -e "$d/.test-guard" ] && continue
    if [ -f "$d/$1" ] && [ -x "$d/$1" ]; then printf '%s' "$d/$1"; return 0; fi
  done
  IFS="$oldifs"
  return 1
}

# _guard_exec <real> [argv...] — hand over to the real tool, ONCE. MEASURED: when the next
# `kubectl` on PATH is a version manager's shim with no active version for the directory the test
# is in (a mise shim, a test that cd'ed into its own temp root), the shim execs the next kubectl
# on PATH, which is this stand-in again, and the two exec each other for ever at full CPU: the
# test never ends. So the hand-over is marked in the real tool's environment, and a stand-in
# entered WITH its own mark knows the "real" tool came back and stops: rc 127, as for no tool.
_guard_exec() {
  if [ "${__TEST_GUARD_HANDED:-}" = "$tool" ]; then
    printf 'test-guard: the %s behind the guard came straight back to the guard (a version-manager shim with no active version execs the next %s on PATH): no real %s is usable from here\n' "$tool" "$tool" "$tool" >&2
    exit 127
  fi
  __TEST_GUARD_HANDED="$tool" exec "$@"
}

case " ${TEST_GUARD_ALLOW:-} " in
  *" $tool "*)
    if _real="$(_guard_next "$tool")"; then _guard_exec "$_real" "$@"; fi
    printf 'test-guard: %s is allowed by TEST_GUARD_ALLOW but is not installed\n' "$tool" >&2
    exit 127 ;;
esac

# ---- invocations that contact NOTHING are let through ------------------------------------------
# These read a local file or print the client's own version; refusing them would change what the
# scripts under test do on a box that has the tool, for no safety gained. The list is CLOSED and
# short on purpose -- anything not named here is refused. MEASURED need (fast tier, 2026-10-09):
#   kubectl ... config view ...   lib/state.sh state_kubeconfig_server parses a FIXTURE kubeconfig
#   kubectl config current-context / get-contexts / get-clusters / get-users   (same: file only)
#   kubectl kustomize <local dir> validate/count tests render fixture trees
#   kubectl / argocd version --client
#   sudo -n true                  lib/os.sh's once-per-process capability probe, run at SOURCE time
#                                 by every script. Answered as a box that wants a password (rc 1,
#                                 the state the probe is silent about) and NOT logged: it is not a
#                                 privileged operation and it would bury every real hit.
_guard_takes_value() {  # rc 0 for an option of kubectl/argocd this file KNOWS consumes the next word
  case "$1" in
    --kubeconfig|--context|--cluster|--user|-n|--namespace|-s|--server|--request-timeout|--as|\
    --as-group|--token|--certificate-authority|--client-certificate|--client-key|--cache-dir|\
    -o|--output|--config|--kube-context|--grpc-web-root-path|--loglevel|--logformat) return 0 ;;
  esac
  return 1
}
_guard_words() {  # the non-option words of a kubectl/argocd command line, one per line
  local skip=0 a
  for a in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      -*) if _guard_takes_value "$a"; then skip=1; fi ;;
      *) printf '%s\n' "$a" ;;
    esac
  done
}
# rc 0 when an option this file does NOT know stands BEFORE the subcommand. There, an option it
# takes for a boolean may really consume the next word (`--username config view get pods`: the
# words then read "config view" while kubectl runs `get pods`), so the only safe reading of an
# unknown one is "not on the list": refused. After the subcommand an unknown option is the
# subcommand's own (`config view --minify`) and is left alone.
_guard_unknown_global() {
  local skip=0 a
  for a in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
      --*=*) _guard_takes_value "${a%%=*}" || return 0 ;;
      -*)    if _guard_takes_value "$a"; then skip=1; else return 0; fi ;;
      *)     return 1 ;;
    esac
  done
  return 1
}
_guard_local_only() {
  local w a client=0 raw=0
  case "$tool" in
    sudo)
      [ "$*" = "-n true" ] || return 1
      printf 'sudo: a password is required\n' >&2
      exit 1 ;;
    kubectl|argocd)
      _guard_unknown_global "$@" && return 1
      w="$(_guard_words "$@" | head -2 | tr '\n' ' ')"
      for a in "$@"; do case "$a" in --client|--client=true) client=1 ;; --raw|--raw=true) raw=1 ;; esac; done
      case "$tool:$w" in
        # `config view --raw` PRINTS the credentials in the kubeconfig it resolves, and with no
        # --kubeconfig that is the one under HOME. Let through only where HOME is the sandbox's.
        kubectl:"config view "*)
          [ "$raw" -eq 0 ] && return 0
          [ -n "${TEST_SANDBOX:-}" ] || return 1
          case "${HOME:-}" in "$TEST_SANDBOX"/*) return 0 ;; esac
          return 1 ;;
        # the READ-ONLY kubeconfig subcommands: they parse a file and print; nothing is dialled
        # and nothing is written (use-context, set-*, delete-* DO write, and are refused)
        kubectl:"config current-context "*|kubectl:"config get-contexts "*|\
        kubectl:"config get-clusters "*|kubectl:"config get-users "*) return 0 ;;
        kubectl:"kustomize "*)
          # a render of a LOCAL directory; a remote base (a URL, a git host path) is refused
          a="$(_guard_words "$@" | sed -n 2p)"
          [ -d "$a" ] && return 0 ;;
        kubectl:"version "*|argocd:"version "*) [ "$client" -eq 1 ] && return 0 ;;
      esac ;;
  esac
  return 1
}
if _guard_local_only "$@"; then
  if _real="$(_guard_next "$tool")"; then _guard_exec "$_real" "$@"; fi
  printf 'test-guard: %s: command not found (no real %s behind the guard)\n' "$tool" "$tool" >&2
  exit 127
fi

# TEST_GUARD_QUIET="kubectl curl" -- a test's DECLARATION that it lets the script under test reach
# for these tools on purpose and expects the refusal (creds.sh probing a cluster that is not there).
# The tool is refused exactly as before; the refusal is just not LOGGED, so TEST_GUARD_LOG holds
# only the calls nobody declared. It never lets anything through -- that is TEST_GUARD_ALLOW.
_guard_quiet=0
case " ${TEST_GUARD_QUIET:-} " in *" $tool "*) _guard_quiet=1 ;; esac
if [ -n "${TEST_GUARD_LOG:-}" ] && [ "$_guard_quiet" -eq 0 ]; then
  # One line per refusal: test, tool, argv. A newline inside an argument would forge a second
  # record, so it is flattened.
  _argv="$*"; _argv="${_argv//$'\n'/ }"; _argv="${_argv//$'\t'/ }"
  printf '%s\t%s\t%s\n' "${TEST_GUARD_TEST:-?}" "$tool" "$_argv" >> "$TEST_GUARD_LOG" 2>/dev/null || true
fi
_show="$*"; _show="${_show//$'\n'/ }"
# shellcheck disable=SC2016  # the backticks are literal text in the message
printf 'test-guard: REFUSED a real `%s %s` -- a unit test must stub this tool, or opt in with TEST_GUARD_ALLOW="%s" (scripts/test-guard/refuse.sh)\n' \
  "$tool" "${_show:0:160}" "$tool" >&2
# kubectl alone answers as kubectl does on a box with NO CLUSTER: its own "connection refused" line
# and rc 1. That is what the suite sees in CI, and the scripts under test CLASSIFY kubectl's stderr
# (lib/os.sh classify_kube_failure) -- an unrecognised refusal text sent them down the
# "error this report does not classify" arm and turned an assertion of test-creds-show.sh red
# (MEASURED: its lab-off headline case, with rc 97 and with this, same run otherwise). The refusal
# is still logged above; only the SHAPE of the failure is kubectl's.
if [ "$tool" = kubectl ]; then
  printf 'The connection to the server localhost:8080 was refused - did you specify the right host or port?\n' >&2
  exit 1
fi
exit 97
