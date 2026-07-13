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
if _VKS_EXPLICIT_KUBECONFIG="${tmp}/other.kubeconfig" state_check >/dev/null 2>&1; then
  bad "a MISMATCHED sink was SOURCED — its LB IPs and passwords belong to another cluster"
else
  ok "a MISMATCHED sink is NOT sourced"
fi
if [ -f "$VKS_STATE_FILE" ]; then
  bad "the mismatched sink is still in place"
else
  ok "the mismatched sink was moved aside"
fi
if ls "${tmp}"/.env.state.stale-* >/dev/null 2>&1; then
  ok "it was ARCHIVED (renamed), NOT deleted — it may hold a live cluster's only passwords"
else
  bad "the mismatched sink was DELETED — those passwords are gone"
fi

# 4. MATCH -> sourced
rm -f "${tmp}"/.env.state.stale-*
state_set FOO bar
printf 'VKS_STATE_SERVER=https://9.9.9.9:6443\n' >> "$VKS_STATE_FILE"
if _VKS_EXPLICIT_KUBECONFIG="${tmp}/other.kubeconfig" state_check >/dev/null 2>&1; then
  ok "a MATCHING sink IS sourced"
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

rm -rf "$tmp"
if [ "$fail" = 0 ]; then
  echo "test-state-overlay: OK"
  exit 0
fi
echo "test-state-overlay: FAILED" >&2
exit 1
