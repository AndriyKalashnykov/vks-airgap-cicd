#!/usr/bin/env bash
# ci-tier: fast — offline; throwaway dirs under mktemp, no network, no cluster, no real $HOME.
#
# test-secret-dir-mode.sh — `ensure_secret_dir` must harden OUR secrets/ and touch NOTHING ELSE.
#
# B174. `secrets/` is born 0775 at umask 002, and `Makefile:132` `-include`s `secrets/.env.make`,
# so a group-writable DIRECTORY lets any group member unlink-and-recreate that file regardless of
# its own 0600 — make-variable injection. The obvious fix is "chmod 700 wherever we mkdir", and it
# is REFUTED TWICE OVER, which is why the containment predicate exists and why this file is mostly
# SKIP cases:
#
#   * `shell_rc_file()` returns `$HOME/.bashrc` (bash), `${ZDOTDIR:-$HOME}/.zshrc` (zsh),
#     `$HOME/.kshrc` (ksh) — dirname is `$HOME` EXACTLY for three of the four supported shells.
#   * `set_env_var`'s mkdir takes `${REPO_ROOT}/.env` at three call sites — dirname is the
#     REPOSITORY WORKING TREE.
#
# Either would be an unrequested, irreversible permission change on a machine we do not own. The
# SKIP cases below are therefore the point of this file, not padding: a change that made the
# predicate more permissive would still pass the HARDEN cases alone.
#
# ⚠️ THIS ROW'S TWO PREVIOUS FIXES BOTH DIED ON A GNU-ONLY FLAG that toybox accepts and IGNORES —
# `mkdir -p -m 700`, then `install -d -m 700`. Each passed on every dev box and did nothing on
# Photon, the PRIMARY air-gap OS. That is why the helper resolves with `cd … && pwd -P` and not
# `realpath -m`: `31-fetch-argocd-kubeconfig.sh:59` already records that "toybox's realpath is not
# guaranteed on Photon". If someone reintroduces realpath here, this file will still pass on a dev
# box — so the guard is the COMMENT plus the grep at the bottom, not these cases.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh >/dev/null 2>&1

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
REPO="$T/repo"; FAKEHOME="$T/fakehome"
mkdir -p "$REPO/x" "$FAKEHOME"
export REPO_ROOT="$REPO"

chk() {  # <label> <path> <HARDEN|SKIP> <pre-mode>
  local lbl="$1" d="$2" want="$3" pre="$4" rp got
  mkdir -p "$d"; chmod "$pre" "$d"
  ensure_secret_dir "$d" >/dev/null 2>&1
  rp="$(cd "$d" && pwd -P)"; got="$(stat -c %a "$rp")"
  # `if`, not `A && B || C` — in that shape a non-zero `ok` also runs `bad`, which is the
  # fake-green form this repo's own gate flags (SC2015).
  if [ "$want" = HARDEN ]; then
    if [ "$got" = 700 ]; then ok "$lbl -> 700"
    else bad "$lbl: want 700, got ${got} (pre ${pre})"; fi
  else
    if [ "$got" = "$pre" ]; then ok "$lbl -> untouched (${got})"
    else bad "$lbl: MUST NOT be re-permissioned. was ${pre}, now ${got}.
        The containment predicate has been loosened, and this is a directory we do not own."; fi
  fi
}

chk 'our secrets/'                          "$REPO/secrets"                HARDEN 775
chk 'nested app secrets/'                   "$REPO/apps/secrets"           HARDEN 775
chk 'traversal INTO secrets/ still hardens' "$REPO/x/../secrets"           HARDEN 775
chk 'the REPO ROOT (set_env_var .env)'      "$REPO"                        SKIP   775
# shellcheck disable=SC2016  # '$HOME' is a LABEL naming the variable, not a reference to it —
# expanding it would print the operator's real home directory into the test output.
chk 'a fake $HOME (shell-init)'             "$FAKEHOME"                    SKIP   755
chk 'a fake ~/.kube (KUBECONFIG)'           "$FAKEHOME/.kube"              SKIP   755
chk 'a mktemp dir (lib/tls.sh)'             "$T/scratch"                   SKIP   700
chk 'traversal OUT of secrets/'             "$REPO/secrets/../../fakehome2" SKIP  755

# REPO_ROOT unset must CREATE and never harden: the patterns would degrade to `/secrets/`, which
# could match a real system path. Refusing to guess is the correct behaviour.
mkdir -p "$T/orphan/secrets"; chmod 775 "$T/orphan/secrets"
( unset REPO_ROOT; ensure_secret_dir "$T/orphan/secrets" >/dev/null 2>&1 )
if [ "$(stat -c %a "$T/orphan/secrets")" = 775 ]; then
  ok 'REPO_ROOT unset -> created, never hardened (refuses to guess)'
else
  bad "with REPO_ROOT unset the helper must not harden anything — the patterns degrade to /secrets/"
fi

# The directory must still be CREATED even where hardening is skipped, or the helper is a
# regression on the bare `mkdir -p` it replaced.
if ensure_secret_dir "$T/brand/new/deep" >/dev/null 2>&1 && [ -d "$T/brand/new/deep" ]; then
  ok 'creates a deep path even when the target is outside our tree'
else
  bad 'ensure_secret_dir must still mkdir -p; it replaced a bare mkdir at 8 call sites'
fi

# ⚠️ THE PORTABILITY GUARD, and it is the one that matters most for this row. Both previous fixes
# were GNU-only no-ops on toybox. These cases cannot catch that — they run on a dev box — so
# assert the IDIOM instead.
# ⚠️ The `realpath` arm is a HERESTRING, not a pipe. `producer | grep -q` lets grep exit at its
# first match, SIGPIPEs the producer, and under pipefail reports a FOUND pattern as ABSENT — which
# here would silently turn "someone reintroduced realpath" into a CLEAN pass, i.e. the false green
# this whole guard exists to prevent. `check-grep-q-pipe` caught it in this very file.
_body="$(grep -A25 '^ensure_secret_dir()' scripts/lib/os.sh)"
if grep -q 'pwd -P' scripts/lib/os.sh && ! grep -q 'realpath' <<< "$_body"; then
  # shellcheck disable=SC2016  # backticks + prose describing the IDIOM; nothing to expand.
  ok 'the helper resolves with `cd … && pwd -P`, not realpath (toybox has no guaranteed realpath)'
else
  bad "ensure_secret_dir must not use realpath: 31-fetch-argocd-kubeconfig.sh:59 records that
        toybox's realpath is not guaranteed on Photon, the PRIMARY air-gap OS. This row has
        already shipped TWO fixes that were silent no-ops there (mkdir -p -m, install -d -m)."
fi

[ "$fail" -eq 0 ] || exit 1
# shellcheck disable=SC2016  # same: '$HOME' names the variable in a sentence.
printf 'SUCCESS — our secrets/ is hardened; $HOME, the repo root, ~/.kube and mktemp dirs are not.\n'
