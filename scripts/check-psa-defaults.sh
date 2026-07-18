#!/usr/bin/env bash
# check-psa-defaults.sh — the PSA level a script FALLS BACK to must equal the one .env.example
# DOCUMENTS, every fallback must name a level PSA actually accepts, and no reference may hide from
# this gate.
#
# WHY THIS IS A GATE AND NOT A RULE (B22):
#   A PSA level lives in two places by necessity: the use-site fallback (what actually runs when the
#   var is unset) and .env.example (what the operator reads and edits). Neither can be deleted —
#   .env.example is the documented source of truth AND, because load_env sources it unconditionally
#   (lib/os.sh:337-338), it is what supplies the value in every real run. So the honest fix is not to
#   eliminate a copy; it is to GATE that the copies agree.
#
# WHAT WAS REJECTED (do not re-propose — three adversary rounds, all measured):
#   1. "Put the defaults in lib/psa.sh as assign-if-unset." REFUTED: moves evaluation from the use
#      site to SOURCE time, and the sourcing order is split across the tree (psa.sh-first in
#      46/47/49/60; load_env-first in 07/40/41/45/70). With psa.sh first and an empty value in .env,
#      psa.sh's "empty level is a no-op" path applies NO LABEL and returns 0 — silently. On VKS the
#      ci namespace then falls back to the cluster default `restricted` and Kaniko (runAsUser=0) is
#      REJECTED. Same .env, opposite behaviour depending on sourcing order.
#   2. "Call a helper in the fallback." REFUTED TWICE: in ARGUMENT position a failed command
#      substitution yields an EMPTY string and `set -e` does NOT fire, reproducing bug 1 byte for
#      byte; and it is dead code anyway, because .env.example always sets these vars so the
#      fallback never fires.
#
# WHY THIS FILE CONTAINS NO MATCHABLE REFERENCE:
#   An earlier draft embedded a real-looking fallback in its own prose. Measured consequences: the
#   gate was RED on a clean tree, AND its docstring VOTED on a value — deleting the one real CI use
#   site still passed, because the comment stood in for the deleted code. A gate that is a script in
#   the tree it scans cannot use the matchable form. So every example here is written with angle
#   brackets, which the key/fallback regexes cannot match, AND the scan excludes this file by name,
#   AND a self-test below asserts this file contributes ZERO sites. Three layers, because the first
#   two are silent when they fail.
#
# shellcheck shell=bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1
# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"

SELF="$(basename "${BASH_SOURCE[0]}")"
ENV_FILE="${REPO_ROOT}/.env.example"
[ -f "$ENV_FILE" ] || die "check-psa-defaults: ${ENV_FILE} is missing — the documented side of the comparison does not exist."

VALID_LEVELS='restricted|baseline|privileged|none'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
bad=0

# --- SIDE A: every PSA_LEVEL reference in scripts/, matched PERMISSIVELY then VALIDATED ----------
# The key charclass includes DIGITS on purpose: an earlier draft used [A-Z_]+ and a key with a digit
# was invisible to it — which reproduces the exact "a new key is invisible" class this gate exists to
# close. Matching permissively and then rejecting what we do not recognise turns invisible into
# flagged, which is the only direction that is safe.
# RECORD DELIMITER IS \x1f (US), NOT TAB, AND THAT IS LOAD-BEARING. A hint-only read has an EMPTY
# fallback field, and TAB is IFS-*whitespace*, so bash `read` COLLAPSES consecutive tabs and the
# empty field silently vanishes — shifting the location into the fallback variable. Measured: with
# TAB, `APP<tab><tab>loc:41` reads as fb="loc:41"; with \x1f it correctly reads fb="". That mis-read
# made all 8 hint-only reads look like invalid levels named "scripts/49-psa-check.sh:41". A
# non-whitespace delimiter is the only form that preserves an empty field here.
grep -rnoE '\$\{PSA_LEVEL_[A-Za-z0-9_]+:-[^}]*\}' scripts/ --exclude="$SELF" 2>/dev/null \
  | sed -E 's|^([^:]+):([0-9]+):\$\{PSA_LEVEL_([A-Za-z0-9_]+):-([^}]*)\}|\3\x1f\4\x1f\1:\2|' \
  | sort > "$TMP/raw" || true

