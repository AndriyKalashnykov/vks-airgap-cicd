#!/usr/bin/env bash
# check-vks-provenance.sh — every FACT ROW in a docs/vks-services Confidence table must carry a
# resolvable [src:] citation token. A grade word ("9.1-doc", "community", "KinD-verified") names the
# SHAPE of the evidence; it does not tell a reader WHERE to check it.
#
# WHY A GATE AND NOT A RULE:
#   The Sources sections list URLs bound to no row, and the Confidence column is a bare grade — so a
#   reader cannot re-verify a fact without guessing. "Cite your sources" did not hold: ~35 fact rows
#   shipped with bare grades. A check that OPENS the cited line (and shape-checks the rest) does.
#
# THE TOKEN — each fact row must carry exactly one:
#   [src: code:<FILE>:<LINE>]  or  [src: code:<FILE>:<L1>-<L2>]   -> OFFLINE-VERIFIED: file+line must exist.
#   [src: url=<https://…> date=<YYYY-MM-DD> quote="<verbatim>"]   -> SHAPE-checked offline (url+date+quote present).
#   [src: cmd="<command>" out="<observed>" date=<YYYY-MM-DD>]     -> a lab/cluster observation (shape-checked).
#   [src: NOT-ESTABLISHED tried="<what was attempted>"]           -> an honest gap (shape-checked, accepted).
#
# HONEST LIMITATION: url=/cmd= arms are SHAPE-checked only (air-gap CI can't fetch / hit a lab). Only
# code:FILE:LINE and NOT-ESTABLISHED are truly offline-verified — the whole reason those are preferred.
# The gate covers Confidence-TABLE rows; load-bearing PROSE claims are a documented phase-2 residual.
# A quote= value must not contain a literal ']' (the token is matched up to the first ']').
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# Scope: every markdown table in docs/vks-services/*.md whose HEADER row contains 'Confidence'. A new
# Confidence table in a new file is caught automatically; README.md's legend ('| Grade | Means |') has
# no Confidence column, so it is out of scope by the header match, not a hand-kept skip list.
mapfile -t DOCS < <(git ls-files -- 'docs/vks-services/*.md' | sort)

# awk emits "<line>\t<token-or-MISSING>" for each fact row inside a Confidence table. A real header is
# a 'Confidence' pipe-row IMMEDIATELY FOLLOWED BY a |---| separator — anchoring on the separator (not on
# the word alone) means a mid-table DATA cell that merely mentions "confidence" cannot be misread as a
# new header (the fake-green H1). POSIX awk only (no gawk-isms) so it runs under the box/CI mawk.
emit_rows() {
  awk '
    function issep(s) { return s ~ /^[[:space:]]*\|[ :|-]+\|[[:space:]]*$/ }
    {
      if (issep($0) && prev ~ /\|.*[Cc]onfidence.*\|/) { intable = 1; prev = $0; next }
      if (intable && $0 ~ /^[[:space:]]*\|/) {
        if (match($0, /\[src:[^]]*\]/)) printf "%d\t%s\n", FNR, substr($0, RSTART, RLENGTH)
        else printf "%d\tMISSING\n", FNR
        prev = $0; next
      }
      if (intable) intable = 0
      prev = $0
    }
  ' "$1"
}

rows=0; bad=0; coderefs=0; scanned=0
for f in "${DOCS[@]}"; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  while IFS=$'\t' read -r ln tok; do
    [ -n "$ln" ] || continue
    rows=$((rows + 1))
    if [ "$tok" = MISSING ]; then
      log_error "$f:$ln: fact row carries a grade but NO [src:] token (a grade is not a citation)"; bad=$((bad + 1)); continue
    fi
    # Classify by the FIRST field after '[src:' — anchored, so a url/cmd quote that happens to contain
    # 'code:' is not misrouted to the code-ref arm.
    inner="${tok#\[src:}"; inner="${inner# }"
    case "$inner" in
      code:*)
        coderefs=$((coderefs + 1))
        ref="$(printf '%s' "$tok" | sed -n 's/.*code:\([^] ]*\).*/\1/p')"   # FILE:LINE or FILE:L1-L2
        cfile="${ref%%:*}"; spec="${ref#*:}"
        if [ ! -f "$cfile" ]; then log_error "$f:$ln: [src: code:$cfile] — file does not exist"; bad=$((bad + 1)); continue; fi
        total="$(awk 'END{print NR}' "$cfile")"   # counts an unterminated last line (wc -l would not)
        ok=1
        for L in "${spec%%-*}" "${spec#*-}"; do
          case "$L" in ''|*[!0-9]*) log_error "$f:$ln: [src: code:$ref] — bad line spec"; ok=0; break ;; esac
          if [ "$L" -lt 1 ] || [ "$L" -gt "$total" ]; then
            log_error "$f:$ln: [src: code:$cfile:$L] — line out of range ($cfile has $total)"; ok=0; break
          fi
        done
        [ "$ok" = 1 ] || { bad=$((bad + 1)); continue; }
        ;;
      url=*)
        case "$tok" in *date=*) : ;; *) log_error "$f:$ln: url token missing date=YYYY-MM-DD"; bad=$((bad + 1)); continue ;; esac
        case "$tok" in *quote=*) : ;; *) log_error "$f:$ln: url token missing a quote=\"…\""; bad=$((bad + 1)); continue ;; esac
        ;;
      cmd=*)
        case "$tok" in *out=*) : ;; *) log_error "$f:$ln: cmd token missing out=\"…\""; bad=$((bad + 1)); continue ;; esac
        ;;
      NOT-ESTABLISHED*)
        case "$tok" in *tried=*) : ;; *) log_error "$f:$ln: NOT-ESTABLISHED token missing tried=\"…\""; bad=$((bad + 1)); continue ;; esac
        ;;
      *)
        log_error "$f:$ln: unrecognized [src:] token: $tok"; bad=$((bad + 1)); continue
        ;;
    esac
  done < <(emit_rows "$f")
done

# A gate that found 0 fact rows is broken, not green (the service docs have Confidence tables by construction).
[ "$rows" -gt 0 ] || die "check-vks-provenance: scanned $scanned doc(s) but found 0 Confidence-table rows — table detection broke."

if [ "$bad" -gt 0 ]; then
  log_error "check-vks-provenance: $bad of $rows fact row(s) lack a resolvable [src:] citation (scanned $scanned docs, $coderefs code-refs opened)."
  echo "  A grade word is not a citation. Append one per row:"
  echo "    [src: code:FILE:LINE] | [src: url=… date=… quote=\"…\"] | [src: cmd=… out=… date=…] | [src: NOT-ESTABLISHED tried=\"…\"]"
  exit 1
fi

log_info "check-vks-provenance: OK — scanned $scanned doc(s), all $rows Confidence-table fact rows carry a resolvable [src:] token ($coderefs code-refs opened + verified)."
exit 0
