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
if sed 's/#.*//' "${SCRIPT_DIR}/05-kind-up.sh" | grep -E 'KUBECONFIG_PATH="\$\{KUBECONFIG[:?]' >/dev/null; then
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

# ---------------------------------------------------------------------------------------------
# 6-9. EXECUTING ARM. Checks 1-5 above are pure greps over source, which is structurally incapable
# of observing the defect that mattered: with docker present-but-UNUSABLE this script printed three
# "not present — skipping" lines and then DELETED the state overlay, rc=0, "kind teardown complete".
# `lib/state.sh` says that file holds the ONLY copy of the generated HARBOR/GITEA/ARGOCD passwords
# and must be ARCHIVED, never `rm`-ed, when ownership cannot be established. So it was rc=0 data loss.
#
# A fake `docker`/`kind` is FAITHFUL here because the script observes only their rc, stdout and
# stderr, and the real permission failure was measured as rc=1 / empty stdout / a message. It is
# faithful ONLY as long as the fix branches on rc — which is why the stderr text below deliberately
# differs from this box's docker wording (measured: two strings for one condition across versions).
_sandbox() {                      # _sandbox <docker-behaviour> -> echoes the sandbox dir
  local sb; sb="$(mktemp -d)"
  cp -a "$SCRIPT_DIR" "$sb/scripts"
  [ -f "${SCRIPT_DIR}/../.env.example" ] && cp "${SCRIPT_DIR}/../.env.example" "$sb/"
  mkdir -p "$sb/fakebin"
  case "$1" in
    unusable)
      printf '#!/usr/bin/env bash\necho "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2\nexit 1\n' > "$sb/fakebin/docker"
      printf '#!/usr/bin/env bash\necho "ERROR: failed to list clusters: command \\"docker ps\\" failed" >&2\nexit 1\n' > "$sb/fakebin/kind" ;;
    empty)   # a WORKING docker with genuinely nothing to clean — the positive control
      printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/fakebin/docker"
      printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/fakebin/kind" ;;
  esac
  chmod +x "$sb/fakebin"/* 2>/dev/null || true
  printf 'VKS_STATE_KIND=1\nHARBOR_PASSWORD=canary-do-not-delete\n' > "$sb/.env.state"
  printf '%s' "$sb"
}
# Only $KD_OUT and the on-disk artifacts are asserted — the rc is deliberately NOT part of the
# contract, because a cannot-ask run legitimately still exits 0 after doing the file half.
_run_kd() {                       # _run_kd <sandbox> -> writes $KD_OUT
  KD_OUT="$(cd "$1" && PATH="$1/fakebin:$PATH" KIND_CLUSTER_NAME=probe-cluster \
            VKS_STATE_FILE="$1/.env.state" SKIP_DOTENV=1 bash "$1/scripts/kind-down.sh" 2>&1)" || true
}

# 6. THE CANARY. Cannot-ask must NOT delete the overlay. This is the case that was rc=0 data loss.
sb="$(_sandbox unusable)"; _run_kd "$sb"
if [ -f "$sb/.env.state" ]; then
  ok "cannot-ask: the state overlay SURVIVES (the only copy of the generated passwords)"
else
  bad "cannot-ask DELETED the state overlay — rc=0 data loss, the defect this test exists for"
fi
# 7. and it must not claim it cleaned things it never looked at
if printf '%s' "$KD_OUT" | grep -q 'CANNOT ASK docker'; then
  ok "cannot-ask says so out loud instead of reporting a clean teardown"
else
  bad "cannot-ask produced no CANNOT ASK line — it is still inferring absence from inability"
fi
rm -rf "$sb"

# 8. POSITIVE CONTROL: a WORKING docker with genuinely nothing to clean must still proceed and
#    delete the stamped overlay. Without this, "always refuse" would pass check 6 and be useless.
sb="$(_sandbox empty)"; _run_kd "$sb"
if [ ! -f "$sb/.env.state" ]; then
  ok "genuinely-empty: the stamped overlay IS removed (the fix did not degenerate into always-refuse)"
else
  bad "genuinely-empty: the stamped overlay survived — the fix over-refuses and kind-down no longer works"
fi
rm -rf "$sb"

# 9. docker ABSENT must still reach the FILE half — the old `require_cmd docker` made every pure-file
#    operation unreachable on a docker-free box, while scenario-2 Step 0c tells EVERY operator to run
#    this command.
#
#    ⚠️ THIS NEEDS A CURATED PATH, NOT A PREPENDED fakebin. My first version merely removed the fake
#    docker and left "$sb/fakebin:$PATH" — so the REAL docker was still found and the case passed on
#    the PRE-FIX tree too. A case that passes in both arms is measuring nothing. The tell was exactly
#    that: it did not flip when the fix was reverted.
sb="$(_sandbox empty)"; rm -f "$sb/fakebin/docker"
mkdir -p "$sb/purebin"
# dirname is LOAD-BEARING: kind-down.sh:11 uses it to locate lib/os.sh. Omitting it made the script
# die at line 11 in BOTH arms, so this case could not discriminate — measured, and it is exactly the
# "absence of a match is evidence about your HARNESS first" trap.
for _b in bash grep cut rm basename dirname mktemp head sed date cat tr ls sort wc id stat readlink env uname; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -sf "$_p" "$sb/purebin/$_b"
done
ln -sf "$sb/fakebin/kind" "$sb/purebin/kind"
if command -v docker >/dev/null 2>&1 && PATH="$sb/purebin" command -v docker >/dev/null 2>&1; then
  bad "the curated PATH still leaks a real docker — case 9 would be vacuous; fix the harness"
else
  ok "curated PATH carries no docker (so case 9 measures something)"
fi
KD_OUT="$(cd "$sb" && PATH="$sb/purebin" KIND_CLUSTER_NAME=probe-cluster \
          VKS_STATE_FILE="$sb/.env.state" SKIP_DOTENV=1 bash "$sb/scripts/kind-down.sh" 2>&1)" || true
# ASSERT A POSITIVE MARKER, not the ABSENCE of the FATAL. A negative assertion also passes when the
# script dies for an unrelated reason — measured: with dirname missing it died at line 11 and the
# "no FATAL string" test reported ok in BOTH arms. The file half is REACHED iff it says something
# about the overlay.
if printf '%s' "$KD_OUT" | grep -qE 'leaving .* in place|removing the KinD state overlay'; then
  ok "docker absent: the FILE half is REACHED (the overlay decision was made)"
else
  bad "docker absent: the file half was never reached — output was: $(printf '%s' "$KD_OUT" | head -2 | tr '\n' ' ')"
fi
rm -rf "$sb"

[ "$fail" = 0 ] && { echo "test-kind-down-safety: OK"; exit 0; }
echo "test-kind-down-safety: FAILED" >&2; exit 1
