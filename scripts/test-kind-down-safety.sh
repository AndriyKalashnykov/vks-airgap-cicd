#!/usr/bin/env bash
# test-kind-down-safety.sh — `make kind-down` must delete ONLY what the KinD flow created.
#
# WHY THIS EXISTS (a data-loss bug, instructed by our own runbooks)
# ----------------------------------------------------------------
# kind-down used to delete:
#   * ANY kubeconfig under ./secrets — and the DOCUMENTED real-lab default is
#     `./secrets/vks.kubeconfig` (.env.example). Its comment even claimed this protected a real-VKS
#     kubeconfig; it did the exact opposite.
#   * `secrets/gitea-ci-token` and `secrets/webhook-token`, UNCONDITIONALLY, on the claim that "only
#     the kind flow writes these; real-VKS runs use their own". FALSE:
#     50-seed-gitea-repos.sh writes both in EITHER flow.
#
# And BOTH real-lab runbooks (docs/scenario-1.md, docs/scenario-2.md) tell the operator to run
# `make kind-down` at Step 0 to clear stale KinD state. So following our own documentation on a lab
# box DESTROYED the operator's lab kubeconfig and their Gitea CI token.
#
# A teardown removes what it created. Nothing else. This test asserts exactly that, offline.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

KD="${SCRIPT_DIR}/kind-down.sh"

# 1. The kubeconfig deletion must key on KIND_KUBECONFIG (what WE wrote), never on "is it under
#    ./secrets" (which is exactly where the real-lab kubeconfig lives).
if grep -q 'KIND_KUBECONFIG' "$KD"; then
  ok "kind-down deletes the kubeconfig by KIND_KUBECONFIG (what the KinD flow actually wrote)"
else
  bad "kind-down does not use KIND_KUBECONFIG — it cannot tell OUR kubeconfig from the operator's"
fi
if grep -qE '"\$\{secrets_dir\}/"\*\)' "$KD"; then
  bad "kind-down still deletes ANY kubeconfig under ./secrets — that is where secrets/vks.kubeconfig (the real-lab default) lives"
else
  ok "kind-down no longer deletes kubeconfigs merely because they sit under ./secrets"
fi

# 2. 05-kind-up.sh must actually RECORD it, or the guard above can never fire.
# state_set is set_env_var against the STAMPED sink (lib/state.sh) — the same publish, a sink that
# says which cluster it belongs to.
if grep -qE '(set_env_var|state_set) KIND_KUBECONFIG' "${SCRIPT_DIR}/05-kind-up.sh"; then
  ok "05-kind-up.sh records KIND_KUBECONFIG (so teardown knows what it created)"
else
  bad "05-kind-up.sh does NOT record KIND_KUBECONFIG — kind-down has nothing to key on"
fi

# 2b. And it must write it to a path IT OWNS — never to a caller-controlled $KUBECONFIG.
#     `kind get kubeconfig > "$KUBECONFIG"` TRUNCATES whatever the operator's KUBECONFIG points at
#     (a developer's ~/.kube/config), and kind-down then DELETES it. The old .env.example pin was an
#     accidental shield, not a design.
# `sed 's/#.*//'` is load-bearing: a grep-gate that does not strip comments matches the comment that
# EXPLAINS it, and fails the very file it certifies. (It did, on this test's first run.)
if sed 's/#.*//' "${SCRIPT_DIR}/05-kind-up.sh" | grep -qE 'KUBECONFIG_PATH="\$\{KUBECONFIG[:?]'; then
  bad "05-kind-up.sh writes its kubeconfig to the CALLER's \$KUBECONFIG — it will truncate (and kind-down will then delete) a developer's ~/.kube/config"
else
  ok "05-kind-up.sh writes its kubeconfig to a path IT owns, not to the caller's \$KUBECONFIG"
fi

# 3. The Gitea/webhook credentials may only be removed when a kind cluster was ACTUALLY torn down.
if grep -q 'KIND_CLUSTER_REMOVED' "$KD"; then
  ok "the gitea/webhook credentials are removed only when a kind cluster was actually deleted"
else
  bad "kind-down removes secrets/gitea-ci-token + secrets/webhook-token UNCONDITIONALLY — a real lab writes those too (50-seed-gitea-repos.sh)"
fi

# 4. The false comment must be gone: 50-seed writes those credentials in EITHER flow.
if grep -q 'Only the kind flow writes these' "$KD"; then
  bad "kind-down still claims 'only the kind flow writes these' — 50-seed-gitea-repos.sh writes them on a real lab too"
else
  ok "the false 'only the kind flow writes these' claim is gone"
fi

# 5. Ground truth for #4: the seeder really does write them unconditionally.
if grep -q 'secrets/gitea-ci-token' "${SCRIPT_DIR}/50-seed-gitea-repos.sh"; then
  ok "confirmed: 50-seed-gitea-repos.sh writes secrets/gitea-ci-token in EITHER flow (so kind-down must not assume otherwise)"
else
  bad "50-seed-gitea-repos.sh no longer writes secrets/gitea-ci-token — this test's premise needs re-checking"
fi

[ "$fail" = 0 ] && { echo "test-kind-down-safety: OK"; exit 0; }
echo "test-kind-down-safety: FAILED" >&2; exit 1
