#!/usr/bin/env bash
# 24-vks-k8s-version.sh — pick the newest Ready+Compatible TKr and publish it as VKS_K8S_VERSION.
#
# WHAT IT REPLACES — an eyeball over ~67 rows
# ------------------------------------------
# scenario-1 Step 6 said: "kubectl get kubernetesreleases -> pick one that is Ready AND Compatible
# and paste its full name." A fresh Supervisor publishes dozens and marks only some usable, so the
# reader is scanning two boolean columns by eye and retyping a string like
# `v1.35.5+vmware.1-vkr.1` -- where a single wrong character is a cluster that never creates.
#
# The repo already knew how: nested-vsphere-lab's walk harness has resolved exactly this for every
# row (`awk '$3=="True" && $4=="True"' | sort -V | tail -1`). The reader was the only one doing it by
# hand.
#
# AND THEY ARE NOT ALL READY AT ONCE. A freshly-enabled Supervisor syncs its TKr content library over
# several minutes: MEASURED 2026-08-12, a lab whose Supervisor had just come up listed 8 releases
# with ZERO Ready, and the newest went Ready+Compatible about a minute later. A point-in-time read
# therefore tells a reader "this lab has nothing usable" about a lab that is merely still starting --
# which is why this waits.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env
require_cmd kubectl

SUP="$(supervisor_kubeconfig_or_die 'the TKr list')"

WAIT="${VKS_TKR_WAIT_SECONDS:-900}"
case "$WAIT" in
  ''|*[!0-9]*) die "VKS_TKR_WAIT_SECONDS must be WHOLE SECONDS, got '${WAIT}' (900, not 15m)" ;;
esac

