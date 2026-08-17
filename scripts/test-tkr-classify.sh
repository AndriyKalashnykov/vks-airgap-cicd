#!/usr/bin/env bash
# ci-tier: slow — asserts the wait loop runs its full budget, `[ "$el" -ge 15 ]` (~30s)
# test-tkr-classify.sh — 24-vks-k8s-version.sh must not spend 900s to reach a wrong conclusion (B110).
#
# WHAT IT USED TO DO. `_newest_ready` was one pipeline ending in `tail -1`, so kubectl's rc was lost,
# and `2>/dev/null` threw the reason away. Any transport failure therefore looked like "no releases
# are Ready yet": the script entered its wait loop, burned up to VKS_TKR_WAIT_SECONDS (default 900),
# and then declared
#     Every release is published but unusable, which is a Supervisor/content-library problem
# — a confident platform diagnosis derived from a connection that never succeeded. Waiting cannot fix
# a stale CA or a missing grant.
#
# ASSERT ELAPSED, NOT ONLY rc. The old path also exits non-zero at its timeout, so rc alone cannot
# tell "refused up front" from "burned the budget" — which is the entire point.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$TMP/sup.kubeconfig"

cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args=("$@"); i=0; sub=""
# THE RESOURCE IS PART OF THE ANSWER. This used to switch on STUB_MODE alone, so every mode applied
# to BOTH reads and the osimages arm was unreachable by construction: STUB_MODE=forbidden failed the
# kubernetesreleases read first and died at the TKr arm. The resource sits immediately after `get` in
# both call shapes (the osimages read carries --request-timeout=, the wait-loop read does not).
res=""
while [ $i -lt ${#args[@]} ]; do case "${args[$i]}" in
  --kubeconfig) i=$((i+2));; --request-timeout=*) i=$((i+1));; --request-timeout) i=$((i+2));;
  *) sub="${args[$i]}"; res="${args[$((i+1))]:-}"; break;; esac; done
case "$sub" in
  version) echo "Client Version: v1.34.0"; exit 0 ;;
  get) case "${STUB_MODE:-ok}" in
         stale_ca)  echo 'Unable to connect to the server: tls: failed to verify certificate: x509: certificate signed by unknown authority' >&2; exit 1 ;;
         forbidden) echo 'Error from server (Forbidden): kubernetesreleases is forbidden: User "u" cannot list resource "kubernetesreleases"' >&2; exit 1 ;;
         none)      exit 0 ;;                                  # reachable, genuinely nothing Ready
         # osi_* : the TKr read SUCCEEDS and only the osimages read fails — the divergence the old
         # stub could not express, and the only one that is structurally persistent (RBAC is
         # per-resource, and osimages is a different API group from kubernetesreleases).
         osi_forbidden)
           case "$res" in
             osimages) echo 'Error from server (Forbidden): osimages.vmoperator.vmware.com is forbidden: User "u" cannot list resource "osimages"' >&2; exit 1 ;;
             *)        echo "x v1.35.5+vmware.1 True True"; exit 0 ;;
           esac ;;
         osi_nocrd)   # an ABSENT CRD classifies UNKNOWN, which the TKr arm's *) would DIE on
           case "$res" in
             osimages) echo 'error: the server doesn'"'"'t have a resource type "osimages"' >&2; exit 1 ;;
             *)        echo "x v1.35.5+vmware.1 True True"; exit 0 ;;
           esac ;;
         osi_empty)   # READ FINE, genuinely nothing — must stay a quiet wait, NOT a warning
           case "$res" in
             osimages) exit 0 ;;
             *)        echo "x v1.35.5+vmware.1 True True"; exit 0 ;;
           esac ;;
         # The happy path. It had NEVER been exercised: the old `*)` emitted the SAME TKr row for
         # both reads, so the osimages join saw a version where it needed an OS name, have[] stayed
         # empty, and every "ok" run silently fell into the wait loop.
         *) case "$res" in
              osimages) echo "v1.35.5+vmware.1 photon"; exit 0 ;;
              *)        echo "x v1.35.5+vmware.1 True True"; exit 0 ;;
            esac ;;
       esac ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/kubectl"

