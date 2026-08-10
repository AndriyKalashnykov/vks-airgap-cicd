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

# Harbor and ArgoCD run on the SUPERVISOR, so resolve the Supervisor kubeconfig the way every other
# Supervisor-facing script does -- do NOT reach for $KUBECONFIG first.
# MEASURED 2026-08-10 walking scenario-1: Step 2 tells the reader to run this "once you have finished
# Step 3", and at that point $KUBECONFIG is the GUEST cluster (Step 4's table sets it) or a stale path
# from an earlier run. The die below then told an operator who had JUST run `make vks-login` -- which
# writes secrets/supervisor.kubeconfig -- that they had "no kubeconfig". Same defect as
# 08-install-argocd-service.sh had.
# ⚠️ PICK THE FIRST CANDIDATE THAT EXISTS -- a plain `${A:-${B:-C}}` chain picks the first one that
# is SET, which is not the same thing and produced a message naming a file it never looked at.
# MEASURED 2026-08-10: .env carries ARGOCD_KUBECONFIG=./secrets/argocd.kubeconfig (Step 8 creates it
# LATER), so at Step 2 that unset-but-configured path won the chain, the guest path lost too, and the
# die reported "no Supervisor kubeconfig ... secrets/supervisor.kubeconfig" -- a file that WAS there.
KC=""
for _c in "${ARGOCD_KUBECONFIG:-}" \
          "${VKS_SUPERVISOR_KUBECONFIG:-}" \
          "${SUPERVISOR_KUBECONFIG:-}" \
          "${REPO_ROOT}/secrets/supervisor.kubeconfig" \
          "${KUBECONFIG:-}"; do
  [ -n "$_c" ] && [ -s "$_c" ] && { KC="$_c"; break; }
done
if [ -z "$KC" ]; then
  log_error "no readable kubeconfig. Harbor and ArgoCD run on the SUPERVISOR; tried, in order:"
  for _c in "${ARGOCD_KUBECONFIG:-<unset>}" "${VKS_SUPERVISOR_KUBECONFIG:-<unset>}" \
            "${SUPERVISOR_KUBECONFIG:-<unset>}" "${REPO_ROOT}/secrets/supervisor.kubeconfig" \
            "${KUBECONFIG:-<unset>}"; do
    log_error "    ${_c}"
  done
  die "run 'make vks-login' (scenario-1 Step 3) to write secrets/supervisor.kubeconfig"
fi

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
