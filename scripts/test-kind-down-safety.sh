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
# ⚠️ THIS CHECK USED TO GREP FOR `KIND_CLUSTER_REMOVED` and certify "removed only when a kind
# cluster was actually deleted". It was GREEN THROUGHOUT the live 2026-09-05 incident, because
# that condition WAS satisfied: the box had a kind cluster AND a lab — this repo's normal dev
# posture. A check that passes over the defect it names is worse than none, and after the fix
# it would have certified a property no longer present in the file.
if grep -qE '^[[:space:]]*run rm -f .*secrets/(gitea-ci-token|webhook-token)' "$KD"; then
  bad "kind-down still DELETES secrets/gitea-ci-token or secrets/webhook-token — 50-seed-gitea-repos.sh writes both in EITHER flow (B537, fired live 2026-09-05)"
else
  ok "kind-down does not delete the gitea/webhook credentials at all — they are flow-agnostic"
fi

# 4. The false comment must be gone: 50-seed writes those credentials in EITHER flow.
# ⚠️ THIS CHECK USED TO GREP a COMMENT — 'Only the kind flow writes these', capital O — which
# MEASURED 0 hits at ANY case: the wording had already been reworded, so it could never fire in
# either direction. The live incident's actual output was `removing kind-cluster-scoped
# credential ...`, a string this test never mentioned. Assert what the OPERATOR READS.
# COMMENTS STRIPPED FIRST. Without that this fires on kind-down.sh's own comment explaining why
# the label was false — the self-scanning trap (gates.md): documenting a defect makes it
# ungreppable, and the "fix" people reach for is deleting the explanation.
if grep -q 'kind-cluster-scoped' <<< "$(sed -E 's@^[[:space:]]*#.*@@' "$KD")"; then
  bad "kind-down still calls those credentials 'kind-cluster-scoped' — the FALSE label it printed on 2026-09-05 while destroying a real lab's"
