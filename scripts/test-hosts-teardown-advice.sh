#!/usr/bin/env bash
# ci-tier: fast — offline; sources lib/apps.sh and applies the emitted sed to fixture
#          /etc/hosts files. No network, no cluster.
# test-hosts-teardown-advice.sh — B727: `_hosts_teardown_advice` (lib/apps.sh) must NOT emit a command
# that deletes /etc/hosts lines it does not own. The old `sed -i '/<domain>/d'` deleted any line
# CONTAINING the domain — including `127.0.0.1 localhost <app>.<domain>` and unrelated real hosts.
# The fix emits an LB-IP-ANCHORED delete (removes only our line, which creds.sh writes starting with
# the LB IP), and falls back to a name-listing by-hand instruction when the LB IP is unknown.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
p=0; f=0
ck() { if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"
       else f=$((f+1)); printf '  FAIL  %s (got=[%s] want=[%s])\n' "$1" "$2" "$3"; fi; }

# A realistic /etc/hosts, built by DERIVATION (this is a shared file; check-app-hardcodes forbids a
# literal app name). localhost + corp each carry a $APP_DOMAIN alias — the exact shape the old `/d`
# destroyed. Our ingress line is assembled just as 46-install-istio.sh emits the ADD line:
# "${LB_IP}  $(ingress_infra_hosts)<app hosts>". Indented + nas lines are the empty-IP / unrelated traps.
fixture() {
  local app_hosts=""
  for a in $(app_names); do [ -n "$a" ] && app_hosts="${app_hosts}$(app_host "$a") "; done
  cat > "$T/hosts" <<HOSTS
127.0.0.1 localhost legacy.${APP_DOMAIN}
::1 ip6-localhost ip6-loopback
10.0.0.1 corp.example.com stale.${APP_DOMAIN}
192.168.101.135  $(ingress_infra_hosts)${app_hosts}
  10.0.0.9 indented.example.com
  192.168.101.135 indented-lbip.${APP_DOMAIN}
192.168.5.5 nas.internal
HOSTS
}

export APP_DOMAIN=vks.local GITEA_HOST=gitea.vks.local TEKTON_DASHBOARD_HOST=tekton.vks.local HEADLAMP_HOST=headlamp.vks.local

# ---- 1. BEHAVIOURAL: apply the emitted sed to the fixture; our line goes, everything else survives ----
export INGRESS_LB_IP=192.168.101.135
out="$(_hosts_teardown_advice)"
sedline="$(grep -F 'sudo sed -i' <<<"$out" | head -1)"
# pull the sed SCRIPT out from between  sed -i '  and  ' /etc/hosts
script="${sedline#*sed -i \'}"; script="${script%%\' /etc/hosts*}"
fixture
sed -i "$script" "$T/hosts"
ck "an emitted sed command was found"                       "$([ -n "$sedline" ] && echo yes || echo no)" "yes"
ck "OUR ingress line (starts with the LB IP) was removed"   "$(grep -c '^192\.168\.101\.135[[:space:]]' "$T/hosts")" "0"
ck "127.0.0.1 localhost line SURVIVES (the data-loss guard)" "$(grep -c '^127\.0\.0\.1 localhost' "$T/hosts")" "1"
ck "unrelated corp line (mentions the domain) SURVIVES"      "$(grep -c '^10\.0\.0\.1 corp\.example\.com' "$T/hosts")" "1"
ck "indented line SURVIVES"                                  "$(grep -c 'indented\.example\.com' "$T/hosts")" "1"
ck "an INDENTED LB-IP line SURVIVES (proves the ^ anchor)"   "$(grep -c 'indented-lbip' "$T/hosts")" "1"
ck "nas line SURVIVES"                                       "$(grep -c 'nas\.internal' "$T/hosts")" "1"

# ---- 2. EMPTY-IP: no sudo sed emitted; the names ARE listed (fall back to by-hand) ----
unset INGRESS_LB_IP
out="$(_hosts_teardown_advice)"
ck "empty LB IP -> NO 'sudo sed' command emitted"           "$(grep -cF 'sudo sed' <<<"$out")" "0"
ck "empty LB IP -> the ingress names ARE listed"            "$(grep -cF 'gitea.vks.local' <<<"$out")" "1"

# ---- 3. CHANGE-TRACKING: a moved host appears in the names (the old literal /vks.local/d could not) ----
export INGRESS_LB_IP=192.168.101.135 HEADLAMP_HOST=headlamp.other.tld
out="$(_hosts_teardown_advice)"
ck "a relocated host (headlamp.other.tld) is named — the fix tracks host changes" \
   "$(grep -cF 'headlamp.other.tld' <<<"$out")" "1"

# ---- 4. B486: a published argocd-server line is named, and ONLY a line whose sole name it is goes ----
export ARGOCD_SERVER=argocd-server
out="$(_hosts_teardown_advice)"
aline="$(grep -F 'argocd-server[[:space:]]' <<<"$out" || true)"
ck "ARGOCD_SERVER=argocd-server -> an ArgoCD sed line is emitted" "$([ -n "$aline" ] && echo yes || echo no)" "yes"
ascript="${aline#*sed -i \'}"; ascript="${ascript%%\' /etc/hosts*}"
printf '127.0.0.1 localhost\n192.168.101.131 argocd-server\n10.0.0.1 argocd-server other\n' > "$T/h2"
sed -i "$ascript" "$T/h2"
ck "the sole-name argocd-server line was removed"           "$(grep -c '^192\.168\.101\.131' "$T/h2")" "0"
ck "a line with OTHER names survives"                       "$(grep -c '^10\.0\.0\.1 argocd-server other' "$T/h2")" "1"
ck "localhost survives"                                     "$(grep -c '^127\.0\.0\.1 localhost' "$T/h2")" "1"
unset ARGOCD_SERVER
ck "no argocd-server published -> no ArgoCD line"           "$(_hosts_teardown_advice | grep -cF 'ArgoCD line')" "0"

printf '\n  %d passed, %d failed\n' "$p" "$f"
[ "$f" -eq 0 ]
