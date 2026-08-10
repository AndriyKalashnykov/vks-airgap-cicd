#!/usr/bin/env bash
# list-supervisor-services.sh — READ-ONLY: what Supervisor Services does vCenter know about?
#
# WHY THIS EXISTS: every other target here takes SERVICE=<id>, and that id is DERIVED BY VCENTER
# from the service-definition YAML's content -- dotted (harbor.tanzu.vmware.com), not the
# dash-only catalogue key (harbor). It is not guessable, and nothing else in this repo printed it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/vcenter.sh
. "${SCRIPT_DIR}/lib/vcenter.sh"
load_env

trap vc_logout EXIT
vc_login
printf '  %-12s %-40s %s\n' STATE ID 'DISPLAY NAME'
n=0
while IFS=$'\t' read -r st id disp; do
  [ -n "${id:-}" ] || continue
  printf '  %-12s %-40s %s\n' "$st" "$id" "$disp"; n=$((n + 1))
done < <(vc_ss_list)
[ "$n" -gt 0 ] || log_warn "no Supervisor Services are registered on ${VCENTER_HOST}"
log_info "${n} registered. Pass one of these as SERVICE=<id>."