: > "$TMP/sites"; : > "$TMP/empty"
while IFS=$'\x1f' read -r k fb loc; do
  [ -n "${k:-}" ] || continue
  if [ -z "$fb" ]; then
    # The hint-only read in 49-psa-check.sh, where empty is the correct "operator did not configure
    # this" signal. Deliberately not a claim about the default.
    printf '%s\t%s\n' "$k" "$loc" >> "$TMP/empty"
  elif printf '%s' "$fb" | grep -qE "^(${VALID_LEVELS})$"; then
    printf '%s\t%s\t%s\n' "$k" "$fb" "$loc" >> "$TMP/sites"
  else
    log_error "PSA_LEVEL_${k}: fallback '${fb}' at ${loc} is not one of ${VALID_LEVELS//|/, }."
    echo "      psa_label_namespace() dies on an unrecognised level AT RUNTIME, case-sensitively —"
    echo "      so this reaches an operator as a failed install, not as a gate failure. Fix it here."
    bad=$((bad + 1))
  fi
done < "$TMP/raw"

sites=$(grep -c . "$TMP/sites" || true)
[ "${sites:-0}" -gt 0 ] || die "check-psa-defaults: found ZERO PSA_LEVEL fallbacks naming a real level in scripts/.
  Either every fallback was removed (then this gate is obsolete — delete it deliberately) or the
  extraction regex has rotted. A gate that scanned nothing is BROKEN, not green."

# --- RECONCILIATION: no reference may hide from this gate ----------------------------------------
# The structural backstop. Every PSA_LEVEL *variable reference* in scripts/ must be accounted for as
# either a validated site or a deliberately-excluded empty-fallback read. Anything else — an
# assign-if-unset (the REFUTED design creeping back), a bare reference, a nested expansion — is RED,
# because a form this gate cannot parse is a form it cannot check, and silence is indistinguishable
# from agreement.
all_refs=$(grep -rhoE '\$\{PSA_LEVEL_[A-Za-z0-9_]+[^}]*\}' scripts/ --exclude="$SELF" 2>/dev/null | grep -c . || true)
empty_refs=$(grep -c . "$TMP/empty" || true)
invalid=$bad
accounted=$(( sites + empty_refs + invalid ))
if [ "${all_refs:-0}" -ne "$accounted" ]; then
  log_error "check-psa-defaults: ${all_refs} PSA_LEVEL reference(s) in scripts/, but only ${accounted} accounted for (${sites} validated + ${empty_refs} empty-fallback + ${invalid} invalid)."
  echo "      The unaccounted forms are below. A reference this gate cannot parse is one it cannot"
  echo "      check — and an assign-if-unset here is the REFUTED design returning (see header)."
  grep -rnoE '\$\{PSA_LEVEL_[A-Za-z0-9_]+[^}]*\}' scripts/ --exclude="$SELF" 2>/dev/null \
    | grep -vE ':-[a-z]*\}' | sed 's/^/        /'
  bad=$((bad + 1))
fi

# --- SELF-TEST: this file must contribute nothing ------------------------------------------------
# Layer three. If a future edit puts a matchable form back into this file's prose, the --exclude
# above hides it from the scan but NOT from a reader who then trusts the docstring. Assert it.
self_hits=$(grep -coE '\$\{PSA_LEVEL_[A-Za-z0-9_]+:-[^}]*\}' "${REPO_ROOT}/scripts/${SELF}" || true)
if [ "${self_hits:-0}" -ne 0 ]; then
  log_error "check-psa-defaults: this gate's OWN source contains ${self_hits} matchable PSA_LEVEL fallback(s)."
  echo "      A gate in the tree it scans must not contain the form it looks for: its prose then"
  echo "      substitutes for production code (a deleted use site still 'passes') and accuses itself"
  echo "      when a real default changes. Write examples with angle brackets instead."
  bad=$((bad + 1))
fi

# --- SIDE A internal consistency: one key must not claim two different defaults -------------------
awk -F'\t' '{print $1"\t"$2}' "$TMP/sites" | sort -u | cut -f1 | uniq -d > "$TMP/conflicts" || true
if [ -s "$TMP/conflicts" ]; then
  while read -r k; do
    log_error "PSA_LEVEL_${k}: use sites DISAGREE about the default:"
    awk -F'\t' -v k="$k" '$1==k {print "      " $2 "  at " $3}' "$TMP/sites"
  done < "$TMP/conflicts"
  bad=$((bad + 1))
fi
awk -F'\t' '{print $1"\t"$2}' "$TMP/sites" | sort -u > "$TMP/a"