# `sort -V` is NUMERIC-aware, which is the whole point: lexically, v1.9.1 sorts AFTER v1.25.13.
# Verified on this lab's real strings: v1.9.1 < v1.25.13 < v1.33.3 < v1.35.2 < v1.35.5.
# THE READ IS SEPARATE FROM THE FILTER, so kubectl's own rc survives. As one pipeline its status was
# awk's, and `2>/dev/null` threw the reason away — which is how a transport failure became "no
# releases are Ready yet" (B110). SEE _TKR_RC / _TKR_ERR below.
_TKR_ERR="$(mktemp)"; _TKR_OUT="$(mktemp)"; _TKR_OSI="$(mktemp)"; _TKR_OSI_ERR="$(mktemp)"
trap 'rm -f "$_TKR_ERR" "$_TKR_OUT" "$_TKR_OSI" "$_TKR_OSI_ERR"' EXIT
_TKR_RC=0
# THE READ RUNS IN THIS SHELL, NOT IN A SUBSTITUTION. A first attempt set _TKR_RC inside a function
# called as `v="$(_newest_ready)"` — a COMMAND SUBSTITUTION IS A SUBSHELL, so the assignment was
# discarded and every classification silently fell through to the wait loop. Measured: the test
# still burned the full budget and still blamed the content library. The fix is to write kubectl's
# output to a FILE and read its rc here, then filter the file — no pipeline, no subshell.
_tkr_read() {
  _TKR_RC=0
  kubectl --kubeconfig "$SUP" --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-15s}" \
    get kubernetesreleases --no-headers >"$_TKR_OUT" 2>"$_TKR_ERR" || _TKR_RC=$?
  # The OS IMAGES are read HERE, in the same function, so the wait loop below re-reads BOTH.
  # A failure is deliberately non-fatal: an empty file makes _newest_ready return nothing, which
  # the existing wait/classify path already handles as "nothing usable yet".
  # rc AND stderr, for the same reason the TKr read above captures them: `2>/dev/null` made a
  # FORBIDDEN, an absent CRD and a transport failure indistinguishable from "no OSImage exists", and
  # an empty file makes the filter below emit NOTHING — so the script burned the full wait budget and
  # then offered two hypotheses that exclude the true one.
  #
  # ⚠️ NO die arm, and NO `case`. Three measured reasons:
  #  - control only reaches here with _TKR_RC==0, so the SAME kubeconfig/endpoint/TLS just worked
  #    seconds ago; the only class that can structurally differ is FORBIDDEN (RBAC is per-resource).
  #  - this runs up to 60x from the wait loop, so a die would let one transient blip kill a
  #    RECOVERABLE wait on the freshly-syncing Supervisor the wait exists for.
  #  - an ABSENT `osimages` CRD classifies UNKNOWN (measured, both kubectl wordings), and the TKr
  #    arm's `*)` DIES — copying that structure would refuse a Supervisor that worked before the
  #    OSImage cross-check was introduced.
  # And `check-classifier-consumers.sh` requires every CASE-form consumer to handle all 8 classes;
  # interpolating the class is the shape it exempts (precedent: 23-argocd-preflight.sh).
  _osi_rc=0
  kubectl --kubeconfig "$SUP" --request-timeout="${KUBECTL_REQUEST_TIMEOUT:-15s}" \
    get osimages -o custom-columns='K8S:.spec.kubernetesVersion,OS:.spec.os.name' --no-headers \
    >"$_TKR_OSI" 2>"$_TKR_OSI_ERR" || _osi_rc=$?
  if [ "$_osi_rc" -ne 0 ]; then
    # FAIL CLOSED: a PARTIAL list would silently narrow have[] and could pick a wrong version or
    # miss the right one. Truncation is the one thing the old line got right; keep it.
    : >"$_TKR_OSI"
    _OSI_UNUSABLE=1
    if [ -z "${_OSI_WARNED:-}" ]; then    # LATCH — 60 iterations must not emit 60 copies
      _OSI_WARNED=1
      log_warn "could not read the OSImages ($(classify_kube_failure "$_TKR_OSI_ERR")) — the OSImage"
      log_warn "  cross-check is SKIPPED, so any release reported below is Ready+Compatible but"
      log_warn "  UNVERIFIED for a ${VKS_OS_NAME:-photon} node image: 'make vks-cluster-create' may"
      log_warn "  still be denied with \"Could not resolve KR/OSImage\"."
      log_warn "  If that verdict is FORBIDDEN it is an RBAC grant on osimages (a DIFFERENT resource"
      log_warn "  from kubernetesreleases, which just succeeded) — NOT a broken kubeconfig, so do not"
      log_warn "  re-fetch it. Ask for:  kubectl auth can-i list osimages"
    fi
  else
    _OSI_UNUSABLE=0
  fi
}
# READY + COMPATIBLE IS NOT ENOUGH. The admission webhook resolves a KubernetesRelease AND an
# OSImage, and the two arrive on INDEPENDENT timelines. MEASURED 2026-08-16: this filter picked
# v1.34.2+vmware.2-vkr.2 (Ready+Compatible since 14:29:13); the create at 14:37:26 was REJECTED with
#   admission webhook "tkr-resolver-cluster-webhook.tanzu.vmware.com" denied the request:
#   Could not resolve KR/OSImage ... {k8sVersionPrefix: v1.34.2+vmware.2-vkr.2, osImageSelector: os-name=photon}
# because that release's photon OSImage was not created until 14:40:58 — 3m32s AFTER the rejection.
# Two other releases (v1.34.8, v1.35.5) had theirs and would have worked. So an operator following
# the runbook got an error naming a release that `kubectl get kubernetesreleases` shows as True True:
# an error contradicted by the very command the runbook told them to run.
#
# The join: an OSImage's spec.kubernetesVersion is the KR's version MINUS its `-vkr.N` suffix
# (v1.34.2+vmware.2-vkr.2 -> v1.34.2+vmware.2). VERIFIED on a live Supervisor across all 6 usable
# releases, including the `-fips` shape (v1.33.6+vmware.1-fips-vkr.2 -> v1.33.6+vmware.1-fips).
# os-name=photon is the builtin-generic ClusterClass default, not ours — hence VKS_OS_NAME.
_newest_ready() {   # call _tkr_read FIRST; this only filters what it fetched
  # skip_osi=1 ONLY when the osimages read itself failed: emitting nothing there would turn an
  # unreadable cross-check into "no usable release", which is the misdiagnosis this fix removes. A
  # read that SUCCEEDED and returned nothing still filters normally — that is a real fact.
  awk -v osi="$_TKR_OSI" -v want_os="${VKS_OS_NAME:-photon}" -v skip_osi="${_OSI_UNUSABLE:-0}" '
    BEGIN { if (skip_osi != 1) while ((getline line < osi) > 0) { n=split(line, f, /[ \t]+/); if (n>=2 && f[2]==want_os) have[f[1]]=1 } }
    $3=="True" && $4=="True" {
      base=$2; sub(/-vkr\.[0-9]+$/, "", base)
      if (skip_osi == 1 || base in have) print $2
    }' "$_TKR_OUT" 2>/dev/null | sort -V | tail -1
}

