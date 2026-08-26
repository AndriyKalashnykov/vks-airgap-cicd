#!/usr/bin/env bash
# scripts/vks-shape.sh — discover the guest-cluster SHAPE from the Supervisor.
#
#   show   print what THIS Supervisor / vSphere Namespace actually offers. Read-only, never gates,
#          exits 0 even with no cluster (same contract as creds-show / argocd-version).
#   set    write the unambiguous ones into .env. Writes NOTHING when the answer is ambiguous or
#          already set — a wrong value pinned in .env is worse than no value, because it OVERRIDES
#          the code default that would otherwise have worked.
#
# ⚠️ DO NOT REPLACE THIS WITH `kubectl get storageclass`. StorageClass is CLUSTER-scoped, so that
# lists policies assigned to OTHER vSphere Namespaces and can hand the operator a class their own
# namespace cannot use. MEASURED on VKS 3.7.1: cluster-wide FOUR (wcp-vmfs, wcp-vmfs-latebinding,
# vm-encryption-policy, vm-encryption-policy-latebinding) but only TWO assigned to `cicd`.
# StoragePolicyQuota is NAMESPACE-scoped and names exactly the usable ones:
#     storagepolicyquota/wcp-vmfs-storagepolicyquota
#       .status.extensions[].extensionQuotaUsage[].storageClassName -> wcp-vmfs, wcp-vmfs-latebinding
# `resourcequota` is NOT an alternative: measured ZERO items in that namespace.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

VERB="${1:-show}"
case "$VERB" in show|set) ;; *) die "usage: ${0##*/} [show|set]" ;; esac

SUP="$(supervisor_kubeconfig 2>/dev/null || true)"
NS="${VKS_NAMESPACE:-}"
k() { kubectl --kubeconfig "$SUP" "$@"; }

if [ -z "$SUP" ] || [ ! -f "$SUP" ]; then
  log_warn "no Supervisor kubeconfig — nothing to discover. Get one with 'make vks-login'."
  exit 0
fi
if [ -z "$NS" ]; then
  log_warn "VKS_NAMESPACE is not set — the storage policy is per-NAMESPACE, so it cannot be resolved."
  log_warn "  set VKS_NAMESPACE in .env (your vSphere Namespace), then re-run."
  exit 0
fi

# --- storage class: the policies assigned to THIS vSphere Namespace ------------------------------
# Prefer the IMMEDIATE-binding class over its -latebinding sibling: a guest cluster's root volumes
# are provisioned up front, so WaitForFirstConsumer buys nothing, and the base name is what this
# repo has always shipped. If a namespace has ONLY a -latebinding class the filter yields nothing
# and we report ambiguity rather than guessing.
sc_all="$(k get storagepolicyquota -n "$NS" \
            -o jsonpath='{range .items[*].status.extensions[*].extensionQuotaUsage[*]}{.storageClassName}{"\n"}{end}' \
            2>/dev/null | sort -u | grep -v '^$' || true)"
sc_pick="$(printf '%s\n' "$sc_all" | grep -v -- '-latebinding$' || true)"
sc_n="$(printf '%s\n' "$sc_pick" | grep -c . || true)"

# --- cluster class ------------------------------------------------------------------------------
# ⚠️ THIS ONE IS INERT AND THE OUTPUT SAYS SO. MEASURED on VKS 3.7.1 via server-side dry-runs: the
# Supervisor's mutating webhook rewrites classRef to the newest COMPATIBLE class, even when the one
# asked for is already in range (asked v3.6.0 with k8s v1.35.6, which v3.6.0 supports; stored
# v3.7.0). Setting it changes nothing. It is listed because the name must EXIST -- a bogus one is
# rejected outright -- so seeing the real catalogue is still worth a command.
# List the PUBLIC namespace, never the cluster's own: a vSphere Namespace gets a replicated SUBSET
# and it is the OLD end (measured: cicd and lab each held the same 3, every one deprecated=true and
# capped at k8s v1.32, against 7 up to v1.36 in the public one).
ccns="${VKS_CLUSTERCLASS_NAMESPACE:-vmware-system-vks-public}"
cc_all="$(k get clusterclass -n "$ccns" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.kubernetes\.vmware\.com/min-version-supported}{"|"}{.metadata.labels.kubernetes\.vmware\.com/max-version-supported}{"|"}{.metadata.labels.deprecated\.kubernetes\.vmware\.com/deprecated}{"\n"}{end}' \
            2>/dev/null | grep -v '^$' || true)"