# --- SIDE B: what .env.example documents ---------------------------------------------------------
# Anchored on `=` so a prose MENTION of a var name is not read as a declaration. TAB-delimited so an
# EMPTY value cannot collapse into the next field — an earlier draft used spaces and awk then read
# the LINE NUMBER as the value, reporting that .env.example documented a line number as a level.
grep -nE '^#?[[:space:]]*PSA_LEVEL_[A-Za-z0-9_]+=' "$ENV_FILE" 2>/dev/null \
  | sed -E 's|^([0-9]+):#?[[:space:]]*PSA_LEVEL_([A-Za-z0-9_]+)=([^[:space:]#]*).*|\2\t\3\t\1|' \
  > "$TMP/env_ordered" || true

# DUPLICATES: load_env sources this file with `set -a`, so the LAST declaration wins. Comparing
# against any other one certifies a value that will not run.
cut -f1 "$TMP/env_ordered" | sort | uniq -d > "$TMP/env_dupes" || true
if [ -s "$TMP/env_dupes" ]; then
  while read -r k; do
    log_error "PSA_LEVEL_${k}: declared MORE THAN ONCE in .env.example — load_env sources it with 'set -a', so the LAST one wins:"
    awk -F'\t' -v k="$k" '$1==k {print "      line " $3 ": " ($2=="" ? "<empty>" : $2)}' "$TMP/env_ordered"
  done < "$TMP/env_dupes"
  bad=$((bad + 1))
fi

# Effective value = LAST in file order, matching `set -a` sourcing.
awk -F'\t' '{v[$1]=$2; l[$1]=$3} END{for (k in v) print k"\t"v[k]"\t"l[k]}' "$TMP/env_ordered" | sort > "$TMP/env"
cut -f1,2 "$TMP/env" | sort -u > "$TMP/b"
documented=$(grep -c . "$TMP/b" || true)
[ "${documented:-0}" -gt 0 ] || die "check-psa-defaults: .env.example documents ZERO PSA_LEVEL_* keys.
  Either they were removed (then remove the fallbacks too) or the extraction regex has rotted."

# --- key-set drift, BOTH directions ---------------------------------------------------------------
# The durable win: check-env-coverage.sh wildcard-exempts PSA_LEVEL_*, so a NEW key added to a script
# is invisible to it. That is how a key came to be used by a script while lib/psa.sh listed only six.
while IFS=$'\t' read -r k _; do
  cut -f1 "$TMP/b" | grep -qxF "$k" || { log_error "PSA_LEVEL_${k}: used in scripts/ but NOT documented in .env.example — an operator cannot discover or override it."; bad=$((bad + 1)); }
done < "$TMP/a"

while IFS=$'\t' read -r k _; do
  cut -f1 "$TMP/a" | grep -qxF "$k" || { log_error "PSA_LEVEL_${k}: documented in .env.example but no script falls back to it — dead config, or a use site was deleted and the doc left behind."; bad=$((bad + 1)); }
done < "$TMP/b"

# --- value drift, per key --------------------------------------------------------------------------
checked=0
while IFS=$'\t' read -r k lit; do
  rec=$(awk -F'\t' -v k="$k" '$1==k {print; exit}' "$TMP/env")
  [ -n "$rec" ] || continue                       # key-in-A-not-B: already reported above
  envval=$(printf '%s' "$rec" | cut -f2)
  envline=$(printf '%s' "$rec" | cut -f3)
  if [ -z "$envval" ]; then
    log_error "PSA_LEVEL_${k}: declared at .env.example:${envline} with an EMPTY value, but scripts/ fall back to '${lit}'."
    echo "      An empty documented value reads as 'unset' to an operator while the code still has a"
    echo "      real default — the drift is invisible in exactly the direction that matters."
    bad=$((bad + 1)); continue
  fi
  checked=$((checked + 1))
  if [ "$envval" != "$lit" ]; then
    log_error "PSA_LEVEL_${k}: scripts/ fall back to '${lit}' but .env.example:${envline} documents '${envval}'."
    awk -F'\t' -v k="$k" '$1==k {print "      fallback " $2 "  at " $3}' "$TMP/sites"
    bad=$((bad + 1))
  fi
done < "$TMP/a"

[ "$checked" -gt 0 ] || die "check-psa-defaults: compared 0 key(s) — every key failed to yield a value on one side. A green here would mean nothing."

if [ "$bad" -ne 0 ]; then
  log_error "check-psa-defaults: ${bad} finding(s)."
  echo "  The use-site fallback is what RUNS when the var is unset; .env.example is what the operator"
  echo "  READS. When they drift, the operator configures against a number that never applies."
  echo "  Fix whichever is wrong — do not delete the gate."
  exit 1
fi

log_info "check-psa-defaults: OK — ${checked} PSA level(s) agree between ${sites} validated use site(s) and .env.example (${documented} documented, ${empty_refs} hint-only read(s), ${all_refs} reference(s) all accounted for)."