_tkr_read
v="$(_newest_ready || true)"

# CLASSIFY BEFORE SPENDING THE BUDGET. This used to enter the wait loop on an empty result whatever
# the reason, burn up to VKS_TKR_WAIT_SECONDS (900s), and then declare "Every release is published
# but unusable, which is a Supervisor/content-library problem" — a confident platform diagnosis
# derived from a connection that never succeeded. Waiting cannot fix a stale CA or a missing grant,
# so it is 15 minutes spent to reach a conclusion that was already wrong.
if [ "$_TKR_RC" -ne 0 ]; then
  _hint="Re-issue it:  make vks-login   (scenario-1 Step 3)"
  # WRONG-CLUSTER BEFORE WRONG-CREDENTIAL. classify_kube_failure reads an ERROR STRING, so it
  # cannot see that we authenticated perfectly well against a cluster that simply is not a
  # Supervisor -- it lands in UNAUTHORIZED/FORBIDDEN and blames the credential. MEASURED
  # 2026-08-22 against the live guest: this died with "the Supervisor REJECTED these
  # credentials", sending the operator to re-run `make vks-login` for a kubeconfig that was
  # working. B210's class: an answer about WHICH CLUSTER you asked, read as an answer about
  # what is installed.
  # rc==1 ONLY: rc==2 means we could not determine (unreachable / stale CA), and that must fall
  # through to classify_kube_failure, which has the right words for those.
  kubeconfig_is_supervisor "$SUP"; _sup_rc=$?
  if [ "$_sup_rc" -eq 1 ]; then
    not_a_supervisor_note >&2   # called directly: $( ) strips the trailing newline, so the
                                # die below would run straight into the last line of the note.
    die "cannot list TKr releases: '${SUP}' is not a Supervisor (see above). The releases were
  never read, so this says nothing about which exist."
  fi
  case "$(classify_kube_failure "$_TKR_ERR")" in
    STALE_CA)     die "could not LIST the TKr releases: '${SUP}' does not work against this cluster,
  and the server ANSWERED — a REBUILT cluster mints a new CA while the address stays the same. The
  releases were never read, so this says nothing about them, and waiting cannot change it. ${_hint}" ;;
    UNAUTHORIZED) die "the Supervisor REJECTED these credentials, so the TKr list was never read.
  This says nothing about which releases exist. ${_hint}" ;;
    FORBIDDEN)    die "authenticated, but this identity may not LIST kubernetesreleases, so we cannot
  tell which TKr are usable. That is an RBAC GRANT, not a broken kubeconfig — do NOT re-fetch it.
  Ask your platform admin for the TKr version and set VKS_K8S_VERSION in .env." ;;
    UNREACHABLE)  die "could not reach the Supervisor at all, so the TKr list was never read. This is
  NOT evidence your kubeconfig is stale — check the address and the network." ;;
    PLAINTEXT)    die "the Supervisor endpoint answered PLAINTEXT where TLS was expected; the TKr list
  was never read. Check the server URL in '${SUP}'." ;;
    NO_KUBE_TARGET) die "'${SUP}' names no cluster to talk to, so the TKr list was never read. ${_hint}" ;;
    KUBECONFIG_UNUSABLE) die "'${SUP}' is unusable — something it NAMES is missing, unreadable or
  malformed, so the TKr list was never read. ${_hint}" ;;
    *)            log_error "could not list the TKr releases:"
                  sed 's/^/    /' "$_TKR_ERR" >&2
                  die "refusing to wait ${WAIT}s, or to blame the content library, on a probe that did not complete." ;;
  esac
