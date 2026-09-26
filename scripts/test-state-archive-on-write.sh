#!/usr/bin/env bash
# shellcheck disable=SC2016  # every single-quoted snippet runs in a CHILD bash, where its $vars expand
# test-state-archive-on-write.sh — a write never lands in a sink stamped for another cluster (B722).
#
# THE LOOP THIS KILLS: state_check refused to SOURCE a sink stamped for another cluster, but state_set
# still WROTE into it. So an installer's INGRESS_LB_IP for the cluster you selected landed in the other
# cluster's file, and the next `make creds` refused it again. Measured by the idea round: after
# `state_set INGRESS_LB_IP ...` the sink still carried the foreign stamp and creds printed
# `<needs ingress>` on 10 lines.
#
# Offline: a kubeconfig is only PARSED (state_kubeconfig_server never dials), and every sink is a
# throwaway VKS_STATE_FILE.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

cat > "$T/kc" <<'KC'
apiVersion: v1
kind: Config
current-context: live
clusters:
- name: live
  cluster: {server: 'https://127.0.0.1:1'}
contexts:
- name: live
  context: {cluster: live, user: live}
users:
- name: live
  user: {token: not-a-real-token}
KC
FOREIGN='VKS_STATE_KIND=1
VKS_STATE_SERVER=https://127.0.0.1:44444
VKS_STATE_CONTEXT=kind-elsewhere
INGRESS_LB_IP=10.9.9.9
HARBOR_PASSWORD=theirs'

# sh <sink-content-or-NONE> <script> — load_env (as every product script does), then run <script>.
sh_() {
  rm -rf "$T/s"; mkdir -p "$T/s"
  [ "$1" = NONE ] || printf '%s\n' "$1" > "$T/s/.env.state"
  ( cd "$T" && env -i HOME="$T" PATH="$PATH" SKIP_DOTENV=1 VKS_STATE_FILE="$T/s/.env.state" ${3:+KUBECONFIG="$3"} \
      bash -c '. "$1/lib/os.sh"; load_env >/dev/null 2>&1; '"$2" _ "$SCRIPT_DIR" 2>&1 )
}
archives() { find "$T/s" -maxdepth 1 -name '.env.state.stale-*' | wc -l | tr -d ' '; }

echo "== a REFUSED sink: the write archives it and lands in a fresh one stamped for the live cluster =="
o="$(sh_ "$FOREIGN" 'echo "mismatch=${_VKS_STATE_MISMATCH:-}"; state_set INGRESS_LB_IP 192.0.2.7' "$T/kc")"
case "$o" in *mismatch=1*) : ;; *) bad "harness" "load_env did not refuse the sink, so this case measures nothing: $o" ;; esac
if [ "$(archives)" = 1 ] && grep -q '^VKS_STATE_SERVER=https://127.0.0.1:44444' "$T"/s/.env.state.stale-* \
   && grep -q 'HARBOR_PASSWORD=theirs' "$T"/s/.env.state.stale-*; then ok "the foreign sink is ARCHIVED, whole (its stamp and its password kept)"
else bad "foreign sink archived" "archives=$(archives) $o"; fi
if ! grep -q '^VKS_STATE_' "$T/s/.env.state" && grep -q '192.0.2.7' "$T/s/.env.state" \
   && ! grep -q 'theirs' "$T/s/.env.state"; then ok "the new sink is UNSTAMPED (real-lab policy, B120) and holds only our value"
else bad "new sink" "$(cat "$T/s/.env.state" 2>&1)"; fi
if [ "$(stat -c %a "$T/s/.env.state")" = 600 ]; then ok "the new sink is 0600"; else bad "mode" "$(stat -c %a "$T/s/.env.state")"; fi

echo "== and the NEXT process sources it (the loop is broken) =="
o="$( cd "$T" && env -i HOME="$T" PATH="$PATH" SKIP_DOTENV=1 VKS_STATE_FILE="$T/s/.env.state" KUBECONFIG="$T/kc" \
        bash -c '. "$1/lib/os.sh"; load_env >/dev/null 2>&1; echo "sourced=${_VKS_STATE_SOURCED:-} ip=${INGRESS_LB_IP:-}"' _ "$SCRIPT_DIR" )"
case "$o" in *"sourced=1 ip=192.0.2.7"*) ok "the next load_env sources the new sink: $o" ;; *) bad "next load" "$o" ;; esac

echo "== a second write in the same process does not archive the sink it just created =="
sh_ "$FOREIGN" 'state_set A 1; state_set B 2' "$T/kc" >/dev/null
if [ "$(archives)" = 1 ] && grep -q '^A=' "$T/s/.env.state" && grep -q '^B=' "$T/s/.env.state"; then ok "one archive, both keys in the new sink"
else bad "second write" "archives=$(archives)"; fi

