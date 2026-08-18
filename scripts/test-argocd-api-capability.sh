#!/usr/bin/env bash
# argocd_api_capability — the B179 graded ladder (create GATES; get/update only WARN).
#
# WHY THIS SUITE EXISTS, and why the row's own RED-proof could not have been written before the
# extraction. B179 prescribed *"a `get`-only role must NOT select api"* as its proof. That is
# ALREADY TRUE and always was — `create=no` takes the `no)` arm and `get` is never probed — so it
# passes identically before and after the change: ZERO discrimination. The discriminating set is the
# five cases below, and they were not expressible while the decision lived INLINE at
# 70-configure-argocd.sh:280-330. Extracting it into a FUNCTION is what makes them testable, which
# is the whole reason the extraction is part of the fix rather than tidying.
#
# THE LOAD-BEARING ASSERTION is case 2 and case 3: with `get` or `update` denied, the returned
# verdict must STILL be `yes`. A downgrade there would make MECH=request reachable from a DERIVED
# denial, and `request` renders files and EXITS 0 HAVING APPLIED NOTHING. It is also frequently a
# FALSE alarm — the probe asks `proj/*`, so a name-scoped grant (`applications, get, proj/oneapp`)
# answers no while the tenant can read the very Application about to be written.
#
# THE WITNESS (cases 4 and 5) pins the converse: on create=no / create=unknown the extra verbs are
# NEVER probed. Without it, an implementation that always probed all three would pass every
# verdict assertion while adding two unanswerable RPCs to a run that is already dead.
#
# HERMETIC: a PATH stub for `argocd`, no server, no cluster, no network.
set -u
cd "$(dirname "$0")/.." || exit 1
# shellcheck disable=SC1091
. scripts/lib/os.sh    2>/dev/null || { echo "cannot source os.sh"; exit 1; }
# shellcheck disable=SC1091
. scripts/lib/argocd.sh 2>/dev/null || { echo "cannot source argocd.sh"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; export PATH="$T/bin:$PATH"

# The stub answers per VERB from $T/ans.<verb>, and WITNESSES every call to $T/calls.
cat > "$T/bin/argocd" <<'STUB'
#!/usr/bin/env bash
# argv: account can-i <verb> <resource> <scope>
verb="$3"
printf '%s\n' "$verb" >> "${T_WITNESS}"
a="${T_ANSDIR}/ans.${verb}"
if [ -f "$a" ]; then
  v="$(cat "$a")"
  case "$v" in
    RPCFAIL) printf 'rpc error: code = Unauthenticated desc = invalid session token: token is expired\n' >&2; exit 1 ;;
    *) printf '%s\n' "$v"; exit 0 ;;
  esac
fi
printf 'yes\n'; exit 0
STUB
chmod +x "$T/bin/argocd"
export T_WITNESS="$T/calls" T_ANSDIR="$T"

# scenario <create> <get> <update> -> sets the stub up and runs one capability probe.
# stdout of the function is the verdict; stderr (the warnings) is captured separately.
scenario() {
  : > "$T/calls"
  printf '%s' "$1" > "$T/ans.create"
  printf '%s' "$2" > "$T/ans.get"
  printf '%s' "$3" > "$T/ans.update"
  VERDICT="$(argocd_api_capability myproj 2>"$T/warn")"
  WARN="$(cat "$T/warn")"
  CALLS="$(tr '\n' ' ' < "$T/calls")"
}

echo "== 1. fully granted: api selected, and NOT one word of warning =="
scenario yes yes yes
if [ "${VERDICT%%|*}" = yes ]; then ok "verdict yes"; else bad "verdict '${VERDICT}' (want yes)"; fi
if [ -z "$WARN" ]; then ok "no warnings on a clean token"; else bad "warned on a fully-granted token: $WARN"; fi
case "$CALLS" in *create*get*update*) ok "probed all three verbs (create get update)" ;;
                 *) bad "verb order/coverage wrong: '$CALLS'" ;; esac

echo "== 2. create WITHOUT get — the B179 case. MUST stay api, MUST warn =="
scenario yes no yes
if [ "${VERDICT%%|*}" = yes ]; then ok "STILL yes — no downgrade from a derived denial"; else bad "verdict '${VERDICT}' — a get denial DOWNGRADED the mechanism (request would exit 0 having applied nothing)"; fi
case "$WARN" in *"not GET them"*) ok "the warning names the missing verb" ;; *) bad "warning does not name GET: $WARN" ;; esac
case "$WARN" in *"argocd app get"*) ok "...and names the late failure site" ;; *) bad "warning does not name the readback" ;; esac
case "$WARN" in *"FALSE ALARM"*)   ok "...and discloses the name-scoping false alarm" ;; *) bad "warning hides the false-alarm case" ;; esac

echo "== 3. create WITHOUT update — the verb the row's 2-verb probe MISSED =="
scenario yes yes no
if [ "${VERDICT%%|*}" = yes ]; then ok "STILL yes — no downgrade"; else bad "verdict '${VERDICT}' — an update denial downgraded"; fi
case "$WARN" in *"not UPDATE them"*) ok "the warning names UPDATE" ;; *) bad "warning does not name UPDATE: $WARN" ;; esac
case "$WARN" in *"--upsert"*) ok "...and names the upsert that needs it" ;; *) bad "warning does not name the upsert" ;; esac
case "$WARN" in *"MISDIAGNOSES"*) ok "...and says the live message misdiagnoses it" ;; *) bad "warning omits the misdiagnosis" ;; esac

echo "== 4. create DENIED: verdict no, and the extra verbs are NEVER probed =="
scenario no yes yes
if [ "${VERDICT%%|*}" = no ]; then ok "verdict no"; else bad "verdict '${VERDICT}' (want no)"; fi
case "$CALLS" in *get*|*update*) bad "probed get/update after a create denial: '$CALLS'" ;;
                 *) ok "only create was probed ('$CALLS')" ;; esac
if [ -z "$WARN" ]; then ok "no ladder warnings on a decided denial"; else bad "warned anyway: $WARN"; fi
echo "== 5. create UNANSWERED: verdict unknown, and the extra verbs are NEVER probed =="
scenario RPCFAIL yes yes
if [ "${VERDICT%%|*}" = unknown ]; then ok "verdict unknown"; else bad "verdict '${VERDICT}' (want unknown)"; fi
case "$CALLS" in *get*|*update*) bad "probed get/update when the server never answered: '$CALLS'" ;;
                 *) ok "only create was probed ('$CALLS')" ;; esac

echo "== 6. the shape is preserved for every existing caller =="
scenario yes yes yes
case "$VERDICT" in *"|"*) ok "still the argocd_can_i 'verdict|class' shape" ;; *) bad "shape changed: '$VERDICT'" ;; esac

printf '\n  %s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
