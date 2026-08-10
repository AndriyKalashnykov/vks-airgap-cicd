#!/usr/bin/env bash
# show-dns-records.sh — print the exact DNS A records this install needs, with their live IPs.
#
# scenario-1 Step 2.6 says "create a real DNS A record for your FQDN" and then leaves the reader
# to go and find the LoadBalancer IP themselves. We KNOW the IP - it is in the cluster - so the
# only genuinely manual part is creating the record in whatever DNS this site runs.
#
# We deliberately do NOT write the record: every site's DNS is different (BIND, Infoblox, Route53,
# a libvirt network on a lab box), and a tool that guessed would be wrong everywhere. Printing the
# exact record removes the lookup, which is the part we can actually own.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
require_cmd kubectl

KC="${ARGOCD_KUBECONFIG:-${KUBECONFIG:-}}"
[ -s "${KC:-/nonexistent}" ] || die "no kubeconfig - point KUBECONFIG at the SUPERVISOR (that is where Harbor and ArgoCD run)"

_lb() { kubectl --kubeconfig "$KC" -n "$2" get svc "$3" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null; }

printf '  %-34s %-16s %s\n' HOSTNAME IP SOURCE
n=0
hns="$(kubectl --kubeconfig "$KC" get svc -A -o json 2>/dev/null \
      | jq -r '.items[]?|select(.spec.type=="LoadBalancer")|select(.metadata.name|test("harbor-nginx|argocd-server"))|"\(.metadata.namespace)\t\(.metadata.name)\t\(.status.loadBalancer.ingress[0].ip // "")"' 2>/dev/null || true)"
while IFS=$'\t' read -r ns nm ip; do
  [ -n "${nm:-}" ] && [ -n "${ip:-}" ] || continue
  case "$nm" in
    harbor-nginx)  host="${HARBOR_URL:-<your harbor FQDN>}" ;;
    argocd-server) host="${ARGOCD_HOST:-${ARGOCD_SERVER:-<your argocd FQDN, if you use one>}}" ;;
    *) continue ;;
  esac
  printf '  %-34s %-16s %s\n' "$host" "$ip" "${ns}/${nm}"
  n=$((n + 1))
done <<< "$hns"

[ "$n" -gt 0 ] || { log_warn "no Harbor/ArgoCD LoadBalancer found on this cluster - is KUBECONFIG the SUPERVISOR's?"; exit 0; }

cat <<'NOTE'

  Create these as A records in the DNS your GUEST CLUSTER NODES resolve.
  /etc/hosts on the jump box is NOT enough: the nodes pull images from Harbor and cannot see it.

  On a libvirt lab box, per network:
    virsh -c qemu:///system net-update <net> add dns-host \
      "<host ip='<IP>'><hostname><HOSTNAME></hostname></host>" --live --config
NOTE