cc_live="$(printf '%s\n' "$cc_all" | awk -F'|' '$4!="true"{print $1}' | sort -V || true)"
cc_newest="$(printf '%s\n' "$cc_live" | tail -1)"

if [ "$VERB" = show ]; then
  echo
  echo "guest-cluster shape available to ${NS} (Supervisor: ${SUP})"
  echo
  echo "  VKS_STORAGE_CLASS — the storage policies ASSIGNED to this vSphere Namespace"
  if [ -n "$sc_all" ]; then
    printf '%s\n' "$sc_all" | while IFS= read -r c; do
      case "$c" in *-latebinding) printf '      %-34s (WaitForFirstConsumer — not what a guest cluster wants)\n' "$c" ;;
                   *)             printf '      %-34s <- use this\n' "$c" ;; esac
    done
  else
    echo "      (none readable — a tenant may lack RBAC on storagepolicyquota in ${NS})"
  fi
  echo "      effective now: ${VKS_STORAGE_CLASS:-<unset — code default 'wcp-vmfs' applies>}"
  echo
  echo "  VKS_CLUSTERCLASS — INERT. The Supervisor rewrites it to the newest COMPATIBLE class;"
  echo "                     it only has to EXIST. Listing ${ccns}:"
  if [ -n "$cc_all" ]; then
    printf '%s\n' "$cc_all" | sort -V | while IFS='|' read -r n mn mx dep; do
      [ -n "$n" ] || continue
      if [ "$dep" = true ]; then printf '      %-26s k8s %s..%s   DEPRECATED\n' "$n" "$mn" "$mx"
      else                       printf '      %-26s k8s %s..%s\n' "$n" "$mn" "$mx"; fi
    done
    echo "      newest non-deprecated: ${cc_newest:-<none>}   <- what admission will pick, whatever you set"
  else
    echo "      (none readable — a tenant may lack RBAC on clusterclass in ${ccns})"
  fi
  echo "      effective now: ${VKS_CLUSTERCLASS:-<unset — code default 'builtin-generic-v3.6.0' applies>}"
  echo
  echo "  write the unambiguous ones into .env:  make vks-shape-set"
  echo
  exit 0
fi

# --- set ----------------------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
[ -f "$ENV_FILE" ] || die "no .env — run 'make env-init' first."
wrote=0
if [ -n "${VKS_STORAGE_CLASS:-}" ]; then
  log_info "= VKS_STORAGE_CLASS already set (${VKS_STORAGE_CLASS}) — not overwriting"
elif [ "$sc_n" = 1 ]; then
  set_env_var VKS_STORAGE_CLASS "$sc_pick" "$ENV_FILE"; wrote=$((wrote+1))
  log_info "+ VKS_STORAGE_CLASS = ${sc_pick}  (the policy assigned to ${NS})"
elif [ "${sc_n:-0}" -gt 1 ] 2>/dev/null; then
  log_warn "? VKS_STORAGE_CLASS AMBIGUOUS — ${NS} has more than one assigned policy. Pick one, set it by hand:"
  printf '%s\n' "$sc_pick" | while IFS= read -r c; do [ -n "$c" ] && printf '      %s\n' "$c"; done
else
  log_warn "- VKS_STORAGE_CLASS not discovered (no storagepolicyquota readable in ${NS})"
fi

if [ -n "${VKS_CLUSTERCLASS:-}" ]; then
  log_info "= VKS_CLUSTERCLASS already set (${VKS_CLUSTERCLASS}) — not overwriting"
elif [ -n "$cc_newest" ]; then
  set_env_var VKS_CLUSTERCLASS "$cc_newest" "$ENV_FILE"; wrote=$((wrote+1))
  log_info "+ VKS_CLUSTERCLASS = ${cc_newest}  (newest non-deprecated — admission would pick it anyway)"
else
  log_warn "- VKS_CLUSTERCLASS not discovered (no clusterclass readable in ${ccns})"
fi
log_info "wrote ${wrote} value(s) to ${ENV_FILE}"
