#!/usr/bin/env bash
# test-vks-package-adoption.sh — B489. `vks-package.sh install` used to `kubectl apply` a
# PackageInstall AND a CLUSTER-SCOPED cluster-admin ClusterRoleBinding with NO pre-apply read, so
# an object of the same derived name created by anyone else was silently ADOPTED and overwritten;
# `uninstall` then deleted it BY NAME. Two destructive acts from one lossy derivation
# (`cut -d. -f1`, so any two refNames sharing a first DNS label collide on a cluster-scoped object).
#
# ⚠️ THE GATE IS ON DIVERGENCE, NOT EXISTENCE, and C2 below is the case that proves it. An
# existence gate was REFUTED by the design round: install `die`s AFTER the apply (the reconcile
# timeout), so the commonest reason to re-run leaves all three objects behind — an existence gate
# would fire on the operator's OWN retry and train them to type CONFIRM=yes reflexively. Without C2
# a "fix" that blocks every re-run would pass this file while being unusable.
#
# ⚠️ R5/R6 are the ones that matter most: the pre-existing precedent idiom
# `if _x="$(kubectl get ... 2>/dev/null)"` cannot tell ABSENT from Forbidden from unreachable, and
# here it fails open into GRANTING cluster-admin. A namespaced tenant is exactly who hits it.
#
# Offline by construction — kubectl is a STUB, so this needs no lab and cannot be flaky.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); return 0; }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); return 0; }

STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
KC="$STUB/kc"; printf 'apiVersion: v1\nkind: Config\n' > "$KC"
PKG=istio.kubernetes.vmware.com

# The stub's ONLY variables are what `get pkgi -o json` returns and how it fails. Everything else
# is fixed: a GUEST cluster (no vmoperator group) offering two versions of the package.
mk_kubectl() { # mk_kubectl <pkgi-json-file|'notfound'|'forbidden'|'unreachable'|'malformed'>
  cat > "$STUB/pkgi.mode" <<< "$1"
  : > "$STUB/calls.log"
  cat > "$STUB/kubectl" <<'EOF'
#!/usr/bin/env bash
mode="$(cat "${STUB_DIR}/pkgi.mode")"
# EVERY invocation is recorded, so a case can assert a call WAS MADE. A purely negative assertion
# (`! grep -q 'NOT deleting'`) passed on a script that FATAL'd at startup AND on one whose delete
# had been removed entirely — measured by an adversary mutating the cleanup away: 12/12 still green.
printf '%s\n' "$*" >> "${STUB_DIR}/calls.log"
case " $* " in
  *" version "*)   exit 0 ;;
  *"vmoperator.vmware.com"*) exit 0 ;;                 # a GUEST prints nothing and exits 0
  *" config "*)    printf 'stub-context\n'; exit 0 ;;
  # ⚠️ `*" get "*" packages "*` CANNOT MATCH under `case " $* "`: `" get "` consumes the space
  # BEFORE `packages`, so `" packages "` has nothing left to match. (That exact dead arm is
  # test-vks-package-guard.sh's, flagged in B489.) Match the pair as ONE token instead.
  *"get packages"*)
      cat <<'J'
{"items":[
 {"spec":{"refName":"istio.kubernetes.vmware.com","version":"1.28.9+vmware.1-vks.1"}},
 {"spec":{"refName":"istio.kubernetes.vmware.com","version":"1.30.2+vmware.1-vks.1"}}
]}
J
      exit 0 ;;
  *"get pkgi"*|*"get packageinstall"*)
      # ⚠️ ARM ORDER. `friendlyDescription` IS a jsonpath, so a generic `*"jsonpath"*` arm placed
      # first swallows the POST-APPLY reconcile poll and feeds it the owner label — which is what
      # the first version of this stub did, turning all four GREEN controls red while the product
      # was fine (the tell was `msg=  vks-airgap-cicd` printed as a reconcile description). The
      # reconcile poll is a DIFFERENT question from the guard's read, so it is answered FIRST and
      # is independent of $mode: every case here reaches the apply only after the guard allowed it.
      case " $* " in *"friendlyDescription"*) printf 'Reconcile succeeded\n'; exit 0 ;; esac
      case "$mode" in
        notfound)    printf 'Error from server (NotFound): packageinstalls.packaging.carvel.dev "istio" not found\n' >&2; exit 1 ;;
        malformed)   printf 'E0826 throttling request took 1s, request: GET:https://...\n<html>gateway</html>\n'; exit 0 ;;
        forbidden)   printf 'Error from server (Forbidden): packageinstalls.packaging.carvel.dev is forbidden: User "t" cannot get resource "packageinstalls"\n' >&2; exit 1 ;;
        unreachable) printf 'Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout\n' >&2; exit 1 ;;
        *)
          # A jsonpath read (uninstall's owner probe) vs a -o json read (install's guard).
          case " $* " in
            *"jsonpath"*) jq -r '.metadata.labels["vks-airgap-cicd.local/owned-by"] // ""' "$mode"; exit 0 ;;
            *) cat "$mode"; exit 0 ;;
          esac ;;
      esac ;;
  *"get clusterrolebinding"*|*"get sa"*|*"get secret"*)
      if [ -n "${OWNER_LABEL_FILE:-}" ] && [ -s "${OWNER_LABEL_FILE:-/nonexistent}" ]; then
        cat "$OWNER_LABEL_FILE"; exit 0
      fi
      printf 'Error from server (NotFound): the object was not found\n' >&2; exit 1 ;;
  *" label "*"--local"*) cat; exit 0 ;;
  *" delete "*)  printf '%s\n' "deleted (stub)"; exit 0 ;;
  *" apply "*)   cat > "${STUB_DIR}/applied.yaml"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUB/kubectl"
}

