#!/usr/bin/env bash
# Reconcile docs/walk-env-manifest.tsv against the scenario documents. Offline; no lab, no network.
#
# The manifest is what the walkthrough harness MAY pre-supply, per scenario. It is a hand-maintained
# decision table, and this repo's standing rule is that enumerated lists rot -- so this gate exists to
# make sure it cannot rot SILENTLY. It reconciles BOTH directions:
#
#   a) a (scenario, key) the documents name with NO manifest row  -> REFUSE. Somebody added a key to
#      a document and nobody decided what the harness does about it.
#   b) a manifest row for a (scenario, key) no document names     -> REFUSE unless the reason says so.
#      Either the key was renamed out of the document and the row is dead, or the harness is
#      supplying something no reader could produce -- and the row must SAY which.
#
# A rotting list that announces its own rot is a reviewable decision record. One that does not is a
# hazard, which is what the hand-typed list in walk_env() was.
#
# WHAT THIS GATE DOES NOT DO: it does not check that the harness OBEYS the manifest. That is the
# harness's own assertion, in its repo, because only it knows what it emits. This gate owns the
# question "is every key accounted for", which is answerable from the documents alone.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT" || { echo "ERROR check-walk-env-manifest: cannot cd to ${REPO_ROOT}"; exit 2; }
MANIFEST="docs/walk-env-manifest.tsv"

[ -s "$MANIFEST" ] || { echo "ERROR check-walk-env-manifest: $MANIFEST is missing or empty."; exit 2; }

# The DOCUMENT set. Its exporter refuses rather than emitting a short list, so a non-zero exit here
# is a real failure and not something to shrug through -- a short doc set would make direction (a)
# pass vacuously, which is the exact fake-green this gate exists to prevent.
if ! doc_pairs="$("${SCRIPT_DIR}/walk-env-keys.sh" 2>/tmp/wek.err)" || [ -z "$doc_pairs" ]; then
  echo "ERROR check-walk-env-manifest: walk-env-keys.sh produced nothing. It refuses on a broken"
  echo "  parse rather than emitting a short set, so this is a real failure, not a skip:"
  sed 's/^/    /' /tmp/wek.err 2>/dev/null
  exit 2
fi

# The MANIFEST set. Reject a malformed row loudly: a row with fewer than 4 fields silently drops out
# of every comparison below, which would make BOTH directions pass while the row does nothing.
man_pairs=""
bad=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  case "$line" in ''|'#'*) continue ;; esac
  n="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  scen="$(printf '%s' "$line" | cut -f1)"
  key="$(printf '%s' "$line"  | cut -f2)"
  disp="$(printf '%s' "$line" | cut -f3)"
  why="$(printf '%s' "$line"  | cut -f4)"
  if [ "$n" -lt 4 ] || [ -z "$key" ] || [ -z "$why" ]; then
    echo "  MALFORMED  line ${lineno}: needs 4 TAB-separated fields with a non-empty reason"
    printf '             %s\n' "$(printf '%s' "$line" | cut -c1-90)"
    bad=1; continue
  fi
  case "$scen" in scenario-1|scenario-2) ;; *)
    echo "  BAD SCENARIO  line ${lineno}: '${scen}' (expected scenario-1 or scenario-2)"; bad=1; continue ;;
  esac
  case "$disp" in EMIT|EXEMPT|FORBID) ;; *)
    echo "  BAD DISPOSITION  line ${lineno}: '${disp}' (expected EMIT, EXEMPT or FORBID)"; bad=1; continue ;;
  esac
  man_pairs="${man_pairs}${scen}	${key}
"
done < "$MANIFEST"

man_pairs="$(printf '%s' "$man_pairs" | grep -c . >/dev/null 2>&1 && printf '%s' "$man_pairs" | sort -u || true)"
if [ -z "$man_pairs" ]; then
  echo "ERROR check-walk-env-manifest: parsed ZERO usable rows out of ${MANIFEST}."
  echo "  A gate that compares an empty set against anything passes vacuously. Refusing."
  exit 2
fi

doc_pairs="$(printf '%s\n' "$doc_pairs" | sort -u)"

# (a) documented, undecided.
undecided="$(comm -23 <(printf '%s\n' "$doc_pairs") <(printf '%s\n' "$man_pairs"))"
# (b) decided, undocumented.
orphan="$(comm -13 <(printf '%s\n' "$doc_pairs") <(printf '%s\n' "$man_pairs"))"

rc=0
if [ -n "$undecided" ]; then
  echo "  A scenario document names these, and ${MANIFEST} has no row for them:"
  printf '%s\n' "$undecided" | sed 's/^/    /'
  echo
  echo "  Add a row per (scenario, key), and decide:"
  echo "    EMIT   <why a READER would have this value>"
  echo "    EXEMPT <what produces it, or which .env.example default stands in>"
  echo "    FORBID <which documented command supplying it would skip, or which persona lacks it>"
  rc=1
fi
if [ -n "$orphan" ]; then
  # An orphan is only legitimate when the reason SAYS it is -- otherwise it is a dead row left behind
  # by a rename, and a dead row is how the list rots without anyone noticing.
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    sc="${pair%%	*}"; kk="${pair##*	}"
    row="$(awk -F'\t' -v s="$sc" -v k="$kk" '$1==s && $2==k {print $3"\t"$4}' "$MANIFEST" | head -1)"
    dd="${row%%	*}"; r="${row#*	}"
    # A FORBID row is a STANDING PROHIBITION -- "never supply this here". Whether the document
    # happens to name the key is beside the point; forbidding a key the document does NOT name is
    # the strongest form of the row, not a defect. (scenario-1 HARBOR_PASSWORD is exactly that: the
    # document does not name it BECAUSE §8.5 fetches it, and the harness must not pre-empt that.)
    if [ "$dd" = FORBID ]; then
      printf '  ok (FORBID)    %-11s %s\n' "${sc#scenario-}" "$kk"
      continue
    fi
    # ⚠️ STRUCTURAL, not a prose substring. This used to be
    #     *"never names it"*|*"no document names"*|*B471*
    # -- and that third alternative is a BACKLOG ROW ID matched against free text. MEASURED
    # 2026-08-26: 8 rows mentioned B471 and FIVE escaped on that literal ALONE. So a copy-edit
    # removing `B471:` from a reason -- changing no decision -- turned five rows ORPHAN and
    # reddened this gate, while any future reason that happened to mention B471 got a free pass.
    # Column 5 (`undocumented`) says the thing the prose was being asked to imply.
    _flag="$(awk -F'\t' -v s="$sc" -v k="$kk" '$1==s && $2==k {print $5}' "$MANIFEST" | head -1)"
    case "$_flag" in
      undocumented)
        printf '  ok (declared)  %-11s %s\n' "${sc#scenario-}" "$kk" ;;
      *)
        printf '  ORPHAN         %-11s %-26s no document names it, and column 5 does not say `undocumented`\n' "${sc#scenario-}" "$kk"
        rc=1 ;;
    esac
  done <<< "$orphan"
fi

d="$(printf '%s\n' "$doc_pairs" | grep -c .)"
m="$(printf '%s\n' "$man_pairs" | grep -c .)"
[ "$bad" -eq 0 ] || rc=1
if [ "$rc" -eq 0 ]; then
  echo "check-walk-env-manifest: OK — ${d} documented (scenario, key) pair(s), ${m} manifest row(s), every one decided."
else
  echo
  echo "ERROR check-walk-env-manifest: ${d} documented pair(s) vs ${m} manifest row(s) — see above."
fi
exit "$rc"
