#!/usr/bin/env bash
# ============================================================================
# mac-lab-tunnel.sh — TEST HARNESS: let a macOS jump box reach a lab that only THIS box can reach.
#
#   scripts/mac-lab-tunnel.sh up     [user@mac]   # derive endpoints, then alias + forward + redirect
#   scripts/mac-lab-tunnel.sh status [user@mac]
#   scripts/mac-lab-tunnel.sh down   [user@mac]   # remove exactly what `up` added
#
# This is NOT a product path. It exists so the README "Tested platforms" macOS row can carry lab
# evidence, and it must be labelled "via a tunnel harness" wherever that evidence is quoted. What a
# tunnel does NOT test: real DNS (the Mac gets an /etc/hosts block), routing/firewall between a jump
# box and the lab, the source address the lab sees (always this box), MTU, and one TCP connection
# carrying everything (a drop kills all of it).
#
# DESIGN (idea-round adversary 2026-09-25; option "per-IP reverse forwards"):
#   * every tool sees the REAL destination IP, so TLS SANs, the argocd gRPC dialer and openssl work
#     unchanged -- a SOCKS proxy was refuted: four code paths ignore it.
#   * the endpoint list is DERIVED here on every `up` (VIPs move between runs), never typed.
#   * MEASURED on the Mac (macOS 26.6.2, OpenSSH 10.3): sshd binds a remote forward as the login user,
#     so a port below 1024 is REFUSED ("remote port forwarding failed for listen port 443"). So a low
#     port P is forwarded to P+10000 and a pf rdr on lo0 redirects VIP:P -> VIP:P+10000. Verified:
#     name-verified TLS to Harbor through that chain returned HTTP 200.
#   * sshd needs `GatewayPorts clientspecified` (the Mac's default is no); a drop-in sorting FIRST
#     sets it (sshd keeps the first value). macOS sshd is inetd-launched: no restart needed.
#   * everything added on the Mac is recorded in ~/.vks-lab-tunnel so `down` removes exactly that.
# Initiated from THIS box because the Mac cannot reach it (NAT).
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

ACTION="${1:-status}"
MAC="${2:-${MAC_TUNNEL_HOST:?set MAC_TUNNEL_HOST=user@mac or pass it as the 2nd argument}}"
KEY="${MAC_TUNNEL_KEY:-$HOME/.ssh/id_ed25519}"
SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -i "$KEY")
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vks-lab-tunnel"
PIDFILE="$STATE_DIR/ssh.pid"
mkdir -p "$STATE_DIR"

mac() { ssh -n "${SSHO[@]}" "$MAC" "$@"; }
hi_port() { if [ "$1" -lt 1024 ]; then echo $(( $1 + 10000 )); else echo "$1"; fi; }

# ── derive: "IP PORT" lines, and "IP NAME" lines for /etc/hosts ─────────────────────────────
derive() {
  local ip h
  : > "$STATE_DIR/endpoints"; : > "$STATE_DIR/hosts"
  add() { printf '%s %s\n' "$1" "$2" >> "$STATE_DIR/endpoints"; }
  name() { printf '%s %s\n' "$1" "$2" >> "$STATE_DIR/hosts"; }
  resolve() { getent hosts "$1" | awk '{print $1; exit}' || true; }
  for h in "${VCENTER_HOST:-}" "${HARBOR_URL:-}"; do
    [ -n "$h" ] || continue
    ip="$(resolve "$h")"; [ -n "$ip" ] || die "cannot resolve $h on this box -- the harness would forward nothing for it"
    add "$ip" 443; name "$ip" "$h"
  done
  [ -n "${SUPERVISOR_HOST:-}" ] && add "$SUPERVISOR_HOST" 443
  [ -n "${ARGOCD_SERVER:-}" ] && add "${ARGOCD_SERVER%%:*}" 443
  # the guest API server, from the kubeconfig the rest of the flow uses
  local srv; srv="$(kubectl config view --kubeconfig "${KUBECONFIG:?}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  srv="${srv#https://}"
  [ -n "$srv" ] && add "${srv%%:*}" "${srv##*:}"
  # every LoadBalancer on the guest (gitea, the ingress) -- IP + each port
  kubectl --kubeconfig "$KUBECONFIG" get svc -A -o json 2>"$STATE_DIR/lb.err" \
    | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.status.loadBalancer.ingress[0].ip as $i|select($i!=null)|.spec.ports[].port|"\($i) \(.)"' \
    >> "$STATE_DIR/endpoints" \
    || die "could not list the guest's LoadBalancers: $(cat "$STATE_DIR/lb.err")"
  # the *.vks.local names the ingress serves -> the ingress IP (INGRESS_LB_IP, published by install-ingress)
  if [ -n "${INGRESS_LB_IP:-}" ]; then
    for h in "${GITEA_HOST:-}" "${TEKTON_DASHBOARD_HOST:-}" "${HEADLAMP_HOST:-}" $(app_hosts_all); do
      [ -n "$h" ] && name "$INGRESS_LB_IP" "$h"
    done
  fi
  sort -u -o "$STATE_DIR/endpoints" "$STATE_DIR/endpoints"
  sort -u -o "$STATE_DIR/hosts" "$STATE_DIR/hosts"
}
app_hosts_all() { # shellcheck source=scripts/lib/apps.sh
  . "${SCRIPT_DIR}/lib/apps.sh"; local a; for a in $(app_names); do printf '%s\n' "$(app_host "$a")"; done; }   # app_host prints no newline

