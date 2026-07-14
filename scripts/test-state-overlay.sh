#!/usr/bin/env bash
# test-state-overlay.sh — the stamped state sink (lib/state.sh), offline.
#
# These assertions are the ADVERSARY'S findings, FROZEN. The backlog originally asked to "STAMP the
# overlay and REFUSE to source it against a different cluster". Refusing is WRONG, and this test says
# why — so nobody re-implements the naive version:
#
#   * The sink holds the ONLY copy of the three GENERATED passwords (05-kind-up.sh), and the air-gap
#     jumpbox has NO cluster to stamp against. Refusing an unstamped sink destroys them.
#   * A MISMATCHED sink is ARCHIVED (renamed), never deleted — it may still hold the only credentials
#     of a cluster that is STILL RUNNING.
#
# Offline by construction: `kubectl config view` PARSES a kubeconfig file — it never dials an API
# server and needs no RBAC, which is also why a locked-down TENANT can use it.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
export REPO_ROOT="$PWD"
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

tmp="$(mktemp -d)"
export VKS_STATE_FILE="${tmp}/.env.state"

# 1. the sink is 0600 — it holds generated passwords
state_set HARBOR_PASSWORD "s3cret"
mode="$(stat -c %a "$VKS_STATE_FILE")"
if [ "$mode" = 600 ]; then
  ok "the sink is 0600 (it holds generated passwords)"
else
  bad "the sink is ${mode}, not 0600"
fi

# 2. UNSTAMPED -> still SOURCED. Refusing would destroy the only copy of the generated passwords, and
#    the air-gap jumpbox has no cluster to stamp against.
if state_check >/dev/null 2>&1; then
  ok "an UNSTAMPED sink is still SOURCED (the jumpbox has no cluster to stamp from)"
else
  bad "an UNSTAMPED sink was refused — that destroys the only copy of the generated passwords"
fi