# A SANDBOX REPO_ROOT, because a degrade path reaches `set_env_var VKS_K8S_VERSION ... .env`. Every
# pre-existing mode fails or waits-then-exits, so that line had never executed under test; the new
# osi_* modes DO emit a version and land on it. Without this the suite writes the operator's real .env.
mkdir -p "$TMP/repo"
[ -f "$SCRIPT_DIR/../.env.example" ] && cp "$SCRIPT_DIR/../.env.example" "$TMP/repo/"
run() {   # run <STUB_MODE> <wait_seconds> -> "<rc> <elapsed>"
  local t0=$SECONDS rc
  ( cd "$SCRIPT_DIR/.." && env PATH="$TMP/bin:$PATH" STUB_MODE="$1" SKIP_DOTENV=1 \
      REPO_ROOT="$TMP/repo" \
      VKS_SUPERVISOR_KUBECONFIG="$TMP/sup.kubeconfig" VKS_TKR_WAIT_SECONDS="$2" \
      bash scripts/24-vks-k8s-version.sh ) >"$TMP/out" 2>&1
  rc=$?; printf '%s %s' "$rc" "$((SECONDS - t0))"
}
saw() { grep -qi -- "$1" "$TMP/out"; }

# --- a transport failure must refuse UP FRONT, not after the budget -----------------------------
read -r rc el <<<"$(run stale_ca 30)"
if [ "$rc" -ne 0 ]; then ok "STALE_CA refuses (rc=$rc)"; else bad "STALE_CA refuses" "rc=0"; fi
if [ "$el" -lt 5 ]; then ok "STALE_CA refuses UP FRONT (${el}s, budget was 30s)"
else bad "STALE_CA refuses UP FRONT" "took ${el}s — it burned the wait budget"; fi
if saw 'content-library'; then bad "STALE_CA must NOT blame the content library" "it did"; else ok "STALE_CA does NOT blame the content library"; fi
if saw 'mints a new CA'; then ok "STALE_CA names the rebuilt-CA cause"; else bad "STALE_CA names the rebuilt-CA cause" "$(tail -2 "$TMP/out")"; fi

read -r rc el <<<"$(run forbidden 30)"
if saw 'RBAC GRANT'; then ok "FORBIDDEN names the grant"; else bad "FORBIDDEN names the grant" "$(tail -2 "$TMP/out")"; fi
if [ "$el" -lt 5 ]; then ok "FORBIDDEN refuses UP FRONT (${el}s)"; else bad "FORBIDDEN refuses UP FRONT" "took ${el}s"; fi

# --- a REACHABLE Supervisor with nothing Ready must still WAIT, and keep its own message ---------
read -r rc el <<<"$(run none 16)"
if [ "$el" -ge 15 ]; then ok "reachable-but-empty still WAITS (${el}s >= 16s budget)"
else bad "reachable-but-empty still WAITS" "returned after ${el}s — a provisioning Supervisor was refused"; fi
if saw 'content-library'; then ok "...and keeps the content-library message, which is correct THERE"
else bad "...and keeps the content-library message" "the true-negative message was lost"; fi

echo
# --------------------------------------------------------------------------------------------------
# THE OSIMAGE ARM. Until the stub became resource-aware these were unreachable: every mode applied to
# BOTH reads, so nothing could make osimages fail while kubernetesreleases succeeded — which is the
# ONLY divergence that is structurally persistent (RBAC is per-resource, and osimages lives in a
# different API group). The old silence turned a FORBIDDEN into a 900s wait and then a die naming two
# hypotheses that exclude the true one.
#
# ⚠️ rc ALONE CANNOT distinguish "refused up front" from "burned the budget" — both are non-zero in
# the old behaviour. The ELAPSED assertion is the discriminator, exactly as the FORBIDDEN case above.
_env_before=""
[ -f "$SCRIPT_DIR/../.env" ] && _env_before="$(cksum < "$SCRIPT_DIR/../.env")"