pkgi() { # pkgi <refName> <version> <owner-label-or-empty>  -> path to a json file
  local f; f="$(mktemp -p "$STUB")"
  jq -n --arg r "$1" --arg v "$2" --arg o "$3" \
    '{metadata:{name:"istio",namespace:"vmware-system-tkg",
      labels:( if $o=="" then {} else {"vks-airgap-cicd.local/owned-by":$o} end)},
      spec:{serviceAccountName:"istio-pkg-sa",
            packageRef:{refName:$r,versionSelection:{constraints:$v}}}}' > "$f"
  printf '%s' "$f"
}

run() { STUB_DIR="$STUB" PATH="$STUB:$PATH" KUBECONFIG="$KC" SKIP_DOTENV=1 \
        VKS_PACKAGE_NAMESPACE=vmware-system-tkg VKS_PACKAGE_WAIT_SECONDS=20 \
        timeout 60 ./scripts/vks-package.sh "$@" 2>&1; }

VER=1.30.2+vmware.1-vks.1
OLD=1.28.9+vmware.1-vks.1

echo "── RED: the guard must REFUSE ─────────────────────────────────────────────"

# R1 — a FOREIGN owner is decisive on its own.
mk_kubectl "$(pkgi "$PKG" "$VER" some-other-tool)"
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -qi "owned by 'some-other-tool'" <<< "$out"; then
  ok "R1 foreign owned-by -> REFUSED"
else bad "R1 foreign owned-by was ADOPTED (rc=$rc): $(tail -2 <<< "$out")"; fi

# R2 — a different refName under the SAME derived name (`cut -d. -f1` collision).
mk_kubectl "$(pkgi istio.example.com "$VER" '')"
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'istio.example.com' <<< "$out"; then
  ok "R2 different refName, same derived name -> REFUSED"
else bad "R2 refName collision was ADOPTED (rc=$rc): $(tail -2 <<< "$out")"; fi