else
  ok "the false 'kind-cluster-scoped' label the operator used to read is gone"
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
      # ⚠️ The stub DERIVES the cluster name from .env.example rather than echoing a literal.
      # SKIP_DOTENV=1 skips `.env` but NOT `.env.example`, whose KIND_CLUSTER_NAME wins over the
      # environment — the clobber class this repo documents. MEASURED: the run resolved
      # `vks-airgap-cicd`, not the `probe-cluster` the harness exports, so a hardcoded stub answer
      # never matched and the CONTROL correctly read "nothing was deleted".
      present) # a WORKING docker AND the cluster IS there -- THE LIVE 2026-09-05 SHAPE (B537).
               # This is exactly the state the old KIND_CLUSTER_REMOVED guard was SATISFIED by,
               # which is why that guard stayed green while a real lab's credentials were
               # destroyed. A kind cluster AND a lab on one box is this repo's normal posture.
        printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/fakebin/docker"
        # shellcheck disable=SC2016  # the $1 belongs to the STUB SCRIPT being written, not to us:
        # single quotes are load-bearing, expansion here would bake OUR $1 into the stub.
        printf '#!/usr/bin/env bash\ncase "$1" in get) sed -n "s/^KIND_CLUSTER_NAME=//p" .env.example | head -1 ;; *) exit 0 ;; esac\n' > "$sb/fakebin/kind" ;;
  esac
  chmod +x "$sb/fakebin"/* 2>/dev/null || true
  printf 'VKS_STATE_KIND=1\nHARBOR_PASSWORD=canary-do-not-delete\n' > "$sb/.env.state"
  printf '%s' "$sb"
}
# Only $KD_OUT and the on-disk artifacts are asserted — the rc is deliberately NOT part of the
# contract, because a cannot-ask run legitimately still exits 0 after doing the file half.
_run_kd() {                       # _run_kd <sandbox> -> writes $KD_OUT
  # ⚠️ REPO_ROOT="$1" IS LOAD-BEARING, AND ITS ABSENCE MADE THIS WHOLE SANDBOX A FICTION.
  #
  # `scripts/lib/os.sh:31` does `export REPO_ROOT`, and THIS TEST sources os.sh — so the child
  # kind-down.sh INHERITED the REAL repo root and every `${REPO_ROOT}/secrets/...` path it touched
  # was the developer's own. MEASURED 2026-09-07, while RED-proving the B537 fix: a mutation that
  # re-added the credential deletion DESTROYED THE REAL secrets/gitea-ci-token and
  # secrets/webhook-token on this box, and the test reported ok — because the sandbox copy it
  # asserted on was never the file being deleted.
  #
  # So the test could do the exact damage B537 is about, while certifying that it could not. Every
  # case that asserts on a `$sb/...` artifact was vacuous in the same way, including the .env.state
  # canary that exists to prevent data loss.
  KD_OUT="$(cd "$1" && PATH="$1/fakebin:$PATH" KIND_CLUSTER_NAME=probe-cluster REPO_ROOT="$1" \
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
sb8="$(_sandbox empty)"; _run_kd "$sb8"

# ── SELF-CANARY: this test must not be able to damage the REAL repo. ───────────────────────────
#
# It could, and it did — TWICE, on 2026-09-07, while RED-proving the B537 fix. `lib/os.sh:31` does
# `export REPO_ROOT`, and this test sources os.sh, so a sandboxed kind-down.sh INHERITED the real
# repo root: every `${REPO_ROOT}/secrets/...` it touched was the developer's own. A mutation that
# re-added the credential deletion destroyed the real secrets/gitea-ci-token and
# secrets/webhook-token — the exact incident B537 is about — while this test reported `ok`, because
# the sandbox copy it asserted on was never the file being deleted.
#
# Both call sites now pin REPO_ROOT to the sandbox. This canary is what makes that a PROPERTY rather
# than a thing someone remembered: it fingerprints the real credentials before the sandboxed runs and
# re-checks them after. It is deliberately the FIRST thing set up and the LAST thing asserted.
_canary_real=""
for _cf in "${REPO_ROOT}/secrets/gitea-ci-token" "${REPO_ROOT}/secrets/webhook-token" "${REPO_ROOT}/.env.state"; do
  [ -f "$_cf" ] && _canary_real="${_canary_real}$(md5sum "$_cf" 2>/dev/null || true)"
done

# ── B537: THE LIVE 2026-09-05 SHAPE — a kind cluster AND a lab on one box. ──────────────────────
#
# ⚠️ THE CONTROL BELOW IS NOT OPTIONAL. Without it a kind-down that refuses to do ANYTHING passes
# the survival case — the teardown would be dead and this test would call that safety.
sb="$(_sandbox present)"
mkdir -p "$sb/secrets"
printf 'ci-token-canary\n'      > "$sb/secrets/gitea-ci-token"
printf 'webhook-token-canary\n' > "$sb/secrets/webhook-token"
_run_kd "$sb"

if [ -f "$sb/secrets/gitea-ci-token" ] && [ -f "$sb/secrets/webhook-token" ]; then
  ok "B537: both credentials SURVIVE a teardown that really deleted a kind cluster"
else
  bad "B537 REGRESSION: kind-down deleted a flow-agnostic credential — the 2026-09-05 live incident"
fi

# CONTENT, not just existence: a silent re-mint is a loss too, and a worse one for webhook-token
# (Gitea and k8s would then hold different HMAC secrets and every delivery is rejected silently).
if [ "$(cat "$sb/secrets/gitea-ci-token" 2>/dev/null)" = "ci-token-canary" ] \
   && [ "$(cat "$sb/secrets/webhook-token" 2>/dev/null)" = "webhook-token-canary" ]; then
  ok "B537: their CONTENT is unchanged (a re-mint would desynchronise the webhook HMAC)"
else
  bad "B537: a credential's CONTENT changed — Gitea and k8s would now disagree"
fi

case "$KD_OUT" in
  *kind-cluster-scoped*) bad "B537: the false 'kind-cluster-scoped' label is back in the OUTPUT" ;;
  *)                     ok "B537: the operator is not told those credentials are kind-scoped" ;;
esac

case "$KD_OUT" in
  *"deleting kind cluster"*) ok "B537 CONTROL: the kind cluster WAS deleted (the teardown is not inert)" ;;
  *)                         bad "B537 CONTROL: nothing was deleted — the survival case would pass on a DEAD teardown" ;;
esac
rm -rf "$sb"

# GROUND TRUTH for the whole verdict: the seeder really does validate the CI token against the live
# Gitea. If that ever goes, the stale-token premise returns and this rule must be re-argued.
# shellcheck disable=SC2016  # a grep PATTERN — it must match the literal text in the seeder,
# so $CANDIDATE_TOKEN must NOT expand here.
if grep -q 'token_works "$CANDIDATE_TOKEN"' "${SCRIPT_DIR}/50-seed-gitea-repos.sh"; then
  ok "B537 ground truth: the seeder still VALIDATES the CI token against the live Gitea"
else
  bad "B537 ground truth GONE: 50-seed no longer validates the CI token — re-argue before trusting this"
fi


# THE CANARY, ASSERTED LAST — after every sandboxed kind-down has run.
_canary_now=""
for _cf in "${REPO_ROOT}/secrets/gitea-ci-token" "${REPO_ROOT}/secrets/webhook-token" "${REPO_ROOT}/.env.state"; do
  [ -f "$_cf" ] && _canary_now="${_canary_now}$(md5sum "$_cf" 2>/dev/null || true)"
done
if [ "$_canary_real" = "$_canary_now" ]; then
  ok "SELF-CANARY: this test did not touch the REAL repo's credentials or state overlay"
else
  bad "SELF-CANARY FAILED: a sandboxed run reached OUTSIDE its sandbox and changed the REAL repo.
       A kind-down invocation is missing REPO_ROOT=<sandbox> — lib/os.sh EXPORTS REPO_ROOT, so the
       child inherits the developer's repo. Grep EVERY 'kind-down.sh' invocation in this file."
fi

if [ ! -f "$sb8/.env.state" ]; then
  ok "genuinely-empty: the stamped overlay IS removed (the fix did not degenerate into always-refuse)"
else
  bad "genuinely-empty: the stamped overlay survived — the fix over-refuses and kind-down no longer works"
fi
rm -rf "$sb8"

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
# REPO_ROOT="$sb" for the same reason as in _run_kd -- see the note there. This SECOND
# invocation was missed on the first pass and destroyed the real credentials a SECOND time,
# minutes after the first was fixed: one call site pinned, one not. Grep EVERY invocation.
KD_OUT="$(cd "$sb" && PATH="$sb/purebin" KIND_CLUSTER_NAME=probe-cluster REPO_ROOT="$sb" \
          VKS_STATE_FILE="$sb/.env.state" SKIP_DOTENV=1 bash "$sb/scripts/kind-down.sh" 2>&1)" || true
# ASSERT A POSITIVE MARKER, not the ABSENCE of the FATAL. A negative assertion also passes when the
# script dies for an unrelated reason — measured: with dirname missing it died at line 11 and the
# "no FATAL string" test reported ok in BOTH arms. The file half is REACHED iff it says something
# about the overlay.
if printf '%s' "$KD_OUT" | grep -qE 'leaving \.env\.state in place|archiving the KinD state overlay'; then
  ok "docker absent: the FILE half is REACHED (the overlay decision was made)"
else
  bad "docker absent: the file half was never reached — output was: $(printf '%s' "$KD_OUT" | head -2 | tr '\n' ' ')"
fi
rm -rf "$sb"

# ---------------------------------------------------------------------------------------------
# 10-19. ANOTHER PROJECT'S KIND CLUSTER ON THE SAME HOST.
#
# kind-down used to remove the cloud-provider-kind controller and EVERY kindccm-* container. One
# controller serves every kind cluster on a host, so on a box that also runs another project's
# cluster (golang-web's, say) `make kind-down` destroyed that project's LoadBalancers. Arms 10, 12, 13, 14, 16, the
# first half of 17 and 18 were RED against the script as it stood at 6d81f16. Arms 11 and 15 are
# controls, so a kind-down that removes nothing cannot pass; the second half of 17 guards the fix
# itself (RED when the second listing feeds the overlay decision); 18b, 20 and 21 came from the
# implementation review of the first version of the fix.
#
# The fakes are STATEFUL, because the properties are about which containers are LEFT: `kind get
# clusters` forgets a deleted cluster, `docker ps` answers by the filter it was given (and returns
# nothing for a filter it does not know), `docker rm` removes rows, and every call is logged.
_stateful_sandbox() {             # _stateful_sandbox -> echoes the sandbox dir (state in $sb/st)
  local sb; sb="$(_sandbox empty)"
  mkdir -p "$sb/st"; : > "$sb/st/clusters"; : > "$sb/st/containers"; : > "$sb/st/calls"
  cat > "$sb/fakebin/kind" <<'STUB'
#!/usr/bin/env bash
st="$(cd "$(dirname "$0")/.." && pwd)/st"
printf 'kind %s\n' "$*" >> "$st/calls"
case "$1 ${2:-}" in
  "get clusters")
    n=$(( $(cat "$st/kind_get_count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$st/kind_get_count"
    if [ -f "$st/kind_get_fail_from" ] && [ "$n" -ge "$(cat "$st/kind_get_fail_from")" ]; then
      echo "ERROR: failed to list clusters" >&2; exit 1
    fi
    if [ -f "$st/kind_get_fail_only" ] && [ "$n" -eq "$(cat "$st/kind_get_fail_only")" ]; then
      echo "ERROR: failed to list clusters" >&2; exit 1
    fi
    cat "$st/clusters" ;;
  "delete cluster")
    name=""; while [ $# -gt 0 ]; do [ "$1" = --name ] && name="$2"; shift; done
    grep -vxF "$name" "$st/clusters" > "$st/clusters.new" || true; mv "$st/clusters.new" "$st/clusters" ;;
esac
exit 0
STUB
  cat > "$sb/fakebin/docker" <<'STUB'
#!/usr/bin/env bash
# containers table: "<id> <name> <label-or-->" per line
st="$(cd "$(dirname "$0")/.." && pwd)/st"
printf 'docker %s\n' "$*" >> "$st/calls"
case "$1" in
  ps)
    f=""; while [ $# -gt 0 ]; do [ "$1" = --filter ] && f="$2"; shift; done
    case "$f" in
      name=*)  re="${f#name=}"; re="${re#^/?}"; re="${re%\$}"
               while read -r id name _; do
                 case "$f" in *'$') [ "$name" = "$re" ] && echo "$id" ;; *) case "$name" in *"$re"*) echo "$id" ;; esac ;; esac
               done < "$st/containers" ;;
      label=*) want="${f#label=}"
               while read -r id _ label; do [ "$label" = "$want" ] && echo "$id"; done < "$st/containers" ;;
    esac ;;
  rm)
    shift; : > "$st/containers.new"
    while read -r id name label; do
      keep=1; for a in "$@"; do { [ "$a" = "$id" ] || [ "$a" = "$name" ]; } && keep=0; done
      [ "$keep" = 1 ] && printf '%s %s %s\n' "$id" "$name" "$label" >> "$st/containers.new"
    done < "$st/containers"
    mv "$st/containers.new" "$st/containers"
    [ -f "$st/rm_fails" ] && { echo "Error response from daemon: No such container" >&2; exit 1; } ;;
esac
exit 0
STUB
  chmod +x "$sb/fakebin/kind" "$sb/fakebin/docker"
  printf '%s' "$sb"
}
_LBL="io.x-k8s.cloud-provider-kind.cluster"
# The cluster name kind-down resolves comes from .env.example, not from the environment (see the
# note in _sandbox), so the fixtures derive it the same way.
_own_name() { sed -n 's/^KIND_CLUSTER_NAME=//p' "$1/.env.example" | head -1; }
_has()  { grep -q "^$2 " "$1/st/containers"; }          # _has <sb> <id>
_rm_argv() { grep '^docker rm ' "$1/st/calls" || true; }

# The fixture itself must be what the arms assume, or every arm below is about the harness.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
if [ -n "$OWN" ] && [ "$OWN" != other-project ]; then
  ok "fixture: the sandbox .env.example names the cluster '$OWN' (arms 11 and 13 prove kind-down resolves the same name)"
else
  bad "fixture: could not derive the cluster name from the sandbox .env.example — arms 10-19 would be vacuous"
fi
rm -rf "$sb"

# 10-13. Own cluster AND a foreign cluster, each with a sidecar, one shared controller.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\nother-project\n' "$OWN" > "$sb/st/clusters"
printf 'a1 kindccm-aaaa %s=%s\nb1 kindccm-bbbb %s=other-project\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" "$_LBL" > "$sb/st/containers"
_run_kd "$sb"
if _has "$sb" b1 && ! _rm_argv "$sb" | grep -qw b1; then
  ok "another cluster's sidecar SURVIVES kind-down (it was never passed to docker rm)"
else
  bad "kind-down removed another cluster's kindccm sidecar — docker rm argv: $(_rm_argv "$sb" | tr '\n' ';')"
fi
if ! _has "$sb" a1; then
  ok "CONTROL: this cluster's own sidecar IS removed"
else
  bad "CONTROL: this cluster's own sidecar survived — kind-down no longer prunes anything"
fi
if _has "$sb" c0 && printf '%s' "$KD_OUT" | grep -q 'kind still lists: .*other-project'; then
  ok "the shared controller is KEPT while another cluster is listed, and the log names that cluster"
else
  bad "kind-down removed the shared cloud-provider-kind controller while 'other-project' still exists (or did not say why it kept it)"
fi
if grep -q "label=${_LBL}=${OWN}" "$sb/st/calls"; then
  ok "the prune selects by the literal cluster label ${_LBL}=<this cluster>"
else
  bad "no docker ps call filtered on ${_LBL}=${OWN} — the prune is not scoped to this cluster"
fi
# 14. ORDER: the prune must come after the cluster delete (a live controller recreates a sidecar
#     that is removed while its Service still exists).
_del_line="$(grep -n '^kind delete cluster' "$sb/st/calls" | head -1 | cut -d: -f1)"
_prune_line="$(grep -n "label=${_LBL}=${OWN}" "$sb/st/calls" | head -1 | cut -d: -f1)"
if [ -n "$_del_line" ] && [ -n "$_prune_line" ] && [ "$_prune_line" -gt "$_del_line" ]; then
  ok "order: the sidecar prune runs AFTER kind delete cluster"
else
  bad "order: the sidecar prune (call ${_prune_line:-none}) does not follow kind delete cluster (call ${_del_line:-none})"
fi
rm -rf "$sb"

# 15. CONTROL: only this cluster exists -> the controller IS removed. Without it "never remove the
#     controller" would pass arm 12.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"
printf 'a1 kindccm-aaaa %s=%s\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" > "$sb/st/containers"
_run_kd "$sb"
if ! _has "$sb" c0 && ! _has "$sb" a1; then
  ok "CONTROL: with no other cluster left, the controller and this cluster's sidecar are both removed"
else
  bad "CONTROL: nothing else is on the host, yet the controller or the sidecar survived: $(tr '\n' ';' < "$sb/st/containers")"
fi
_ctl_line="$(grep -n '^docker rm -f cloud-provider-kind' "$sb/st/calls" | head -1 | cut -d: -f1)"
_lbl_line="$(grep -n "label=${_LBL}=${OWN}" "$sb/st/calls" | head -1 | cut -d: -f1)"
if [ -n "$_ctl_line" ] && [ -n "$_lbl_line" ] && [ "$_lbl_line" -gt "$_ctl_line" ]; then
  ok "order: the prune runs AFTER the controller is removed (nothing is left to recreate a sidecar)"
else
  bad "order: the prune (call ${_lbl_line:-none}) does not follow the controller removal (call ${_ctl_line:-none})"
fi
if grep '^docker ps ' "$sb/st/calls" | grep -v -- ' -aq ' >/dev/null; then
  bad "a docker ps call omits -a — stopped sidecars would be missed"
else
  ok "every docker ps call lists stopped containers too (-aq)"
fi
rm -rf "$sb"

# 16. This project has NO cluster on the box, another project does: nothing of theirs is touched.
sb="$(_stateful_sandbox)"
printf 'other-project\n' > "$sb/st/clusters"
printf 'b1 kindccm-bbbb %s=other-project\nc0 cloud-provider-kind -\n' "$_LBL" > "$sb/st/containers"
_run_kd "$sb"
if _has "$sb" b1 && _has "$sb" c0 && [ -z "$(_rm_argv "$sb")" ] && grep -qx other-project "$sb/st/clusters"; then
  ok "no cluster of ours on the box: the other project's cluster, sidecar and controller are untouched"
else
  bad "kind-down with no cluster of ours still removed something of another project — docker rm argv: $(_rm_argv "$sb" | tr '\n' ';')"
fi
rm -rf "$sb"

# 17. The listing AFTER the delete cannot be answered: keep the controller (no positive "nothing is
#     left"), and still reach the file half — the stamped overlay is archived as in case 8.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"; echo 2 > "$sb/st/kind_get_fail_from"
printf 'c0 cloud-provider-kind -\n' > "$sb/st/containers"
_run_kd "$sb"
if _has "$sb" c0 && printf '%s' "$KD_OUT" | grep -q 'CANNOT ASK kind which clusters remain'; then
  ok "post-delete listing unanswerable: the controller is LEFT and the log says CANNOT ASK"
else
  bad "post-delete listing failed, yet the controller was removed or nothing said so"
fi
if [ ! -f "$sb/.env.state" ]; then
  ok "post-delete listing unanswerable: the file half still ran (the stamped overlay was archived)"
else
  bad "post-delete listing failed and the stamped overlay was left — the second listing leaked into the overlay decision"
fi
rm -rf "$sb"

# 18. `docker rm` fails (a sidecar vanished under a live controller): the file half is still reached.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\nother-project\n' "$OWN" > "$sb/st/clusters"; : > "$sb/st/rm_fails"
printf 'a1 kindccm-aaaa %s=%s\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" > "$sb/st/containers"
_run_kd "$sb"
if [ ! -f "$sb/.env.state" ] && printf '%s' "$KD_OUT" | grep -q 'kind teardown complete'; then
  ok "a failing docker rm does not stop kind-down before the overlay decision"
else
  bad "a failing docker rm aborted kind-down before the file half — output tail: $(printf '%s' "$KD_OUT" | tail -2 | tr '\n' ' ')"
fi
rm -rf "$sb"

# 18b. The CONTROLLER's docker rm fails (only our cluster on the host): the prune and the file half
#      still run. Arm 18 cannot see this: its fixture lists another cluster, so that rm is never reached.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"; : > "$sb/st/rm_fails"
printf 'a1 kindccm-aaaa %s=%s\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" > "$sb/st/containers"
_run_kd "$sb"
if [ ! -f "$sb/.env.state" ] && grep -q "label=${_LBL}=${OWN}" "$sb/st/calls" && printf '%s' "$KD_OUT" | grep -q 'kind teardown complete'; then
  ok "a failing docker rm of the controller does not stop kind-down before the prune and the overlay decision"
else
  bad "a failing docker rm of the controller aborted kind-down — output tail: $(printf '%s' "$KD_OUT" | tail -2 | tr '\n' ' ')"
fi
rm -rf "$sb"

# 20. The first listing cannot be answered, so the cluster is NOT deleted and may be running: its
#     sidecars must not be pruned (a live controller would recreate them, or its LoadBalancers break).
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"; echo 1 > "$sb/st/kind_get_fail_only"
printf 'a1 kindccm-aaaa %s=%s\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" > "$sb/st/containers"
_run_kd "$sb"
if _has "$sb" a1 && _has "$sb" c0 && [ -z "$(_rm_argv "$sb")" ] && printf '%s' "$KD_OUT" | grep -q 'NOT pruning'; then
  ok "cluster not confirmed gone: its sidecars and the controller are left, and the log says NOT pruning"
else
  bad "kind could not be asked, the cluster still exists, yet kind-down removed its sidecar or controller — docker rm argv: $(_rm_argv "$sb" | tr '\n' ';')"
fi
if [ -f "$sb/.env.state" ]; then
  ok "cluster not confirmed gone: the state overlay is left in place"
else
  bad "kind could not be asked, yet the state overlay was archived"
fi
rm -rf "$sb"

# 20b. NEITHER listing can be answered: the same rule holds — nothing of this cluster is pruned, and
#      the log gives the operator the command for when the cluster is known to be gone.
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"; echo 1 > "$sb/st/kind_get_fail_from"
printf 'a1 kindccm-aaaa %s=%s\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" > "$sb/st/containers"
_run_kd "$sb"
if _has "$sb" a1 && _has "$sb" c0 && [ -z "$(_rm_argv "$sb")" ] && printf '%s' "$KD_OUT" | grep -q 'remove them with:  docker rm -f a1'; then
  ok "kind unanswerable twice: nothing is removed, and the log prints the docker rm command for later"
else
  bad "kind could not be asked at all, yet kind-down removed something or gave no way forward — docker rm argv: $(_rm_argv "$sb" | tr '\n' ';')"
fi
rm -rf "$sb"

# 21. DRY_RUN=1 changes nothing and previews the REAL decision: with only our cluster on the host it
#     must print both removals (the delete it only printed must not make it say "leaving").
sb="$(_stateful_sandbox)"; OWN="$(_own_name "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"
printf 'a1 kindccm-aaaa %s=%s\nc0 cloud-provider-kind -\n' "$_LBL" "$OWN" > "$sb/st/containers"
DRY_RUN=1 _run_kd "$sb"
if _has "$sb" a1 && _has "$sb" c0 && grep -qx "$OWN" "$sb/st/clusters" && [ -f "$sb/.env.state" ] && [ -z "$(_rm_argv "$sb")" ]; then
  ok "DRY_RUN=1 removes nothing (cluster, sidecar, controller and overlay all still there)"
else
  bad "DRY_RUN=1 changed something — containers: $(tr '\n' ';' < "$sb/st/containers") docker rm argv: $(_rm_argv "$sb" | tr '\n' ';')"
fi
if printf '%s' "$KD_OUT" | grep -q 'DRY_RUN docker rm -f cloud-provider-kind' && printf '%s' "$KD_OUT" | grep -q 'DRY_RUN docker rm -f a1'; then
  ok "DRY_RUN=1 previews what the real run does: the controller and this cluster's sidecar would be removed"
else
  bad "DRY_RUN=1 does not preview the real decision — output: $(printf '%s' "$KD_OUT" | grep -i 'DRY_RUN\|leaving\|NOT pruning' | tr '\n' ';' | cut -c1-240)"
fi
rm -rf "$sb"

# 19. Never a graceful stop of the shared controller: on SIGTERM it removes the sidecars of EVERY
#     cluster it serves. Comments stripped first (the script explains this in a comment).
if sed -E 's@^[[:space:]]*#.*@@' "$KD" | grep -qE '(^|[;&|[:space:]])docker[[:space:]]+(stop|restart)([[:space:]]|$)'; then
  bad "kind-down uses docker stop/restart — a graceful stop makes cloud-provider-kind delete every cluster's sidecars"
else
  ok "kind-down never stops the controller gracefully (docker rm -f only)"
fi

[ "$fail" = 0 ] && { echo "test-kind-down-safety: OK"; exit 0; }
echo "test-kind-down-safety: FAILED" >&2; exit 1
