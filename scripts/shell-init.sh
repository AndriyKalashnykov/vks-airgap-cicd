#!/usr/bin/env bash
# shell-init.sh — put the pinned toolchain on the OPERATOR'S OWN interactive PATH, permanently.
#
# WHY THIS EXISTS. `make deps` installs kubectl/helm/crane/yq/tkn/argocd under mise and
# $HOME/.local/bin. Every `make` target resolves them (the Makefile prepends both), but the runbook
# also tells the reader to run RAW commands — `kubectl -n "$VKS_NAMESPACE" get storagepolicyquotas`
# in scenario-1 §1b, `vcf context create` in §3, `argocd login` in §3. Those run in THEIR shell,
# which has neither path. MEASURED on a bare photon:5.0 walking the doc literally: every raw command
# returned `kubectl: command not found` while `make check-tools` reported all tools present.
#
# The doc used to say `>> ~/.bashrc   # or ~/.zshrc`, which hands the reader a decision we can make
# for them and is wrong for anyone on zsh or fish. This target makes it.
#
# IT IS IDEMPOTENT AND APPEND-ONLY. It never rewrites a line, never reorders a file, and refuses
# rather than guessing when it cannot identify the shell. Re-running is a no-op.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

BIN_DIR="${BIN_DIR:-${HOME}/.local/bin}"
RC="$(shell_rc_file)"
ACT="$(shell_activate_line)"

if [ -z "$RC" ] || [ -z "$ACT" ]; then
  log_error "cannot identify your interactive shell from SHELL='${SHELL:-unset}'."
  log_error "  Supported: bash, zsh, fish, ksh. Add mise activation by hand:"
  log_error "      https://mise.jdx.dev/getting-started.html"
  log_error "  Or, for this shell only:  export PATH=\"${BIN_DIR}:\$PATH\""
  exit 1
fi

log_info "shell: $(basename "$SHELL")   rc file: $RC"

# A `mise activate` line already present (ours or the operator's own) means there is nothing to do.
# Match the COMMAND, not our exact spelling — an operator who wrote their own activation with
# different quoting must not get a second, redundant one appended.
if [ -f "$RC" ] && grep -q 'mise activate' "$RC"; then
  log_info "already activated in $RC — nothing to do."
  log_info "  Open a NEW shell (or: source '$RC') if the tools are still not on your PATH."
  exit 0
fi

mkdir -p "$(dirname "$RC")"
# BOTH lines, and the PATH one FIRST. `eval "$(mise activate zsh)"` alone is a NO-OP on a fresh box,
# because mise ITSELF lives in $BIN_DIR and is not on PATH — so the activation silently evaluates
# nothing and the operator still gets `kubectl: command not found`. MEASURED 2026-08-10: with only
# the activate line, a new login zsh still could not find kubectl. This is the same root cause as
# the Makefile bug it was written to fix, reproduced one layer out in the rc file.
#
# shellcheck disable=SC2016  # the single quotes are the POINT: $PATH and `mise activate` must land
# in the rc file LITERALLY, to be expanded by the operator's shell at login. Expanding them here
# would freeze THIS process's PATH into their rc file forever.
{
  printf '\n# added by vks-airgap-cicd `make shell-init` — puts the pinned toolchain on PATH.\n'
  printf '# The PATH line must come FIRST: mise itself lives here, so the activation below cannot\n'
  printf '# run without it. It also covers the tools installed outside mise (kubectl, tkn, argocd).\n'
  case "$(basename "$SHELL")" in
    fish) printf 'set -gx PATH %s $PATH\n' "$BIN_DIR" ;;
    *)    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
  esac
  printf '%s\n' "$ACT"
} >> "$RC"

log_info "appended to $RC:"
log_info "    export PATH=\"${BIN_DIR}:\$PATH\""
log_info "    $ACT"

# BASH ONLY: ~/.bashrc is read by INTERACTIVE NON-LOGIN shells. An SSH session is an interactive
# LOGIN shell, which reads /etc/profile and then the FIRST of ~/.bash_profile, ~/.bash_login,
# ~/.profile — and NOT ~/.bashrc unless one of those sources it. Debian/Ubuntu ship a ~/.profile
# that does; PHOTON SHIPS NEITHER FILE, so on a Photon jump box everything we just wrote to
# ~/.bashrc is never read by the operator's actual session.
# MEASURED 2026-08-10 on photon:5.0 — `bash -l -i -c 'command -v kubectl'`: NOT FOUND with only
# ~/.bashrc; FOUND once a ~/.bash_profile sourcing it exists. (zsh needs none of this: ~/.zshrc IS
# read by an interactive login zsh — measured in the same run.)
# shellcheck disable=SC2016  # `~/.bashrc` must stay literal — it is read by their shell, not us.
if [ "$(basename "$SHELL")" = bash ] \
   && [ ! -f "$HOME/.bash_profile" ] && [ ! -f "$HOME/.bash_login" ] && [ ! -f "$HOME/.profile" ]; then
  printf '# created by vks-airgap-cicd `make shell-init`: a LOGIN bash reads this file, not\n' >  "$HOME/.bash_profile"
  printf '# ~/.bashrc. Without it an SSH session never sees the toolchain PATH set above.\n'    >> "$HOME/.bash_profile"
  printf '[ -f ~/.bashrc ] && . ~/.bashrc\n'                                                    >> "$HOME/.bash_profile"
  log_info "also created $HOME/.bash_profile (this OS shipped none, so a LOGIN bash would never"
  log_info "  have read $RC — your SSH sessions would have kept saying 'command not found')."
fi
log_info ""
log_info "It applies to NEW shells. For the one you are in right now:"
log_info "    source '$RC'"
log_info "Then check:  kubectl version --client   (and, after 'make install-vcf-clis', vcf version)"