# R3 — same package, DIFFERENT version, no consent. This is the downgrade-over-a-live-mesh case.
mk_kubectl "$(pkgi "$PKG" "$OLD" vks-airgap-cicd)"
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'CONFIRM=yes' <<< "$out"; then
  ok "R3 version change without CONFIRM -> REFUSED"
else bad "R3 version change proceeded silently (rc=$rc): $(tail -2 <<< "$out")"; fi

# R5 — Forbidden MUST NOT be read as absent. This is the fail-open that grants cluster-admin.
mk_kubectl forbidden
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'UNKNOWN whether one' <<< "$out"; then
  ok "R5 Forbidden -> REFUSED (does not fail open)"
else bad "R5 Forbidden FAILED OPEN (rc=$rc): $(tail -2 <<< "$out")"; fi

# R6 — the same for an unreachable API server.
mk_kubectl unreachable
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'UNKNOWN whether one' <<< "$out"; then
  ok "R6 unreachable -> REFUSED (does not fail open)"
else bad "R6 unreachable FAILED OPEN (rc=$rc): $(tail -2 <<< "$out")"; fi

# R4 — a read that exits 0 with text jq cannot parse (a proxy page, a throttling banner) must NOT
# be handed to jq and silently yield empty fields that then compare "equal".
mk_kubectl malformed
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'jq cannot parse' <<< "$out"; then
  ok "R4 unparseable read -> REFUSED, and names what it saw"
else bad "R4 unparseable read was accepted (rc=$rc): $(tail -2 <<< "$out")"; fi

echo "── GREEN controls: the guard must NOT block these ─────────────────────────"

# C1 — provably absent is a fresh install.
mk_kubectl notfound
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "C1 NotFound -> proceeds (fresh install)"
else bad "C1 a fresh install was BLOCKED (rc=$rc): $(tail -3 <<< "$out")"; fi

# C2 — THE LOAD-BEARING CONTROL. Identical + ours must proceed with NO gate and NO adoption warning:
# that is idempotency, and it is the operator's retry after the post-apply reconcile timeout.
mk_kubectl "$(pkgi "$PKG" "$VER" vks-airgap-cicd)"
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'adopting an existing' <<< "$out"; then
  ok "C2 identical + ours -> proceeds SILENTLY (the retry still works)"
else bad "C2 the retry was blocked or noisy (rc=$rc): $(tail -3 <<< "$out")"; fi

# C3 — identical but UNLABELLED: adopt (so pre-label installs keep working) and SAY SO.
mk_kubectl "$(pkgi "$PKG" "$VER" '')"
out="$(PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'adopting an existing, UNLABELLED' <<< "$out"; then
  ok "C3 identical + unlabelled -> adopts, and says so"
else bad "C3 unlabelled adoption was silent or blocked (rc=$rc): $(tail -3 <<< "$out")"; fi

# C4 — an explicit version change WITH consent proceeds.
mk_kubectl "$(pkgi "$PKG" "$OLD" vks-airgap-cicd)"
out="$(CONFIRM=yes PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if [ "$rc" -eq 0 ] && grep -q "changing ${PKG} from ${OLD}" <<< "$out"; then
  ok "C4 version change WITH CONFIRM=yes -> proceeds, and says what it changed"
else bad "C4 consented version change was blocked (rc=$rc): $(tail -3 <<< "$out")"; fi

# C5 — the three objects we create must carry the ownership label, or the uninstall half below has
# nothing to key on and would refuse to clean up after us.
if [ -s "$STUB/applied.yaml" ] \
   && [ "$(grep -c 'vks-airgap-cicd.local/owned-by: vks-airgap-cicd' "$STUB/applied.yaml")" -eq 3 ]; then
  ok "C5 all THREE applied objects carry owned-by (SA, ClusterRoleBinding, PackageInstall)"
else bad "C5 expected 3 owned-by labels in the applied manifest, got $(grep -c 'owned-by' "$STUB/applied.yaml" 2>/dev/null || echo 0)"; fi

