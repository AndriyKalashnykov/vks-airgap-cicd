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
our_pid() {   # prints the recorded pid only if that process is really this tunnel's ssh
  local p; [ -s "$PIDFILE" ] || return 1; p="$(cat "$PIDFILE")"
  ps -o args= -p "$p" 2>/dev/null | grep -q "ssh -N .*${MAC}" || return 1
  printf '%s' "$p"
}
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
  # SUPERVISOR_HOST and ARGOCD_SERVER may be NAMES (.env.example documents ARGOCD_SERVER as the name
  # its cert carries), so resolve them like the others -- an alias of a name would abort mid-setup.
  local v
  for v in "${SUPERVISOR_HOST:-}" "${ARGOCD_SERVER:-}"; do
    v="${v#*://}"; v="${v%%/*}"; v="${v%%:*}"
    [ -n "$v" ] || continue
    if is_ipv4 "$v"; then add "$v" 443; continue; fi
    ip="$(resolve "$v")"; is_ipv4 "${ip:-}" || die "cannot resolve ${v} to an IPv4 on this box -- the Mac could not reach it either"
    add "$ip" 443; name "$ip" "$v"
  done
  # the guest API server, from the kubeconfig the rest of the flow uses
  local srv; srv="$(kubectl config view --kubeconfig "${KUBECONFIG:?}" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  srv="${srv#https://}"; srv="${srv%%/*}"
  case "$srv" in *:*) ;; ?*) srv="${srv}:443" ;; esac
  [ -n "$srv" ] && add "${srv%%:*}" "${srv##*:}"
  # every LoadBalancer on the guest (gitea, the ingress) -- IP + each port
  kubectl --kubeconfig "$KUBECONFIG" get svc -A -o json 2>"$STATE_DIR/lb.err" \
    | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.status.loadBalancer.ingress[0].ip as $i|select($i!=null)|.spec.ports[].port|"\($i) \(.)"' \
    >> "$STATE_DIR/endpoints" \
    || die "could not list the guest's LoadBalancers: $(cat "$STATE_DIR/lb.err")"
  # the *.vks.local names the ingress serves -> the ingress IP (INGRESS_LB_IP, published by install-ingress)
  # The ingress IP from the LIVE list just fetched (the Service exposing 15021, as lib/istio.sh
  # discovers it) -- never INGRESS_LB_IP, which is published state and goes stale when a VIP moves.
  local ing; ing="$(awk '$2 == 15021 {print $1; exit}' "$STATE_DIR/endpoints")"
  [ -n "$ing" ] || log_warn "no Service exposes 15021 on the guest -- the *.vks.local names are NOT mapped on the Mac"
  if [ -n "$ing" ]; then
    for h in "${GITEA_HOST:-}" "${TEKTON_DASHBOARD_HOST:-}" "${HEADLAMP_HOST:-}" $(app_hosts_all); do
      [ -n "$h" ] && name "$ing" "$h"
    done
  fi
  sort -u -o "$STATE_DIR/endpoints" "$STATE_DIR/endpoints"
  sort -u -o "$STATE_DIR/hosts" "$STATE_DIR/hosts"
}
is_ipv4() { printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
app_hosts_all() { # shellcheck source=scripts/lib/apps.sh
  . "${SCRIPT_DIR}/lib/apps.sh"; local a; for a in $(app_names); do printf '%s\n' "$(app_host "$a")"; done; }   # app_host prints no newline

up() {
  if our_pid >/dev/null; then die "the tunnel is already up (pid $(our_pid)) -- run: $0 down"; fi
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
    printf '%s' '${rdr}' | sudo -n pfctl -a com.apple/vks-tunnel -f - 2>&1 | grep -v -e ALTQ -e 'flushing of rules' -e 'present in the main' -e 'See /etc/pf.conf' -e '^\$' || true
    sudo -n pfctl -a com.apple/vks-tunnel -s nat 2>/dev/null | grep -q rdr || [ -z '${rdr}' ] || { echo 'pf anchor load FAILED' >&2; exit 1; }
    # pfctl -E takes a REFERENCE on pf and prints a token; -X <token> releases exactly that one, so
    # down never disables pf for anything else that enabled it. MEASURED 2026-09-25: on the Scaleway Mac pf
    # was ALREADY enabled (2 days) by the image; after down it stayed enabled -- only our reference went.
    # a FRESH reference every up (appended): a token file that outlived a Mac reboot names a reference
    # that no longer exists, and skipping -E then left pf off on an image that does not pre-enable it.
    sudo -n pfctl -E 2>&1 | awk '/^Token/ {print \$3}' >> ~/.vks-lab-tunnel-pftoken
    sudo -n pfctl -s info 2>/dev/null | grep -q 'Status: Enabled' || { echo 'pf is NOT enabled' >&2; exit 1; }
    sudo -n sed -i '' '/# >>> vks-lab-tunnel/,/# <<< vks-lab-tunnel/d' /etc/hosts"
  # the hosts block travels over STDIN, never inside the command string: .env values are data, not
  # Mac shell code.
  { echo '# >>> vks-lab-tunnel'; cat "$STATE_DIR/hosts"; echo '# <<< vks-lab-tunnel'; } \
    | ssh "${SSHO[@]}" "$MAC" 'sudo -n tee -a /etc/hosts >/dev/null'
  # the forwards themselves, from THIS box; its own process group so `down` can kill it whole
  # Its output goes to a LOG, never the caller's stdout: a backgrounded child holding the caller's pipe
  # made `mac-lab-tunnel.sh up | grep ...` hang forever (measured 2026-09-25).
  setsid ssh -N "${SSHO[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 "${fwd[@]}" "$MAC" \
    </dev/null >"$STATE_DIR/ssh.log" 2>&1 &
  local sp=$!
  sleep 3
  kill -0 "$sp" 2>/dev/null || die "the ssh forward exited: $(tail -3 "$STATE_DIR/ssh.log")"
  echo "$sp" > "$PIDFILE"
  printf 'tunnel up (pid %s): %s forwards, %s redirects, %s host names\n' "$(cat "$PIDFILE")" "$(( ${#fwd[@]} / 2 ))" \
    "$(printf '%s' "$rdr" | grep -c . || true)" "$(wc -l < "$STATE_DIR/hosts")"
}

down() {
  local p
  if p="$(our_pid)"; then kill -- "-$p" 2>/dev/null || true
  elif [ -s "$PIDFILE" ]; then log_warn "pid $(cat "$PIDFILE") is not this tunnel's ssh (reused after a reboot?) -- not killing it"; fi
  rm -f "$PIDFILE"
  mac "sudo -n pfctl -a com.apple/vks-tunnel -F all >/dev/null 2>&1 || true
    [ -f ~/.vks-lab-tunnel-aliases ] && while read -r ip; do sudo -n ifconfig lo0 -alias \$ip || true; done < ~/.vks-lab-tunnel-aliases; rm -f ~/.vks-lab-tunnel-aliases
    sudo -n sed -i '' '/# >>> vks-lab-tunnel/,/# <<< vks-lab-tunnel/d' /etc/hosts
    sudo -n rm -f /etc/ssh/sshd_config.d/05-vks-tunnel.conf
    [ -s ~/.vks-lab-tunnel-pftoken ] && while read -r t; do sudo -n pfctl -X \$t >/dev/null 2>&1 || true; done < ~/.vks-lab-tunnel-pftoken; rm -f ~/.vks-lab-tunnel-pftoken"
  status
}

status() {
  local p
  if p="$(our_pid)"; then echo "local ssh forward: running (pid $p)"; else echo "local ssh forward: not running"; fi
  mac "n=0; [ -f ~/.vks-lab-tunnel-aliases ] && while read -r ip; do ifconfig lo0 | grep -q \"inet \$ip \" && n=\$((n+1)); done < ~/.vks-lab-tunnel-aliases; echo \"mac lo0 aliases we added: \$n\"; echo \"mac pf rules: \$(sudo -n pfctl -a com.apple/vks-tunnel -s nat 2>/dev/null | grep -c rdr)\"; echo \"mac hosts block lines: \$(sed -n '/# >>> vks-lab-tunnel/,/# <<< vks-lab-tunnel/p' /etc/hosts | grep -vc '^#')\"; echo \"mac sshd drop-in: \$(ls /etc/ssh/sshd_config.d/05-vks-tunnel.conf 2>/dev/null || echo absent)\""
}

case "$ACTION" in up) up ;; down) down ;; status) status ;; *) die "usage: $0 up|down|status [user@mac]" ;; esac
