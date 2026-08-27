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
# READ status.total[] — the field Broadcom documents ("read storage class names from the Status
# section"), and `kubectl get storagepolicyquota -n <ns>` is explicitly given as the NON-ADMIN path
# because `kubectl get storageclass` is "available only to a user with administrator privileges".
# A tenant is this repo's DEFAULT persona, so the admin-only command must not be the primary.
# status.extensions[] carries the same names and is the fallback. API is cns.vmware.com/v1alpha2
# here (v1alpha1 is served but not storage) — do not pin v1alpha1.
sc_all="$(k get storagepolicyquota -n "$NS" \
            -o jsonpath='{range .items[*].status.total[*]}{.storageClassName}{"\n"}{end}' \
            2>/dev/null | sort -u | grep -v '^$' || true)"
[ -n "$sc_all" ] || sc_all="$(k get storagepolicyquota -n "$NS" \
            -o jsonpath='{range .items[*].status.extensions[*].extensionQuotaUsage[*]}{.storageClassName}{"\n"}{end}' \
            2>/dev/null | sort -u | grep -v '^$' || true)"

# ⚠️ MULTI-ZONE INVERTS THE CHOICE. Broadcom, verbatim: "When there are multiple Zones in a
# namespace, late-binding storage class is REQUIRED for persistent volumes for node of
# machineDeployment." That scopes it to WORKERS, while this repo renders ONE storageClass for the
# whole topology — so a multi-zone namespace cannot be served by one auto-picked value and we
# refuse rather than pick the wrong half. Measured on this lab: 1 zone.
zones="$(k get zones -n "$NS" --no-headers 2>/dev/null | grep -c . || true)"
sc_pick="$(printf '%s\n' "$sc_all" | grep -v -- '-latebinding$' || true)"
# F9: de-prioritise an ENCRYPTION policy before declaring ambiguity — the ClusterClass schema
# says storageClass creates NODE ROOT VOLUMES, which a VM-encryption policy is never the answer
# for. Measured on this Supervisor: 5 of 7 namespaces carry one, so skipping this step makes the
# feature inert in most of them. Only applied when it still leaves a candidate.
if [ "$(printf '%s\n' "$sc_pick" | grep -c . || true)" -gt 1 ] 2>/dev/null; then
  _noenc="$(printf '%s\n' "$sc_pick" | grep -v -- '-encryption-policy$' || true)"
  [ -n "$_noenc" ] && sc_pick="$_noenc"
