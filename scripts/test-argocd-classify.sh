#!/usr/bin/env bash
# test-argocd-classify.sh — argocd's failure VOCABULARY, and that both write sites actually use it.
#
# WHY THIS EXISTS. An implementation-round adversary drove the real `70-configure-argocd.sh` on
# 2026-08-17 and measured that the two argocd write sites called `classify_kube_failure` RAW:
#
#   argocd stderr shape                              classifier   message the operator got
#   x509 name mismatch (the B137 case)               STALE_CA     transport            OK
#   dial tcp ...: connect: connection refused        UNREACHABLE  "Does your AppProject permit..."
#   rpc error: Unauthenticated ... token is expired  UNKNOWN      "Does your AppProject permit..."
#                                                                 / "repo-server cannot reach Gitea"
#
# Two of three transport/credential shapes were reported as a PERMISSIONS question, and one of them
# as a claim about a DIFFERENT COMPONENT. The repo already owned the fix — a refinement buried inside
# `argocd_can_i`, reachable by one caller. It is now `classify_argocd_failure`, and this pins it.
#
# ⚠️ WHAT THIS DOES NOT PROVE, stated rather than implied: it does NOT drive `70-configure-argocd.sh`
# end to end, so it does not prove the rendered `die` TEXT for each class. It proves (a) the
# vocabulary maps each shape to the right class, and (b) both sites are WIRED to that vocabulary and
# to ONE shared arm list. Driving the script needs the stub harness in `test-argocd-preflight-ns.sh`;
# that is a further test, not this one.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

pass=0; fail=0
t() {  # t <expected-class> <stderr-text>
  local f got; f="$(mktemp)"; printf '%s' "$2" > "$f"
  got="$(classify_argocd_failure "$f")"; rm -f "$f"
  if [ "$got" = "$1" ]; then echo "  PASS  ${1}"; pass=$((pass+1))
  else echo "  FAIL  want ${1}, got ${got}"; echo "        input: ${2:0:110}"; fail=$((fail+1)); fi
}
ck() {  # ck <label> <predicate-command...>   — the helper RUNS the predicate, so there is no
        # `$?`-after-a-condition anywhere (SC2319), and the rc cannot be clobbered by an expansion
        # in the label. Same discipline as the repo's "read the gate's rc on its own line" rule.
  local label="$1"; shift
  if "$@"; then echo "  PASS  ${label}"; pass=$((pass+1))
  else echo "  FAIL  ${label}"; fail=$((fail+1)); fi
}

echo "classify_argocd_failure — argocd's OWN vocabulary, not kubectl's"

# The four shapes from the adversary's measured table. Every string below is a real argocd v3.0.19
# emission (or the repo's own recorded capture), not a paraphrase.
t STALE_CA     '{"level":"fatal","msg":"Failed to establish connection to 192.168.101.131:443: error creating connection: tls: failed to verify certificate: x509: cannot validate certificate for 192.168.101.131 because it doesn'"'"'t contain any IP SANs","time":"2026-08-17T07:17:43Z"}'
t UNREACHABLE  '{"level":"fatal","msg":"Failed to establish connection to argocd.env1.lab.test:443: dial tcp 10.0.0.5:443: connect: connection refused","time":"2026-08-17T07:17:43Z"}'
t UNAUTHORIZED '{"level":"fatal","msg":"rpc error: code = Unauthenticated desc = invalid session token: token is expired","time":"2026-08-17T07:17:43Z"}'

# ⚠️ A GENUINE RBAC DENIAL MUST *NOT* BE CLAIMED AS TRANSPORT. This is the discrimination the whole
# change rests on: if PermissionDenied classified as UNREACHABLE/UNAUTHORIZED, the new shared die
# would tell a correctly-refused tenant that the server was never reached — inverting the defect.
# It must fall through to the caller's own AppProject message, i.e. NOT be a transport class.
# ⚠️ The app name here is deliberately GENERIC. The classifier does not read it, and naming a real
# app in a shared file is what `check-app-hardcodes` forbids — it caught this fixture on first run.
_pd='{"level":"fatal","msg":"rpc error: code = PermissionDenied desc = permission denied: applications, create, default/some-app","time":"2026-08-17T07:17:43Z"}'
_f="$(mktemp)"; printf '%s' "$_pd" > "$_f"; _cls="$(classify_argocd_failure "$_f")"; rm -f "$_f"
case "$_cls" in
  STALE_CA|UNREACHABLE|UNAUTHORIZED) echo "  FAIL  a genuine PermissionDenied must NOT be a transport class (got ${_cls})"; fail=$((fail+1)) ;;
  *) echo "  PASS  a genuine PermissionDenied is NOT a transport class (${_cls}) — falls to the AppProject message"; pass=$((pass+1)) ;;
