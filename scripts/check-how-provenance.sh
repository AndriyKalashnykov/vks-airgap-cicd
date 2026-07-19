#!/usr/bin/env bash
# check-how-provenance.sh — every `# how:` acquisition command in .env.example must be one we can
# actually stand behind. A gate, not a reminder.
#
# WHY THIS IS A GATE AND NOT A RULE:
#   The rule already existed ("check facts — no assumptions, no guessing", BLOCKING) and was loaded
#   the whole session. It still got violated: ARGOCD_KUBECONFIG was given a fabricated
#   `# how: vcf cluster kubeconfig get ... --export-file ...`, which is the WRONG subcommand (that
#   fetches a workload-cluster kubeconfig; ArgoCD runs on the Supervisor) for a file nothing in this
#   repo even creates. Prose loaded at the start of a session does not fire at the moment text is
#   generated. A check that runs does.
#
# THE CONTRACT — each `# how:` line must be exactly one of:
#   1. a `make <target>` we actually ship          -> the target must exist (verified mechanically)
#   2. a command built from tools WE run           -> kubectl / jq / crane / helm / openssl / curl ...
#   3. a VENDOR command we cannot execute here     -> MUST be tagged `(verified)`, `(inferred)`, or
#                                                      carry an UNVERIFIED note, so the reader can
#                                                      tell a proven command from a plausible one.
# Anything else is an unmarked guess, and that is the failure this gate exists to make impossible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

ENV_FILE="${REPO_ROOT}/.env.example"
[ -f "$ENV_FILE" ] || die "no .env.example"

# Tools this repo actually runs — a `# how:` built from these is self-verifying.
OURS='kubectl|jq|crane|helm|openssl|curl|make|git|base64|awk|sed|grep|podman|docker|kind|yq'
# Tools we CANNOT execute here (vendor/lab CLIs) — these need an explicit provenance tag.
VENDOR='vcf|kubectl-vsphere|govc|esxcli'

rc=0
n=0
while IFS= read -r line; do
  lineno="${line%%:*}"; text="${line#*:}"

  # Skip the CONVENTIONS legend itself (bullets that TALK about `# how:` rather than being one).
  printf '%s' "$text" | grep -qE '^#[[:space:]]*-' && continue
  n=$((n+1))

  # Already graded, or an explicit unknown, or an explicit "ask a human" -> honest, accept.
  if printf '%s' "$text" | grep -qiE '\((verified|inferred)\b|UNVERIFIED|ask (your|the) '; then
    continue
  fi

  # A VENDOR CLI anywhere in the command (not just as the first word) demands a provenance tag:
  # we cannot run it here, so an unmarked one reads as proven and gets copy-pasted.
  if printf '%s' "$text" | grep -qE "(^|[^a-z-])(${VENDOR})[[:space:]]"; then
    log_error ".env.example:${lineno}: '# how:' uses a vendor CLI we cannot run here, with NO provenance tag."
    log_error "    Mark it '(verified)' (you ran it on a lab), '(inferred)' (cited from docs, unproven),"
    log_error "    or replace it with an UNVERIFIED note stating what IS established."
    rc=1; continue
  fi

  # Names a make target -> it must actually exist.
  if printf '%s' "$text" | grep -qE '\bmake +[a-z0-9-]+'; then
    tgt="$(printf '%s' "$text" | grep -oE '\bmake +[a-z0-9-]+' | head -1 | awk '{print $2}')"
    grep -qE "^${tgt}:" "${REPO_ROOT}/Makefile" && continue
    log_error ".env.example:${lineno}: '# how:' names 'make ${tgt}', which is NOT a Makefile target"
    rc=1; continue
  fi

  # Built from tools we actually run -> self-verifying.
  printf '%s' "$text" | grep -qE "(^|[^a-z-])(${OURS})[[:space:]]" && continue

  log_warn ".env.example:${lineno}: '# how:' uses no tool we run and carries no provenance tag — grade it."
done < <(grep -n '# *how' "$ENV_FILE")

if [ "$rc" -eq 0 ]; then
  [ "$n" -gt 0 ] || die "check-how-provenance: examined 0 '# how:' commands in .env.example — EITHER the '# how:' convention moved out of .env.example (in which case RETIRE this gate, do not weaken it) OR the file is empty / the grep no longer matches. Naming both: a zero here is not automatically blindness."
  log_info "check-how-provenance: OK — all ${n} '# how:' commands are runnable-by-us, a real make target, or provenance-tagged."
else
  log_error "check-how-provenance: an acquisition command is an UNMARKED GUESS. Fix it or grade it."
fi
exit "$rc"