fi
sc_n="$(printf '%s\n' "$sc_pick" | grep -c . || true)"
if [ "${zones:-1}" -gt 1 ] 2>/dev/null; then sc_n=0; sc_multizone=1; else sc_multizone=0; fi

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
# ⚠️ NO `sort -V`. It is BANNED in product code here — it is OS-dependent (toybox != GNU) and this
# repo ships a shared jq sort key, vkey_jq(), used at 8 sites. test-vks-package-version-sort.sh
# gates it, and caught this file using `sort -V` on its first full run. Sorting the CLASS list also
# genuinely needs a version key, not lexicographic: builtin-generic-v3.9.0 must rank BELOW v3.10.0,
# and VKS moved 3.1 -> 3.7 inside this repo's own history, so v3.10 is within the artifact's life.
cc_all="$(k get clusterclass -n "$ccns" -o json 2>/dev/null \
  | jq -r "$(vkey_jq)"' [.items[]
      | {n: .metadata.name,
         v: (.metadata.labels["kubernetes.vmware.com/version"] // ""),
         mn: (.metadata.labels["kubernetes.vmware.com/min-version-supported"] // ""),
         mx: (.metadata.labels["kubernetes.vmware.com/max-version-supported"] // ""),
         d:  (.metadata.labels["deprecated.kubernetes.vmware.com/deprecated"] // "")}]
      | sort_by(.v | vkey) | .[] | "\(.n)|\(.mn)|\(.mx)|\(.d)"' 2>/dev/null | grep -v '^$' || true)"
cc_live="$(printf '%s\n' "$cc_all" | awk -F'|' '$4!="true"{print $1}' || true)"
cc_newest="$(printf '%s\n' "$cc_live" | grep -v '^$' | tail -1 || true)"

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
    printf '%s\n' "$cc_all" | while IFS='|' read -r n mn mx dep; do
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
# F8: this runs as a PREREQUISITE of vks-cluster-create, whose comment promises it NEVER gates.
# A die here would stop a create that previously ran fine on a .env-less box (load_env itself only
# requires .env.example). Warn and exit 0 like every other degrade arm in this file.
if [ ! -f "$ENV_FILE" ]; then
  log_warn "no .env — nothing to write. Run 'make env-init' if you want one; the code defaults apply."
  exit 0
fi
wrote=0
# ⚠️ READ THE PIN FROM THE FILE, NOT THE ENVIRONMENT. Under SKIP_DOTENV=1 load_env does not read
# .env, so ${VKS_STORAGE_CLASS} is UNSET while the file may hold a deliberate pin — and this
# script still WRITES to that file. Measured: SKIP_DOTENV=1 ... set replaced a
# `my-deliberate-vsan-policy` pin with this lab's `wcp-vmfs`. "Ignore .env for reading" plus
# "write .env" is exactly how a tool produces the wrong pin its own header warns about.
pin_of() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
sc_pin="$(pin_of VKS_STORAGE_CLASS)"; cc_pin="$(pin_of VKS_CLUSTERCLASS)"

# ⚠️ TWO REVIEW FINDINGS COLLIDE HERE AND THE TIE IS BROKEN DELIBERATELY. "Never destroy a
# deliberate pin" and "repair a stale one" give opposite answers for a pin naming a class this
# Supervisor does not have. Repair wins: that pin CANNOT work here — the create is rejected
# `storage class(es): <pin> not found` — so preserving it only makes the tool unable to fix the
# failure it exists to prevent. The pin is still read from the FILE, so SKIP_DOTENV=1 cannot make a
# VALID pin look unset and clobber it; only a provably-absent one is replaced, and loudly.
# A pin that names something this Supervisor does NOT have is not a preference — it is a stale
# value carried from another lab, and refusing to touch it makes the tool unable to repair the very
# failure it exists to prevent. Overwrite ONLY in that case, and say so loudly.
sc_stale=0
if [ -n "$sc_pin" ] && [ -n "$sc_all" ] && ! printf '%s\n' "$sc_all" | grep -qxF "$sc_pin"; then sc_stale=1; fi
cc_stale=0
if [ -n "$cc_pin" ] && [ -n "$cc_live" ] && ! printf '%s\n' "$cc_live" | grep -qxF "$cc_pin"; then cc_stale=1; fi

if [ -n "$sc_pin" ] && [ "$sc_stale" = 0 ]; then
  log_info "= VKS_STORAGE_CLASS already set (${sc_pin}) — not overwriting"
elif [ "$sc_n" = 1 ]; then
  set_env_var VKS_STORAGE_CLASS "$sc_pick" "$ENV_FILE"; wrote=$((wrote+1))
  log_info "+ VKS_STORAGE_CLASS = ${sc_pick}  (the policy assigned to ${NS})"
elif [ "${sc_n:-0}" -gt 1 ] 2>/dev/null; then
  log_warn "? VKS_STORAGE_CLASS AMBIGUOUS — ${NS} has more than one assigned policy. Pick one, set it by hand:"
  printf '%s\n' "$sc_pick" | while IFS= read -r c; do [ -n "$c" ] && printf '      %s\n' "$c"; done
elif [ "${sc_multizone:-0}" = 1 ]; then
  log_warn "? VKS_STORAGE_CLASS NOT auto-set — ${NS} has ${zones} zones, and a multi-zone namespace"
  log_warn "    REQUIRES a -latebinding class for machineDeployment (worker) volumes, while this repo"
  log_warn "    renders ONE storageClass for the whole topology. Set it by hand and check the workers."
elif [ -n "$sc_all" ]; then
  # The quota WAS readable and returned classes — they are all WaitForFirstConsumer. Blaming RBAC
  # here sends the operator to fix something that is fine, and the create then proceeds on a code
  # default that does not exist in this namespace.
  log_warn "? VKS_STORAGE_CLASS NOT auto-set — ${NS} has only WaitForFirstConsumer (-latebinding)"
  log_warn "    classes assigned. Pick one by hand and check the worker volumes:"
  printf '%s\n' "$sc_all" | while IFS= read -r c; do [ -n "$c" ] && printf '      %s\n' "$c"; done
else
  log_warn "- VKS_STORAGE_CLASS not discovered — nothing readable at storagepolicyquota in ${NS}"
  log_warn "    (a tenant may lack RBAC there; 'make vks-shape-show' prints what this identity sees)"
fi

if [ -n "$cc_pin" ] && [ "$cc_stale" = 0 ]; then
  log_info "= VKS_CLUSTERCLASS already set (${cc_pin}) — not overwriting"
elif [ -n "$cc_newest" ]; then
  set_env_var VKS_CLUSTERCLASS "$cc_newest" "$ENV_FILE"; wrote=$((wrote+1))
  log_info "+ VKS_CLUSTERCLASS = ${cc_newest}  (newest non-deprecated — admission would pick it anyway)"
else
  log_warn "- VKS_CLUSTERCLASS not discovered (no clusterclass readable in ${ccns})"
fi
log_info "wrote ${wrote} value(s) to ${ENV_FILE}"
