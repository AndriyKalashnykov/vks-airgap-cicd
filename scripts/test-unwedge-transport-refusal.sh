#!/usr/bin/env bash
# test-unwedge-transport-refusal.sh — B112.
#
# `unwedge-supervisor-service.sh` DELETES. Its reads used to be `kubectl … 2>/dev/null || true`,
# which made "this kind has no objects" and "we could not ask" the SAME empty string. On a transport
# failure every kind was skipped, nothing was deleted, and the script printed "deleted." and told the
# operator to wait 15 minutes for a kapp retry that could not help. That is a SUCCESS CLAIM OVER A
# NO-OP in a script whose only purpose is to delete.
#
# THIS RUNS THE SHIPPED SCRIPT, never a transcription of its logic. It is `cp`-ed into a temp
# SCRIPT_DIR at test time, so it cannot drift from what ships: the real scripts/lib is copied in
# (we want the REAL classify_kube_failure) and only lib/vcenter.sh is overwritten, because the vCenter
# half is not what is under test and cannot be reached offline.
#
# RED-PROVEN: restore `2>/dev/null || true` on either read and cases 1/2/4 fail.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# ── build a sandbox that runs the REAL script ────────────────────────────────────────────────
mk_sandbox() {                     # mk_sandbox <kubectl-stub-body>  -> echoes the sandbox dir
  local body="$1" d; d="$(mktemp -d)"
  mkdir -p "$d/lib" "$d/bin"
  cp "$REPO_ROOT/scripts/unwedge-supervisor-service.sh" "$d/"
  # The WHOLE lib, copied at test time: os.sh sources its siblings (state.sh, tls.sh …) relative to
  # its own dir, so symlinking os.sh alone leaves them missing. A copy taken per run cannot drift.
  cp -r "$REPO_ROOT/scripts/lib/." "$d/lib/"

  # vCenter stub: get past both gates so the kubectl half is what is exercised.
  cat > "$d/lib/vcenter.sh" <<'VC'
vc_logout() { :; }
vc_login()  { :; }
vc_supervisor_id() { printf 'domain-c9'; }
vc_ss_list() { printf 'DELETING\targocd.vmware.com\tArgoCD\n'; }
vc_api() { printf '{"messages":[{"severity":"ERROR","details":{"args":["Deleting","kapp timed out"]}}]}'; }
VC

  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$d/bin/kubectl"
  chmod +x "$d/bin/kubectl"
  printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$d/kubeconfig"
  printf '%s' "$d"
}

# `out="$(run_it ...)"` would be a SUBSHELL, so an RC assigned inside it is DISCARDED — the exact
# trap this repo hit with _TKR_RC. Write the output to a FILE and read the rc in the CURRENT shell.
run_it() {                          # run_it <sandbox> -> sets OUT (text) and RC (real exit status)
  local d="$1" f; f="$(mktemp)"
  PATH="$d/bin:$PATH" \
  SKIP_DOTENV=1 KUBECONFIG="$d/kubeconfig" CONFIRM=yes SERVICE=argocd.vmware.com \
    bash "$d/unwedge-supervisor-service.sh" > "$f" 2>&1
  RC=$?
  OUT="$(cat "$f")"; rm -f "$f"
}

# The `get ns -o name` call (GATE 2) must always succeed, or we never reach the code under test.
NS_OK='case "$*" in *"get ns -o name"*) echo namespace/svc-argocd-1a2b3; exit 0;; esac'

# ── 1. transport failure on the PRE-CONFIRM LISTING → refuse BEFORE asking ───────────────────
d="$(mk_sandbox "$NS_OK"'
case "$*" in
  *"get deploy,statefulset"*) echo "Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout" >&2; exit 1;;
esac
exit 0')"
run_it "$d"; out="$OUT"
if [ "$RC" -eq 0 ]; then
  bad "1. an unreadable namespace must NOT reach the delete loop" "exited 0"
elif ! printf '%s' "$out" | grep -q 'refusing to ask you to confirm'; then
  bad "1. an unreadable namespace must NOT reach the delete loop" "no refusal text: $(printf '%s' "$out" | tail -2)"
elif printf '%s' "$out" | grep -qi 'deleted'; then
  bad "1. an unreadable namespace must NOT reach the delete loop" "still claimed a deletion"
else
  ok "1. a transport failure on the listing REFUSES before the operator confirms"
fi
rm -rf "$d"

# ── 2. transport failure INSIDE the delete loop → die, do not report success ─────────────────
d="$(mk_sandbox "$NS_OK"'
case "$*" in
  *"get deploy,statefulset"*) echo "no objects"; exit 0;;
  *"get deployment -o name"*) echo "Unable to connect to the server: i/o timeout" >&2; exit 1;;
esac
exit 0')"
run_it "$d"; out="$OUT"
if [ "$RC" -eq 0 ]; then
  bad "2. a transport failure mid-loop must abort" "exited 0 — this is the no-op-reported-as-success bug"
elif ! printf '%s' "$out" | grep -q 'NOTHING further will be deleted'; then
  bad "2. a transport failure mid-loop must abort" "no abort text: $(printf '%s' "$out" | tail -2)"
else
  ok "2. a transport failure mid-loop ABORTS and says nothing further was deleted"
fi
rm -rf "$d"

# ── 3. genuinely empty (readable) → say so, do NOT claim a deletion ──────────────────────────
d="$(mk_sandbox "$NS_OK"'
case "$*" in
  *"get deploy,statefulset"*) echo "No resources found"; exit 0;;
  *"-o name"*) exit 0;;
esac
exit 0')"
run_it "$d"; out="$OUT"
if printf '%s' "$out" | grep -qE 'deleted [0-9]+ object'; then
  bad "3. an empty-but-readable namespace must not claim a deletion" "claimed a count"
elif ! printf '%s' "$out" | grep -q 'nothing was deleted'; then
  bad "3. an empty-but-readable namespace must not claim a deletion" "did not say nothing was deleted"
else
  ok "3. empty-but-READABLE is reported as 'nothing was deleted', not as success"
fi
rm -rf "$d"

# ── 4. objects present → the COUNT is right (the subshell trap) ──────────────────────────────
# `printf | while read` is a SUBSHELL: the counter would never survive the loop and this would
# print 0. Two objects across two kinds proves the herestring form.
d="$(mk_sandbox "$NS_OK"'
case "$*" in
  *"get deploy,statefulset"*) echo "deployment.apps/argocd-server   1/1"; exit 0;;
  *"get deployment -o name"*) echo "deployment.apps/argocd-server"; exit 0;;
  *"get service -o name"*)    echo "service/argocd-server"; exit 0;;
  *"-o name"*) exit 0;;
  *delete*) echo "deleted"; exit 0;;
esac
exit 0')"
run_it "$d"; out="$OUT"
if ! printf '%s' "$out" | grep -q 'deleted 2 object'; then
  bad "4. the deleted COUNT must survive the loop" "expected 'deleted 2 object(s)', got: $(printf '%s' "$out" | grep -i deleted | tail -2)"
else
  ok "4. the deleted count is accurate (2) — the loop is not a subshell"
fi
rm -rf "$d"

printf '\ntest-unwedge-transport-refusal: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-unwedge-transport-refusal: OK\n'
