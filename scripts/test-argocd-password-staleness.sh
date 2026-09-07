#!/usr/bin/env bash
# RED-proof for argocd-password.sh's CURRENT/STALE/UNKNOWN discriminator.
#
# WHY IT EXISTS. `make creds` printed one unconditional hedge — "it stops working once someone
# changes it" — which told the reader nothing they could act on and, worse, was wrong about the
# consequence: NOTHING deletes argocd-initial-admin-secret (measured 2026-09-07: still present 20h
# after install, zero annotations/labels/ownerRefs, so argocd-server created it at runtime and the
# kapp-managed operator neither deletes nor recreates it). So the report does not go quiet when the
# password changes — it keeps serving a DEAD password with full confidence, forever.
#
# ⚠️ THE STALE BRANCH CANNOT BE PROVEN ON THE REAL LAB without changing the admin password, which
# would break a shared instance. So the discriminator is proven here against a STUBBED kubectl with
# controlled timestamps. What that does NOT prove is the ordering premise itself — that ArgoCD
# writes admin.passwordMtime AFTER the initial secret's creationTimestamp on a change. That is
# `inferred` from upstream's write order; measured only in the EQUAL (unchanged) case, where both
# read 2026-09-06T07:45:25Z on cicd-gc3. A rotation inside the same second as bootstrap would be
# read as CURRENT — harmless, and named rather than hidden.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; : > "$T/kc"

# A kubectl stub. $MT / $CT drive what the two reads return; EMPTY means "absent / refused", which
# is the case that MUST degrade to UNKNOWN rather than to a confident CURRENT.
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  argocd-secret)               printf '%s' "${STUB_MT_B64:-}"; exit 0 ;;
  argocd-initial-admin-secret) printf '%s' "${STUB_CT:-}";     exit 0 ;;
esac; done
exit 0
STUB
chmod +x "$T/bin/kubectl"
cat > "$T/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift; exec "$@"
STUB
chmod +x "$T/bin/timeout"

# Source ONLY the function under test, so this needs no cluster and no argument parsing.
# shellcheck disable=SC1090
eval "$(sed -n '/^_password_state() {/,/^}/p' "${SCRIPT_DIR}/argocd-password.sh")"
ARGOCD_NAMESPACE=cicd

check() { # <label> <mtime|""> <ctime|""> <want-state>
  local label="$1" mt="$2" ct="$3" want="$4" got
  got="$(PATH="$T/bin:$PATH" \
         STUB_MT_B64="$( [ -n "$mt" ] && printf '%s' "$mt" | base64 -w0 || true )" \
         STUB_CT="$ct" _password_state "$T/kc")"
  got="${got%%$'\t'*}"
  if [ "$got" = "$want" ]; then printf '  ok   %-52s -> %s\n' "$label" "$got"; pass=$((pass+1))
  else printf '  FAIL %-52s -> %s (want %s)\n' "$label" "$got" "$want"; fail=$((fail+1)); fi
}

echo "== argocd-password.sh _password_state — RED-proof =="
check "unchanged: mtime == creationTimestamp (the LAB case)" \
      "2026-09-06T07:45:25Z" "2026-09-06T07:45:25Z" CURRENT
check "CHANGED: mtime AFTER creationTimestamp"              \
      "2026-09-07T11:00:00Z" "2026-09-06T07:45:25Z" STALE
check "changed by ONE SECOND (the boundary)"                \
      "2026-09-06T07:45:26Z" "2026-09-06T07:45:25Z" STALE
check "mtime BEFORE creation (clock skew) -> not STALE"     \
      "2026-09-06T07:00:00Z" "2026-09-06T07:45:25Z" CURRENT
check "argocd-secret unreadable (RBAC/absent) -> UNKNOWN"   \
      "" "2026-09-06T07:45:25Z" UNKNOWN
check "initial secret unreadable -> UNKNOWN"                \
      "2026-09-06T07:45:25Z" "" UNKNOWN
check "both unreadable -> UNKNOWN, never CURRENT"           \
      "" "" UNKNOWN
# Cross-year, because the comparison is LEXICAL and only works because both are RFC3339 UTC.
check "cross-year lexical order holds"                      \
      "2027-01-01T00:00:00Z" "2026-12-31T23:59:59Z" STALE

echo
if [ "$fail" -ne 0 ]; then echo "argocd-password staleness: ${fail} FAILED, ${pass} passed"; exit 1; fi
echo "argocd-password staleness: ALL ${pass} passed"