echo "== state_unset after the swap proceeds (the flag was cleared) =="
sh_ "$FOREIGN" 'state_set A 1; state_set B 2; state_unset A' "$T/kc" >/dev/null
if ! grep -q '^A=' "$T/s/.env.state" && grep -q '^B=' "$T/s/.env.state"; then ok "state_unset removed its key from the new sink"
else bad "state_unset after swap" "$(cat "$T/s/.env.state")"; fi

echo "== scenario-1 alternates Supervisor -> guest: ONE archive, every key in ONE sink =="
# Implementation round, measured: a STAMPED fresh sink re-armed the refusal against the other server,
# so a 5-step sup/sup/guest/sup/guest walk left 4 archives and stranded HARBOR_PASSWORD in one of them.
sed 's#127.0.0.1:1#10.0.0.2:6443#; s#name: live#name: guest#g; s#current-context: live#current-context: guest#; s#cluster: live#cluster: guest#; s#user: live#user: guest#' "$T/kc" > "$T/guest"
sed 's#127.0.0.1:1#10.0.0.1:6443#' "$T/kc" > "$T/sup"
rm -rf "$T/s"; mkdir -p "$T/s"; printf '%s\n' "$FOREIGN" > "$T/s/.env.state"
step() { ( cd "$T" && env -i HOME="$T" PATH="$PATH" SKIP_DOTENV=1 VKS_STATE_FILE="$T/s/.env.state" KUBECONFIG="$1" \
             bash -c '. "$1/lib/os.sh"; load_env >/dev/null 2>&1; state_set "$2" "$3"' _ "$SCRIPT_DIR" "$2" "$3" >/dev/null 2>&1 ); }
step "$T/sup" ARGOCD_KUBECONFIG /k/sup; step "$T/sup" HARBOR_PASSWORD labadmin; step "$T/guest" GITEA_LB_IP 10.1.1.1
step "$T/sup" ARGOCD_SERVER_SOURCE discovered; step "$T/guest" INGRESS_LB_IP 10.1.1.2
n_keys="$(grep -cE '^(ARGOCD_KUBECONFIG|HARBOR_PASSWORD|GITEA_LB_IP|ARGOCD_SERVER_SOURCE|INGRESS_LB_IP)=' "$T/s/.env.state" || true)"
if [ "$(archives)" = 1 ] && [ "$n_keys" = 5 ]; then ok "5 alternating writes: 1 archive, all 5 keys in the one sink"
else bad "alternation" "archives=$(archives) keys-in-sink=${n_keys}"; fi

echo "== states that must NOT archive =="
sh_ NONE 'state_set X 1' "$T/kc" >/dev/null
if [ "$(archives)" = 0 ] && grep -q '^X=' "$T/s/.env.state"; then ok "a clean box: no sink -> the write simply lands, nothing archived"; else bad "clean box" "archives=$(archives)"; fi
sh_ 'INGRESS_LB_IP=10.9.9.9' 'state_set X 1' "$T/kc" >/dev/null
if [ "$(archives)" = 0 ] && grep -q '^INGRESS_LB_IP=10.9.9.9' "$T/s/.env.state"; then ok "an UNSTAMPED sink (the real-lab path) is never archived"; else bad "unstamped" "archives=$(archives)"; fi
sh_ 'VKS_STATE_SERVER=https://127.0.0.1:1
INGRESS_LB_IP=10.9.9.9' 'state_set X 1' "$T/kc" >/dev/null
if [ "$(archives)" = 0 ]; then ok "a sink stamped for the SAME cluster is written in place"; else bad "same cluster" "archives=$(archives)"; fi
sh_ "$FOREIGN" 'state_set X 1' "" >/dev/null
if [ "$(archives)" = 0 ] && grep -q '^X=' "$T/s/.env.state"; then ok "no explicit KUBECONFIG -> no mismatch -> written in place (unchanged behaviour)"; else bad "no selection" "archives=$(archives)"; fi
( rm -rf "$T/s"; mkdir -p "$T/s"; printf '%s\n' "$FOREIGN" > "$T/s/.env.state"
  cd "$T" && env -i HOME="$T" PATH="$PATH" VKS_STATE_FILE="$T/s/.env.state" KUBECONFIG="$T/kc" \
    bash -c '. "$1/lib/os.sh"; state_set X 1' _ "$SCRIPT_DIR" >/dev/null 2>&1 )
if [ "$(archives)" = 0 ]; then ok "a process that never ran load_env (flag unset) is unchanged"; else bad "no load_env" "archives=$(archives)"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