esac

# k_can_i is a KUBECTL probe one function away, and the two call sites look identical. Keying on the
# CODE FORM, not the function name, because the name appears in comments too.
echo
echo "wiring — the sites are actually connected to that vocabulary"
LIB="${SCRIPT_DIR}/lib/os.sh"; CFG="${SCRIPT_DIR}/70-configure-argocd.sh"
_body() { sed -n "/^$1() {/,/^}/p" "$2"; }

# Counts first, assertions second — so the predicate is a plain `test` the helper can run.
# shellcheck disable=SC2016  # the `$_err` is MEANT to be literal: we are matching the SOURCE TEXT
# of the call site, not expanding a variable. Double quotes here would search for the value.
n_kk="$(_body k_can_i     "$LIB" | grep -c 'classify_kube_failure "\$_err"'   || true)"
# shellcheck disable=SC2016  # same: the `$_err` is the SOURCE TEXT being matched, not a variable.
n_ak="$(_body argocd_can_i "$LIB" | grep -c 'classify_argocd_failure "\$_err"' || true)"
ck "k_can_i still uses the KUBECTL classifier (it is a kubectl probe)" test "$n_kk" -ge 1
ck "argocd_can_i uses the argocd classifier"                          test "$n_ak" -ge 1

# No RAW kubectl classifier may remain in the argocd write path.
n_raw="$(sed 's/#.*//' "$CFG" | grep -c 'classify_kube_failure' || true)"
ck "70-configure-argocd.sh calls NO raw classify_kube_failure (found ${n_raw})" test "$n_raw" -eq 0

# ONE arm list. The two sites shipped with DIFFERENT lists in the same commit; that divergence is
# what let a connection-refused reach the AppProject message at one site and not the other.
# B197(3): this asserted a FLOOR (-ge 2) over THREE sites, so it was GREEN while the third
# (argocd repo add) died RAW, and would have stayed green if a fourth landed raw. Two assertions
# now. The count is EQUALITY and is enumerated on purpose - a new argocd failure site must be
# reviewed, not silently absorbed. The raw-die check below is the non-rotting half: it fires on a
# new unclassified site whatever the count.
n_die="$(sed 's/#.*//' "$CFG" | grep -c 'argocd_transport_die ' || true)"
ck "every argocd write site routes through argocd_transport_die (${n_die} calls, expected 3)" test "$n_die" -eq 3
n_rawdie="$(sed 's/#.*//' "$CFG" | grep -cE '\|\| *die "argocd' || true)"
ck "no argocd invocation dies WITHOUT classification (${n_rawdie} raw)" test "$n_rawdie" -eq 0
n_arm="$(sed -n '/^argocd_transport_die() {/,/^}/p' "$CFG" | grep -c 'STALE_CA|UNREACHABLE' || true)"
ck "the transport arm list exists in exactly ONE place" test "$n_arm" -eq 1

# The guard must precede the first side-effecting write. Row 5 created a namespace, applied PSA
# labels and minted an image-pull secret BEFORE dying with a guessed cause.
g="$(grep -n 'ARGOCD_MECHANISM=api, but the argocd API probe DID NOT ANSWER' "$CFG" | head -1 | cut -d: -f1)"
w="$(grep -n 'apply_application() {' "$CFG" | head -1 | cut -d: -f1)"
ck "the MECH=api/unknown guard (line ${g:-?}) precedes the first write (line ${w:-?})" \
   test "${g:-0}" -lt "${w:-0}"

echo
if [ "$fail" -eq 0 ]; then echo "test-argocd-classify: ${pass} passed, 0 failed"; exit 0; fi
echo "test-argocd-classify: ${pass} passed, ${fail} FAILED"; exit 1
