#!/usr/bin/env bash
# state-archives.sh — list the archived state overlays beside the sink, READ-ONLY (B723).
#
# state_archive never deletes: it renames the sink to `<sink>.stale-<UTC>`, because it may hold the only
# copy of a cluster's generated passwords and discovered addresses. Nothing used to read those archives
# back. This prints, for each: its class, when it was archived (from its name) and last written (mtime),
# its stamp (which cluster it was written for), whether that stamp is the cluster you point at NOW, and
# the NAMES of the keys it holds — never a value, except the VKS_STATE_* stamp fields.
# Restore one with:  make state-restore ARCHIVE=<name>
#
# File-only: no cluster call (the "is it yours" check parses your kubeconfig and never dials), so a
# tenant can run it. Always exits 0.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

clean() { local v="$1"; printf '%s' "${v//[$'\001'-$'\037'$'\177']/}"; }   # no terminal escapes from a file
stamp_of() { grep -m1 "^$1=" "$2" 2>/dev/null | cut -d= -f2- | tr -d '"' || true; }

sink="$(state_file)"
cur_srv=""
if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG%%:*}" ]; then
  cur_srv="$(state_kubeconfig_server "${KUBECONFIG%%:*}" 2>/dev/null || true)"
fi

n=0; ns=0; no=0; nt=0; nl=0; nk=0
while IFS=$'\t' read -r cls p; do
  [ -n "$p" ] || continue
  n=$((n + 1)); name="$(basename "$p")"
  case "$cls" in stale) ns=$((ns + 1)) ;; other) no=$((no + 1)) ;; temp) nt=$((nt + 1)) ;; symlink) nl=$((nl + 1)) ;; esac
  printf '\n%s   [%s]\n' "$(clean "$name")" "$cls"
  case "$cls" in
    temp)    printf '    a state_unset temp leftover — NOT restorable\n'; continue ;;
    symlink) printf '    a SYMLINK — NOT restorable (restoring it would make the sink a link)\n'; continue ;;
    other)   printf '    NOT written by state_archive — an unrecognised producer; check it before restoring\n' ;;
  esac
  suf="${name##*.}"
  printf '    archived: %s   last written: %s   mode %s, %s bytes, owner %s\n' \
    "$(printf '%s' "$suf" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1 || echo '?')" \
    "$(date -u -r "$p" +%Y%m%d-%H%M%S 2>/dev/null || echo '?')" \
    "$(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p" 2>/dev/null || echo '?')" \
    "$(wc -c < "$p" | tr -d ' ')" "$(stat -c %U "$p" 2>/dev/null || stat -f %Su "$p" 2>/dev/null || echo '?')"
  srv="$(stamp_of VKS_STATE_SERVER "$p")"
  if [ -z "$srv" ]; then
    printf '    stamp: UNSTAMPED — restored, it is sourced as-is by every command that has no explicit KUBECONFIG\n'
  else
    nk=$((nk + 1))
    printf '    stamp: %s  (%s)  written %s  kind=%s\n' "$(clean "$srv")" "$(clean "$(stamp_of VKS_STATE_CONTEXT "$p")")" \
      "$(clean "$(stamp_of VKS_STATE_WRITTEN "$p")")" "$(clean "$(stamp_of VKS_STATE_KIND "$p")")"
    if [ -z "$cur_srv" ]; then printf '    yours now: unknown (no readable KUBECONFIG)\n'
    elif [ "$srv" = "$cur_srv" ]; then printf '    yours now: YES — the same API server as your KUBECONFIG\n'
    else printf '    yours now: no — your KUBECONFIG points at %s\n' "$(clean "$cur_srv")"; fi
  fi
  keys="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$p" 2>/dev/null | tr -d '=' | grep -v '^VKS_STATE_' || true)"
  line=""
  for k in $keys; do
    if state_key_is_secret "$k"; then line="${line}${k}(secret) "; else line="${line}${k} "; fi
  done
  printf '    keys: %s\n' "${line:-<none>}"
done < <(state_archive_candidates)

printf '\n%s archive(s) beside %s: %s stale, %s unrecognised, %s temp leftover(s), %s symlink(s); %s stamped\n' \
  "$n" "$(basename "$sink")" "$ns" "$no" "$nt" "$nl" "$nk"
[ "$n" -eq 0 ] || printf 'restore one (the current overlay is archived first, so it is reversible):\n  make state-restore ARCHIVE=<name>\n'
exit 0
