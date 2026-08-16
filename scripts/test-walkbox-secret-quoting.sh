#!/usr/bin/env bash
# ============================================================================
# walkbox_push_env writes secrets that the far side SOURCES (`set -a; . ~/.walk-secrets`), so the
# value is PARSED. It used to write them BARE — directly beneath a comment naming this exact
# failure — and no amount of doc advice could fix it: an operator can single-quote `.env`
# perfectly and this path still mangled it.
#
# The fixtures live in a DATA FILE, one per line. Two earlier versions of this test were written
# with the passwords inline and BOTH died on the fixture containing a backtick — which is one of
# the characters under test. A test whose fixtures cannot survive its own quoting tests nothing.
#
# The NEGATIVE CONTROL is the point: it re-runs every fixture through the OLD bare form and
# requires it to break. Without it, "6/6 intact" is equally consistent with an oracle that cannot
# tell intact from mangled.
# ============================================================================
set -uo pipefail
cd /home/andriy/projects/vks-work || exit 1
. scripts/lib/os.sh >/dev/null 2>&1
pass=0; fail=0; cbad=0; n=0
while IFS= read -r pw; do
  n=$((n+1))
  t=$(mktemp); printf "%s='%s'\n" VCF_CLI_VSPHERE_PASSWORD "$(esc_sq "$pw")" > "$t"
  # shellcheck disable=SC1090  # a generated temp fixture; following it is the whole point
  got=$( (set -a; . "$t"; set +a; printf '%s' "${VCF_CLI_VSPHERE_PASSWORD:-<PARSE-FAILED>}") 2>/dev/null )
  rm -f "$t"
  if [ "$got" = "$pw" ]; then pass=$((pass+1)); printf '  ok     %-12s -> intact\n' "$pw"
  else fail=$((fail+1)); printf '  BROKEN %-12s -> [%s]\n' "$pw" "$got"; fi

  t=$(mktemp); printf '%s=%s\n' VCF_CLI_VSPHERE_PASSWORD "$pw" > "$t"
  # shellcheck disable=SC1090  # same, for the negative control
  cgot=$( (set -a; . "$t"; set +a; printf '%s' "${VCF_CLI_VSPHERE_PASSWORD:-<PARSE-FAILED>}") 2>/dev/null )
  rm -f "$t"
  [ "$cgot" = "$pw" ] || { cbad=$((cbad+1)); printf '         (old bare form) -> [%s]\n' "$cgot"; }
done < "$(dirname "${BASH_SOURCE[0]}")/fixtures-passwords.txt"
printf '\n  FIXED: %d/%d intact.   NEGATIVE CONTROL (old bare form): %d/%d broken\n' "$pass" "$n" "$cbad" "$n"
[ "$fail" -eq 0 ] && [ "$cbad" -gt 0 ]
