#!/usr/bin/env bash
# test-el-wait-ready.sh — el_wait_ready must WAIT for the EventListener Deployment to exist, then for
# its rollout, and tell "cannot tell" (Forbidden) apart from "not ready".
#
# The bug it replaces: `kubectl wait … pod -l eventlistener=apps` returns "no matching resources
# found" IMMEDIATELY when the controller has not created the pod yet, so the gate passed through at
# once and the first webhook was lost. The stub reproduces that answer for the CONTROL arm.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
rc=0; checks=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$1"; }
bad() { checks=$((checks+1)); rc=1; printf '  FAIL %s\n' "$1"; }

# STUB_MODE: late | forbidden | unauth | unreach | never | stuck | rforbid | zero | ok
cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
n=\$(cat "$T/gets" 2>/dev/null || echo 0)
case " \$* " in
  *" jsonpath="*)
    [ "\$STUB_MODE" = zero ] && { echo 0; exit 0; }; echo 1; exit 0 ;;
  *" get deploy "*)
    echo \$((n+1)) > "$T/gets"
    case "\$STUB_MODE" in
      forbidden) echo 'Error from server (Forbidden): deployments.apps "el-apps" is forbidden: User "t" cannot get resource' >&2; exit 1 ;;
      unauth)    echo 'error: You must be logged in to the server (Unauthorized)' >&2; exit 1 ;;
      unreach)   echo 'Unable to connect to the server: dial tcp 10.9.9.9:6443: connect: no route to host' >&2; exit 1 ;;
      never)     echo 'Error from server (NotFound): deployments.apps "el-apps" not found' >&2; exit 1 ;;
      late)      [ "\$n" -ge 2 ] && exit 0; echo 'Error from server (NotFound): deployments.apps "el-apps" not found' >&2; exit 1 ;;
      *)         exit 0 ;;
    esac ;;
  *" rollout status "*)
    for a in "\$@"; do case "\$a" in --timeout=*) echo "\${a#--timeout=}" > "$T/timeout" ;; esac; done
    case "\$STUB_MODE" in
      stuck)   echo 'error: timed out waiting for the condition' >&2; exit 1 ;;
      rforbid) echo 'Error from server (Forbidden): deployments.apps "el-apps" is forbidden: User "t" cannot watch resource' >&2; exit 1 ;;
    esac
    exit 0 ;;
  *" wait "*)   # what the OLD gate's kubectl answers before the pod exists (measured, kubectl 1.36)
    echo 'error: no matching resources found' >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/bin/kubectl"

run() {  # run <mode> <budget>  -> sets R (rc), G (get calls), W (reason)
  rm -f "$T/gets" "$T/timeout"
  R=0
  W="$( PATH="$T/bin:$PATH" STUB_MODE="$1" CI_NAMESPACE=ci EL_READY_TIMEOUT_SECONDS="$2" EL_POLL_SECONDS=1 \
        bash -c '. "$0"; el_wait_ready; r=$?; printf "%s" "$EL_WAIT_REASON"; exit $r' "$SCRIPT_DIR/lib/os.sh" )" || R=$?
  G="$(cat "$T/gets" 2>/dev/null || echo 0)"
}

echo "== STUB SELF-CHECK: the stub answers the old gate's 'kubectl wait -l' the way kubectl 1.36 did (not a proof about kubectl) =="
start=$SECONDS
PATH="$T/bin:$PATH" kubectl -n ci wait --for=condition=Ready pod -l eventlistener=apps --timeout=30s >/dev/null 2>&1; crc=$?
if [ "$crc" -ne 0 ] && [ $((SECONDS - start)) -lt 5 ]; then ok "control: the old gate returned rc=$crc immediately"
else bad "control: the stub does not reproduce the vacuous old gate (rc=$crc)"; fi

echo "== the Deployment appears late: the helper must WAIT for it, then succeed =="
run late 30
if [ "$R" = 0 ] && [ "$G" -ge 3 ]; then ok "waited through ${G} get(s), then ready"; else bad "late: rc=$R gets=$G reason=$W"; fi

echo "== Forbidden: cannot tell, rc 2, at once =="
run forbidden 30
if [ "$R" = 2 ] && [ "$G" = 1 ]; then ok "Forbidden -> rc 2 without waiting"; else bad "forbidden: rc=$R gets=$G reason=$W"; fi

echo "== never created: rc 1 after the budget, and the reason says so =="
run never 2
if [ "$R" = 1 ] && printf '%s' "$W" | grep -q 'never created'; then ok "absent Deployment -> rc 1 ($W)"; else bad "never: rc=$R reason=$W"; fi

echo "== created but the rollout never finishes: rc 1, 'not Ready' =="
run stuck 5
if [ "$R" = 1 ] && printf '%s' "$W" | grep -q 'not Ready'; then ok "stuck rollout -> rc 1 ($W)"; else bad "stuck: rc=$R reason=$W"; fi

echo "== Unauthorized: rc 1 at once, and the reason names the credential, not Tekton =="
run unauth 30
if [ "$R" = 1 ] && [ "$G" = 1 ] && printf '%s' "$W" | grep -q UNAUTHORIZED && ! printf '%s' "$W" | grep -q Tekton
then ok "Unauthorized -> rc 1 after 1 get ($W)"; else bad "unauth: rc=$R gets=$G reason=$W"; fi

echo "== unreachable until the budget: the reason says unreachable, not 'never created' =="
run unreach 2
if [ "$R" = 1 ] && printf '%s' "$W" | grep -q 'no route to host' && ! printf '%s' "$W" | grep -q 'never created'
then ok "unreachable -> rc 1, reason names the network"; else bad "unreach: rc=$R reason=$W"; fi

echo "== Forbidden during the rollout: rc 2 =="
run rforbid 30
if [ "$R" = 2 ]; then ok "Forbidden on rollout status -> rc 2"; else bad "rforbid: rc=$R reason=$W"; fi

echo "== the remaining budget reaches rollout status --timeout =="
run ok 40
to="$(cat "$T/timeout" 2>/dev/null || true)"
if [ "$R" = 0 ] && [ -n "$to" ] && [ "${to%s}" -le 40 ] && [ "${to%s}" -ge 1 ]; then ok "rollout status got --timeout=${to} (budget 40s)"
else bad "timeout passing: rc=$R timeout='${to}'"; fi

echo "== a Deployment scaled to 0 is not 'ready' even though rollout status succeeds =="
run zero 30
if [ "$R" = 1 ] && printf '%s' "$W" | grep -q 'no Ready pod'; then ok "readyReplicas 0 -> rc 1"; else bad "zero: rc=$R reason=$W"; fi

echo "test-el-wait-ready: ${checks} checks, rc=$rc"
exit "$rc"