# 3. MISMATCH -> not sourced, and ARCHIVED (renamed), never deleted
printf 'VKS_STATE_SERVER=https://1.2.3.4:6443\n' >> "$VKS_STATE_FILE"
cat > "${tmp}/other.kubeconfig" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: other, cluster: {server: https://9.9.9.9:6443}}]
contexts: [{name: other, context: {cluster: other, user: u}}]
current-context: other
users: [{name: u, user: {}}]
KC
# DRIVE load_env, NOT state_check. The first version of this test hand-set _VKS_EXPLICIT_KUBECONFIG —
# the input the PRODUCT never supplied — so it passed against DEAD CODE: load_env never set that
# variable, state_check always returned 0, and a foreign sink was ALWAYS sourced. A test that supplies
# the mechanism's input itself is testing the fixture, not the code.
# Probe a key that exists ONLY in the sink, with .env skipped — otherwise the operator's own .env
# supplies HARBOR_PASSWORD and the probe measures nothing.
printf 'SINK_ONLY_CANARY=leaked\n' >> "$VKS_STATE_FILE"
leak="$(SKIP_DOTENV=1 VKS_STATE_FILE="$VKS_STATE_FILE" KUBECONFIG="${tmp}/other.kubeconfig" \
          bash -c '. scripts/lib/os.sh; load_env >/dev/null 2>&1; printf "%s" "${SINK_ONLY_CANARY:-}"')"
if [ -n "$leak" ]; then
  bad "a MISMATCHED sink was SOURCED through load_env — a foreign cluster's state leaked in"
else
  ok "a MISMATCHED sink is NOT sourced (proven through load_env, the product's real entry point)"
fi
# 3b. A READ MUST NOT MUTATE. state_check runs inside load_env — i.e. on EVERY script, including
#     read-only ones. It used to state_archive on mismatch, so a single
#         KUBECONFIG=/tmp/other make creds-show
#     RENAMED the operator's sink; the next command against the ORIGINAL cluster then found no
#     overlay and silently fell back to .env.example defaults (LB IPs, CA paths, passwords gone),
#     while .env.state.stale-* files piled up. Declining to source is sufficient. Archiving belongs
#     on the WRITE path (state_claim_kind), where the file is about to be overwritten anyway.
if [ -f "$VKS_STATE_FILE" ]; then
  ok "a mismatched sink is LEFT ALONE by a READ (load_env must not rename the operator's state)"
else
  bad "load_env MOVED the sink on a read — a read-only command just renamed the operator's state"
fi
if ls "${tmp}"/.env.state.stale-* >/dev/null 2>&1; then
  bad "a READ archived the sink — that is a mutation on a read path"
else
  ok "no .stale-* litter from a read"
fi

# 4. MATCH -> sourced
# Start from a CLEAN sink: case 3 now (correctly) LEAVES the mismatched file in place, so appending a
# second VKS_STATE_SERVER here would leave the OLD one first — and state_check reads the first match.
# (The old fixture only worked because the read path archived the file, which is the bug we removed.)
rm -f "${tmp}"/.env.state.stale-* "$VKS_STATE_FILE"
state_set FOO bar
printf 'VKS_STATE_SERVER=https://9.9.9.9:6443\n' >> "$VKS_STATE_FILE"
got="$(SKIP_DOTENV=1 VKS_STATE_FILE="$VKS_STATE_FILE" KUBECONFIG="${tmp}/other.kubeconfig" \
         bash -c '. scripts/lib/os.sh; load_env >/dev/null 2>&1; printf "%s" "${FOO:-}"')"
if [ "$got" = bar ]; then
  ok "a MATCHING sink IS sourced (through load_env)"
else
  bad "a matching sink was refused"
fi

# 5. THE DELETE CONTRACT. Both real-lab runbooks tell the operator to run `make kind-down` at Step 0 —
#    and this same sink now holds a lab's discovered LB IPs, CA paths and Gitea token. An
#    unconditional `rm` there is how the repo already destroyed a real lab's kubeconfig once (#167).
if grep -q 'VKS_STATE_KIND' "${REPO_ROOT}/scripts/kind-down.sh"; then
  ok "kind-down keys its delete on VKS_STATE_KIND (it cannot eat a real lab's state)"
else
  bad "kind-down deletes the state overlay UNCONDITIONALLY — it will destroy a real lab's state"
fi

# 6. set_env_var has NO default sink. That default is exactly what put real-lab state into a
#    KinD-named file in the first place.
if grep -qE 'file="\$\{3:\?' "${REPO_ROOT}/scripts/lib/os.sh"; then
  ok "set_env_var REQUIRES an explicit sink (no silent default to a KinD-named file)"
else
  bad "set_env_var still DEFAULTS its sink — the class can grow straight back"
fi

# 7. the last publish-then-read-back is gone (70 re-derives the destination from the live cluster).
if sed 's/#.*//' "${REPO_ROOT}/scripts/71-argocd-register-guest.sh" | grep -q 'state_set ARGOCD_DEST_SERVER'; then
  bad "71 still PUBLISHES ARGOCD_DEST_SERVER — a stale pointer survives into the NEXT cluster"
else
  ok "71 does not publish ARGOCD_DEST_SERVER (70 re-derives it from the live ArgoCD Cluster Secrets)"
fi

# 8. A KUBECONFIG SET IN `.env` IS AN EXPLICIT CHOICE TOO.
#    THE BUG: load_env snapshotted the explicit selectors from the ENVIRONMENT ONLY, before sourcing
#    anything. So for the operator who did the DOCUMENTED thing (uncomment KUBECONFIG in .env, per
#    .env.example), _VKS_EXPLICIT_KUBECONFIG was EMPTY — and state_check's mismatch branch
#    short-circuits on exactly that. The whole cross-cluster refusal was DEAD CODE for the one
#    operator it exists to protect: a lab's sink was sourced unconditionally into a KinD run.
#    Case 3 above passes even with the bug present, because it puts KUBECONFIG in the ENVIRONMENT.
fake="$(mktemp -d)"
cp "${REPO_ROOT}/.env.example" "${fake}/.env.example"
cat > "${fake}/other.kubeconfig" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: other, cluster: {server: https://9.9.9.9:6443}}]
contexts: [{name: other, context: {cluster: other, user: u}}]
current-context: other
users: [{name: u, user: {}}]
KC
printf 'KUBECONFIG=%s/other.kubeconfig\n' "$fake" > "${fake}/.env"    # the DOCUMENTED lab setup
printf 'VKS_STATE_SERVER=https://1.2.3.4:6443\nSINK_ONLY_CANARY=leaked\n' > "${fake}/.env.state"
leak8="$(cd "${REPO_ROOT}" && REPO_ROOT="$fake" VKS_STATE_FILE="${fake}/.env.state" \
           bash -c '. scripts/lib/os.sh; load_env >/dev/null 2>&1; printf "%s" "${SINK_ONLY_CANARY:-}"')"
if [ -n "$leak8" ]; then
  bad "a KUBECONFIG in .env is IGNORED as a selector — a foreign cluster's sink was sourced into the run"
else
  ok "a KUBECONFIG set in .env counts as an EXPLICIT selection (the documented lab setup is protected)"
fi
rm -rf "$fake"

# 9. THE KIND FLOW MUST NOT WRITE INTO A SINK IT DID NOT CREATE.
#    05-kind-up.sh used to upsert into WHATEVER sink was there and then stamp it `--kind`. On a box
#    where a real lab wrote that sink, that re-stamped the LAB's state as KinD state — and
#    `make kind-down` (Step 0 of BOTH lab runbooks) then DELETED it.
lab="$(mktemp -d)"
export VKS_STATE_FILE="${lab}/.env.state"
printf 'VKS_STATE_KIND=0\nVKS_STATE_SERVER=https://lab.example.com:6443\nHARBOR_PASSWORD=LabOnlySecret\n' > "$VKS_STATE_FILE"
HARBOR_PASSWORD="LabOnlySecret"          # as load_env would have exported it
state_claim_kind >/dev/null 2>&1
if [ -f "$VKS_STATE_FILE" ]; then
  bad "state_claim_kind wrote into the LAB's sink — kind-down will now delete a real lab's state"
else
  ok "state_claim_kind refuses a foreign sink (the KinD flow starts on a fresh one)"
fi
if ls "${lab}"/.env.state.stale-* >/dev/null 2>&1; then
  ok "the lab's sink was ARCHIVED, not deleted — it may hold a live cluster's only passwords"
else
  bad "the lab's sink was DELETED — its generated passwords are gone"
fi
if [ -n "${HARBOR_PASSWORD:-}" ]; then
  bad "the lab's HARBOR_PASSWORD survived into the KinD run — the throwaway Harbor would REUSE a lab credential"
else
  ok "the foreign sink's values were UNSET (a KinD Harbor cannot inherit a lab's password)"
fi
rm -rf "$lab"

# 10. ...and the KinD flow actually CALLS it, before its first write.
kb="${REPO_ROOT}/scripts/05-kind-up.sh"
claim_ln="$(sed 's/#.*//' "$kb" | grep -n 'state_claim_kind' | head -1 | cut -d: -f1)"
set_ln="$(  sed 's/#.*//' "$kb" | grep -n 'state_set'        | head -1 | cut -d: -f1)"
if [ -n "$claim_ln" ] && [ -n "$set_ln" ] && [ "$claim_ln" -lt "$set_ln" ]; then
  ok "05-kind-up.sh claims the sink BEFORE its first state_set"
else
  bad "05-kind-up.sh writes state before claiming the sink (claim=${claim_ln:-none} set=${set_ln:-none})"
fi

rm -rf "$tmp"
if [ "$fail" = 0 ]; then
  echo "test-state-overlay: OK"
  exit 0
fi
echo "test-state-overlay: FAILED" >&2
exit 1