fi

# ONLY NOW is an empty result a fact about the Supervisor's releases.
if [ -z "$v" ] && [ "$WAIT" -gt 0 ]; then
  # Reuse $_TKR_OUT rather than a THIRD round trip whose `2>/dev/null` would let a failed read print
  # "0 release(s) published" — a claim about the Supervisor derived from a read that never completed.
  total="$(grep -c . "$_TKR_OUT" 2>/dev/null || true)"
  log_info "${total:-0} release(s) published, none Ready+Compatible yet — a freshly-enabled Supervisor syncs them over several minutes."
  log_info "waiting up to ${WAIT}s ..."
  _w=0
  while [ "$_w" -lt "$WAIT" ]; do
    sleep 15; _w=$((_w + 15))
    _tkr_read; v="$(_newest_ready || true)"; [ -n "$v" ] && break
    [ $((_w % 60)) = 0 ] && log_info "  still none usable (${_w}/${WAIT}s) ..."
  done
fi

if [ -z "$v" ]; then
  log_error "no Ready AND Compatible TKr on this Supervisor after ${WAIT}s. Nothing was written."
  log_error "  Either every release is published-but-unusable (a Supervisor/content-library problem),"
  log_error "  OR none of the usable ones has a ${VKS_OS_NAME:-photon} OSImage yet — the webhook needs BOTH."
  # FOUR causes reach here, not two, and the OS names are already in hand — so print them instead of
  # sending the operator to wait. A VKS_OS_NAME that matches nothing is a TYPO, not a timing issue,
  # and "has no <os> OSImage YET" mis-frames it as one.
  if [ "${_OSI_UNUSABLE:-0}" = 1 ]; then
    log_error "  OR the OSImages could not be READ at all — see the WARN above; that is neither of the two."
  elif [ -s "$_TKR_OSI" ]; then
    _os_seen="$(awk '{ if (NF>=2) print $2 }' "$_TKR_OSI" 2>/dev/null | sort -u | tr '\n' ' ')"
    log_error "  OS names actually present in the OSImages: ${_os_seen:-<none>}"
    log_error "  If ${VKS_OS_NAME:-photon} is not in that list, VKS_OS_NAME is wrong — waiting cannot fix a typo."
  fi
  log_error "  Check the second one with:"
  log_error "    kubectl --kubeconfig ${SUP} get osimages -o custom-columns=K8S:.spec.kubernetesVersion,OS:.spec.os.name"
  log_error "  not something a cluster name can work around. Look at the two boolean columns:"
  log_error "    kubectl --kubeconfig ${SUP} get kubernetesreleases"
  exit 1
fi

# NON-DESTRUCTIVE. VKS_K8S_VERSION is a deliberate PIN: an operator who chose an older release to
# match something else must not have it silently moved forward by a target they ran for information.
if ! is_placeholder "${VKS_K8S_VERSION:-}" && [ "${VKS_K8S_VERSION}" != "$v" ]; then
  log_warn "VKS_K8S_VERSION is already pinned to '${VKS_K8S_VERSION}' - NOT overwriting it with the newest (${v})."
  log_warn "  Change it in .env yourself if you want to move."
else
  set_env_var VKS_K8S_VERSION "$v" "${REPO_ROOT}/.env"
  log_info "wrote VKS_K8S_VERSION=${v} to ./.env  (newest Ready+Compatible)"
fi

# The FULL name, deliberately: it is a PREFIX selector, so a bare `v1.35` is accepted and then
# FLOATS to whatever matches later -- which an air-gap repo must never do.
echo
echo "  VKS_K8S_VERSION: ${VKS_K8S_VERSION:-$v}"
echo
