#!/usr/bin/env bash
# state-restore.sh ARCHIVE=<name> — put one archived state overlay back as the sink (B723).
#
# Reversible by construction: the CURRENT sink is archived first (state_archive, never rm), and the
# exact command to swap back is printed. Only a name `make state-archives` lists as restorable is
# accepted: a bare file name (no path), a regular file you own, not a symlink.
# ⚠️ Run it with no other vks command in flight: a writer that read the old sink before the swap would
# write it back over the restored one. The swap is re-read and hash-checked, which catches most of that.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

a="${ARCHIVE:-}"
[ -n "$a" ] || die "set ARCHIVE=<name> — list them with: make state-archives"
case "$a" in */*|.|..) die "ARCHIVE must be a bare file name from 'make state-archives', not a path: '${a}'" ;; esac

sink="$(state_file)"
path="$(dirname "$sink")/$a"
# ⚠️ awk must DRAIN its input: an early `exit` SIGPIPEs the producer and pipefail + set -e then kills
# this script with rc=141 -- measured, intermittently, in test-state-archives.sh.
cls="$(state_archive_candidates | awk -F'\t' -v p="$path" '$2 == p && !f { print $1; f = 1 }')"
case "$cls" in
  stale|other) : ;;
  temp)    die "'${a}' is a state_unset temp leftover, not an archive" ;;
  symlink) die "'${a}' is a symlink — restoring it would make the sink a link. Refused." ;;
  '')      die "'${a}' is not an archive of $(basename "$sink") — list them with: make state-archives" ;;
esac
[ -f "$path" ] && [ ! -L "$path" ] || die "'${a}' is not a regular file"
[ -O "$path" ] || die "'${a}' is not owned by you — refused"
[ ! -L "$sink" ] || die "the current $(basename "$sink") is a symlink — refused; inspect it first"
if [ "$cls" = other ]; then log_warn "'${a}' was not written by state_archive (an unrecognised producer) — restoring it anyway, as you asked"; fi

want="$(cksum < "$path")"
STATE_ARCHIVED_AS=""
if [ -f "$sink" ]; then
  state_archive "replaced by 'make state-restore ARCHIVE=${a}'"
fi
# `ln` + `rm`, not `mv`: link(2) fails if the sink REAPPEARED (a concurrent writer) instead of
# silently overwriting it. The archive is only removed once the sink is its hard link.
ln "$path" "$sink" 2>/dev/null || die "$(basename "$sink") reappeared while restoring (another vks command wrote it). Nothing was deleted; see 'make state-archives'."
rm -f "$path"
[ ! -L "$sink" ] || die "$(basename "$sink") is a symlink after the restore -- refused; inspect it"
chmod 600 "$sink"
[ "$(cksum < "$sink")" = "$want" ] || die "the restored $(basename "$sink") does not match '${a}' — another command wrote it during the swap. Nothing was deleted; see 'make state-archives'."

# printed below, and a hand-made archive is untrusted: strip C0 AND C1 control bytes.
srv="$(grep -m1 '^VKS_STATE_SERVER=' "$sink" | cut -d= -f2- | tr -d '"' | state_strip_controls || true)"
kc="$(grep -m1 '^KUBECONFIG=' "$sink" | cut -d= -f2- | tr -d '"' | state_strip_controls || true)"
log_info "restored $(basename "$sink") from ${a}"
if [ -z "$srv" ]; then
  log_warn "  it is UNSTAMPED: every command without an explicit KUBECONFIG now sources it as-is"
else
  log_info "  it is stamped for ${srv}"
  cur=""
  if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG%%:*}" ]; then cur="$(state_kubeconfig_server "${KUBECONFIG%%:*}" 2>/dev/null | state_strip_controls || true)"; fi
  if [ -z "$cur" ]; then log_info "  your KUBECONFIG's server: unknown"
  elif [ "$cur" = "$srv" ]; then log_info "  your KUBECONFIG points at the same server, so it will be used"
  else log_warn "  your KUBECONFIG points at ${cur}, so an explicit-KUBECONFIG command will NOT source it"; fi
fi
if [ -n "$kc" ]; then
  if [ -f "$kc" ]; then log_info "  it selects KUBECONFIG=${kc} (the file exists)"
  else log_warn "  it selects KUBECONFIG=${kc}, which does NOT exist on this box"; fi
fi
[ ! -f "${REPO_ROOT}/.env.kind" ] || log_warn "  a legacy .env.kind exists and is sourced LAST — it shadows this restore (make state-migrate)"
if [ -n "${STATE_ARCHIVED_AS:-}" ]; then
  log_info "to undo: make state-restore ARCHIVE=$(basename "$STATE_ARCHIVED_AS")"
fi