echo "── uninstall: never delete a cluster-scoped object BY NAME ────────────────"

# R7 — a ClusterRoleBinding that is NOT ours must survive, loudly.
mk_kubectl "$(pkgi "$PKG" "$VER" vks-airgap-cicd)"
printf 'some-other-tool\n' > "$STUB/owner.txt"
out="$(OWNER_LABEL_FILE="$STUB/owner.txt" CONFIRM=yes run uninstall "$PKG")"; rc=$?
if grep -q 'NOT deleting clusterrolebinding/istio-pkg-sa-cluster-admin' <<< "$out"; then
  ok "R7 a foreign cluster-admin ClusterRoleBinding is NOT deleted"
else bad "R7 deleted (or ignored) a foreign cluster-scoped binding: $(tail -3 <<< "$out")"; fi

# C6 — ...and one that IS ours is still cleaned up, or we leave cluster-admin behind.
# ⚠️ POSITIVE ASSERTION, deliberately. This case used to be `! grep -q 'NOT deleting'`, and an
# adversary measured that pure negative passing on BOTH a script that FATAL'd at startup and one
# whose delete-when-ours had been deleted outright (12/12 green while cluster-admin was abandoned
# on every uninstall). Assert the call was ISSUED.
mk_kubectl "$(pkgi "$PKG" "$VER" vks-airgap-cicd)"
printf 'vks-airgap-cicd\n' > "$STUB/owner.txt"
out="$(OWNER_LABEL_FILE="$STUB/owner.txt" CONFIRM=yes run uninstall "$PKG")"; rc=$?
if grep -qE 'delete clusterrolebinding istio-pkg-sa-cluster-admin' "$STUB/calls.log"; then
  ok "C6 our OWN ClusterRoleBinding delete was ISSUED (asserted on the call log, not on silence)"
else bad "C6 no delete was issued for our own cluster-admin binding — it would be abandoned"; fi

# R8 — THE CRITICAL ONE. A FOREIGN-owned PackageInstall must not be deleted. It owns everything the
# package deployed, so it is the expensive object; the first version of this change protected the
# three subordinates and destroyed this one BY NAME, one command after install had REFUSED it.
mk_kubectl "$(pkgi "$PKG" "$VER" some-other-tool)"
out="$(CONFIRM=yes run uninstall "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "owned by 'some-other-tool'" <<< "$out"; then
  ok "R8 a FOREIGN PackageInstall is NOT deleted"
else bad "R8 deleted a foreign PackageInstall (rc=$rc): $(tail -2 <<< "$out")"; fi
if grep -qE 'delete pkgi istio' "$STUB/calls.log"; then
  bad "R8 the delete was ISSUED anyway — the refusal came too late"
else ok "R8 no delete call was issued at all"; fi

# R9 — an unreadable pkgi must not be reported as "not installed ... nothing to do" with rc=0.
mk_kubectl forbidden
out="$(CONFIRM=yes run uninstall "$PKG")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'UNKNOWN whether it is' <<< "$out"; then
  ok "R9 Forbidden on uninstall -> REFUSED (not 'nothing to do')"
else bad "R9 Forbidden read as not-installed, rc=$rc: $(tail -2 <<< "$out")"; fi

# C7 — the values Secret must be created WITH the ownership label, or uninstall abandons an object
# we made ourselves and prints a leftover warning on every real run (43-install-istio-package.sh
# always passes PKG_VALUES).
mk_kubectl notfound
vals="$(mktemp -p "$STUB")"; printf 'a: b\n' > "$vals"
out="$(PKG_VALUES="$vals" PKG_VERSION="$VER" run install "$PKG")"; rc=$?
if grep -qE 'label --local .*vks-airgap-cicd\.local/owned-by=vks-airgap-cicd' "$STUB/calls.log"; then
  ok "C7 the values Secret is labelled at creation"
else bad "C7 the values Secret is created UNLABELLED — uninstall would abandon it"; fi

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