set -- "$(run osi_forbidden 600)"; rc="${1%% *}"; el="${1##* }"
if [ "$rc" = 0 ]; then ok "osimages FORBIDDEN: still resolves a version (rc=0) — degrade, never die"
else bad "osimages FORBIDDEN died (rc=$rc)" "an unreadable cross-check must not refuse a readable TKr list"; fi
if [ "$el" -lt 5 ]; then ok "osimages FORBIDDEN: answers in ${el}s, not after the 600s budget"
else bad "osimages FORBIDDEN burned ${el}s" "it waited — the misdiagnosis this fix removes"; fi
if saw 'FORBIDDEN'; then ok "osimages FORBIDDEN: the class is NAMED in the output"
else bad "osimages FORBIDDEN: class not named" "the operator cannot tell RBAC from 'no image exists'"; fi
if saw 'cross-check is SKIPPED'; then ok "osimages FORBIDDEN: says the cross-check was SKIPPED (not silently trusted)"
else bad "no SKIPPED disclosure" "a quiet fallback re-opens the bug the OSImage join was added to fix"; fi

set -- "$(run osi_nocrd 600)"; rc="${1%% *}"; el="${1##* }"
if [ "$rc" = 0 ] && [ "$el" -lt 5 ]; then ok "absent osimages CRD: degrades in ${el}s (rc=0) — does NOT refuse a Supervisor that lacks it"
else bad "absent CRD: rc=$rc after ${el}s" "an absent CRD classifies UNKNOWN, and a die arm there is a regression"; fi
if saw 'UNKNOWN'; then ok "absent osimages CRD: classified UNKNOWN and said so"
else bad "absent CRD: UNKNOWN not named"; fi

# THE TRUE NEGATIVE. A read that SUCCEEDED and returned nothing is a real fact about the Supervisor,
# so it must still wait QUIETLY. Without this the fix could degenerate into warning unconditionally.
set -- "$(run osi_empty 16)"; rc="${1%% *}"; el="${1##* }"
if saw 'cross-check is SKIPPED'; then bad "osimages EMPTY warned" "a successful-but-empty read is not a failure"
else ok "osimages EMPTY: no warning — a readable empty list is a fact, not an error"; fi
if [ "$el" -ge 16 ]; then ok "osimages EMPTY: still WAITS (${el}s) — the pre-existing behaviour is intact"
else bad "osimages EMPTY returned in ${el}s" "it stopped waiting; that is a behaviour change, not this fix"; fi

# THE HAPPY PATH, exercised here for the FIRST time: the old stub emitted the same TKr row for both
# reads, so the join saw a version where it needed an OS name and have[] was always empty.
set -- "$(run ok 16)"; rc="${1%% *}"
if [ "$rc" = 0 ]; then ok "happy path: TKr + a matching photon OSImage resolves a version (rc=0)"
else bad "happy path rc=$rc" "the join is broken, or the stub's OS-name row does not match"; fi
if saw 'cross-check is SKIPPED'; then bad "happy path warned" "the warning fires when nothing is wrong"
else ok "happy path: silent — no warning when both reads succeed"; fi

# THE SANDBOX ASSERTION. A degrade path is the first thing to reach set_env_var into .env, so prove
# the suite did not write the operator's real one.
_env_after=""
[ -f "$SCRIPT_DIR/../.env" ] && _env_after="$(cksum < "$SCRIPT_DIR/../.env")"
if [ "$_env_before" = "$_env_after" ]; then ok "the repo's real ./.env is byte-unchanged (REPO_ROOT sandbox holds)"
else bad "THE SUITE WROTE ./.env" "REPO_ROOT is not being honoured — every later run inherits it"; fi

echo "tkr classify: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ] || exit 1