up() {
  derive
  printf 'endpoints (%s):\n' "$(wc -l < "$STATE_DIR/endpoints")"; sed 's/^/  /' "$STATE_DIR/endpoints"
  local ips rdr fwd=() ip p
  ips="$(awk '{print $1}' "$STATE_DIR/endpoints" | sort -u | tr '\n' ' ')"
  rdr=""
  while read -r ip p; do
    fwd+=(-R "${ip}:$(hi_port "$p"):${ip}:${p}")
    [ "$p" -lt 1024 ] && rdr="${rdr}rdr pass on lo0 inet proto tcp from any to ${ip} port ${p} -> ${ip} port $(hi_port "$p")"$'\n'
  done < "$STATE_DIR/endpoints"
  # Mac side: sshd drop-in, lo0 aliases, pf anchor, hosts block -- all recorded for `down`
  mac "set -e
    printf '# vks-airgap-cicd mac-lab-tunnel harness. Remove to undo.\nGatewayPorts clientspecified\n' | sudo -n tee /etc/ssh/sshd_config.d/05-vks-tunnel.conf >/dev/null
    for ip in ${ips}; do ifconfig lo0 | grep -q \"inet \$ip \" || { sudo -n ifconfig lo0 alias \$ip; echo \$ip >> ~/.vks-lab-tunnel-aliases; }; done
    printf '%s' '${rdr}' | sudo -n pfctl -a com.apple/vks-tunnel -f - 2>/dev/null
    # pfctl -E takes a REFERENCE on pf and prints a token; -X <token> releases exactly that one, so
    # down never disables pf for anything else that enabled it. MEASURED 2026-09-25: on the Scaleway Mac pf
    # was ALREADY enabled (2 days) by the image; after down it stayed enabled -- only our reference went.
    [ -s ~/.vks-lab-tunnel-pftoken ] || sudo -n pfctl -E 2>&1 | awk '/^Token/ {print \$3}' > ~/.vks-lab-tunnel-pftoken
    sudo -n sed -i '' '/# >>> vks-lab-tunnel/,/# <<< vks-lab-tunnel/d' /etc/hosts
    { echo '# >>> vks-lab-tunnel'; printf '%s\n' \"$(cat "$STATE_DIR/hosts")\"; echo '# <<< vks-lab-tunnel'; } | sudo -n tee -a /etc/hosts >/dev/null"
  # the forwards themselves, from THIS box; its own process group so `down` can kill it whole
  # Its output goes to a LOG, never the caller's stdout: a backgrounded child holding the caller's pipe
  # made `mac-lab-tunnel.sh up | grep ...` hang forever (measured 2026-09-25).
  setsid ssh -N "${SSHO[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "${fwd[@]}" "$MAC" \
    </dev/null >"$STATE_DIR/ssh.log" 2>&1 &
  echo $! > "$PIDFILE"
  sleep 3
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || die "the ssh forward exited: $(tail -3 "$STATE_DIR/ssh.log")"
  printf 'tunnel up (pid %s): %s forwards, %s redirects, %s host names\n' "$(cat "$PIDFILE")" "$(( ${#fwd[@]} / 2 ))" \
    "$(printf '%s' "$rdr" | grep -c . || true)" "$(wc -l < "$STATE_DIR/hosts")"
}

down() {
  if [ -f "$PIDFILE" ]; then kill -- "-$(cat "$PIDFILE")" 2>/dev/null || kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
  mac "sudo -n pfctl -a com.apple/vks-tunnel -F all >/dev/null 2>&1 || true
    [ -f ~/.vks-lab-tunnel-aliases ] && while read -r ip; do sudo -n ifconfig lo0 -alias \$ip || true; done < ~/.vks-lab-tunnel-aliases; rm -f ~/.vks-lab-tunnel-aliases
    sudo -n sed -i '' '/# >>> vks-lab-tunnel/,/# <<< vks-lab-tunnel/d' /etc/hosts
    sudo -n rm -f /etc/ssh/sshd_config.d/05-vks-tunnel.conf
    [ -s ~/.vks-lab-tunnel-pftoken ] && sudo -n pfctl -X \$(cat ~/.vks-lab-tunnel-pftoken) >/dev/null 2>&1; rm -f ~/.vks-lab-tunnel-pftoken"
  status
}

status() {
  local p=""; [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE")"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "local ssh forward: running (pid $p)"; else echo "local ssh forward: not running"; fi
  mac "echo \"mac lo0 lab aliases: \$(ifconfig lo0 | grep -c 'inet 192.168.')\"; echo \"mac pf rules: \$(sudo -n pfctl -a com.apple/vks-tunnel -s nat 2>/dev/null | grep -c rdr)\"; echo \"mac hosts block lines: \$(sed -n '/# >>> vks-lab-tunnel/,/# <<< vks-lab-tunnel/p' /etc/hosts | grep -vc '^#')\"; echo \"mac sshd drop-in: \$(ls /etc/ssh/sshd_config.d/05-vks-tunnel.conf 2>/dev/null || echo absent)\""
}

case "$ACTION" in up) up ;; down) down ;; status) status ;; *) die "usage: $0 up|down|status [user@mac]" ;; esac
