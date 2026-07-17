#!/usr/bin/env bash
# 49-psa-check.sh — for every namespace WE create: what is the MINIMUM Pod Security Standard its
# running pods actually satisfy, and is the level we label it with sufficient?
#
# Read-only. Changes nothing.
#
# Why it matters: a VKS guest cluster ENFORCES `restricted` by default from VKS/TKr v1.26 —
# "pods violating security are rejected unless namespace configuration is changed" (Broadcom,
# "Configure PSA for VKr 1.25 and Later"). Only kube-system / tkg-system /
# vmware-system-cloud-provider are exempt. KinD enforces nothing, so a stack that installs
# cleanly locally can have its pods rejected outright on a real lab, invisibly.
#
# HOW (this is the honest part): `kubectl label --dry-run=server ns <ns>
# pod-security.kubernetes.io/enforce=<level>` makes the API SERVER evaluate every EXISTING pod in
# that namespace against <level> and return the violations as warnings — without changing
# anything. So the minimum level is MEASURED against the real workloads, not guessed from what
# their charts are supposed to do.
#
# Run it against KinD to derive the levels, and against a real VKS guest cluster to prove the
# levels we ship are sufficient there too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# One namespace per app — the list comes from the registry, never hardcoded.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# shellcheck source=scripts/lib/psa.sh
. "${SCRIPT_DIR}/lib/psa.sh"
load_env

require_cmd kubectl
: "${KUBECONFIG:?KUBECONFIG must be set (see .env.example / .env.kind)}"; export KUBECONFIG

# The namespaces we own, paired with the level this repo labels them with.
NS_SPEC="
${GITEA_NAMESPACE:-gitea}|${PSA_LEVEL_GITEA:-}
${TEKTON_NAMESPACE:-tekton-pipelines}|${PSA_LEVEL_TEKTON:-}
${CI_NAMESPACE:-ci}|${PSA_LEVEL_CI:-}
$(app_names | while read -r a; do if [ -n "$a" ]; then printf "%s|${PSA_LEVEL_APP:-}\n" "$a"; fi; done)
${TRAEFIK_NAMESPACE:-traefik}|${PSA_LEVEL_TRAEFIK:-}
${ISTIO_GWAPI_NAMESPACE:-vks-ingress}|${PSA_LEVEL_INGRESS:-}
${ISTIO_GATEWAY_NAMESPACE:-istio-ingress}|${PSA_LEVEL_INGRESS:-}
${ISTIO_NAMESPACE:-istio-system}|${PSA_LEVEL_ISTIO_SYSTEM:-}
"

# Lowest level that admits every existing pod in <ns>, or "" if even privileged complains.
psa_min_level() { # <ns>
  local ns="$1" level out
  for level in restricted baseline privileged; do
    out="$(kubectl label --dry-run=server --overwrite namespace "$ns" \
             "pod-security.kubernetes.io/enforce=${level}" 2>&1 >/dev/null || true)"
    printf '%s' "$out" | grep -qi 'violate' || { printf '%s' "$level"; return 0; }
  done
  return 1
}

# Is `have` at least as permissive as `need`?
psa_rank() { case "$1" in restricted) echo 0 ;; baseline) echo 1 ;; privileged) echo 2 ;; *) echo -1 ;; esac; }

echo "===================== PSA check =====================" >&2
log_info "cluster: $(kubectl config current-context 2>/dev/null || echo '<unknown>')"
log_info "VKS enforces 'restricted' by DEFAULT (VKr v1.26+). Every namespace we create needs a level that admits its pods."
echo >&2
printf "  %-22s %-8s %-12s %-12s %s\n" NAMESPACE PODS "NEEDS(min)" "ACTUAL" VERDICT >&2

rc=0
# COUNT THE DENOMINATOR. This gate used to exit 0 on a fresh cluster having measured NOTHING: every
# namespace was `absent (skipped)`, and `absent` never touched rc. So `make psa-check` was GREEN BY
# CONSTRUCTION before any of our code had run — and scenario-1 instructed it as a Step-1 precondition
# with the words "psa-check proves the cluster will admit them". It proved nothing; it could not.
#
# A green that was already true before the change exists cannot fail for the right reason. So: count what
# we actually measured, and say so. (We still exit 0 when there is genuinely nothing to measure — a fresh
# cluster is a legitimate state, and `preflight` runs here before `platform` — but the OUTPUT must not
# read as proof, and it must say when to come back.)
measured=0; skipped=0; unproven=0
while IFS='|' read -r ns labelled; do
  [ -z "$ns" ] && continue
  kubectl get namespace "$ns" >/dev/null 2>&1 || { printf '  %-22s %-8s %-12s %-12s %s\n' "$ns" '-' '-' "${labelled:-<none>}" 'absent (skipped)' >&2; skipped=$((skipped+1)); continue; }
  pods="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$pods" = "0" ]; then unproven=$((unproven+1)); else measured=$((measured+1)); fi
  need="$(psa_min_level "$ns" || true)"
  cur="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"

  # The verdict MUST be based on the label the namespace ACTUALLY carries — that is what the API
  # server enforces. Judging by the level we *configured* in .env instead would report our INTENT
  # and miss the case that matters: a namespace created before the label was wired, or by a chart
  # we don't control, carries NO label — and an unlabelled namespace on VKS falls back to the
  # cluster default (`restricted`), which is exactly where the pods get rejected. (This gate said
  # "OK" for two such namespaces until it was corrected — the same read-your-own-intent false
  # green this repo has now hit twice.)
  # In istio-existing mode the mesh namespaces belong to the PLATFORM TEAM. We must not judge
  # (or relabel) what we do not own — report them for information only.
  ours=1
  if [ "${INGRESS_CONTROLLER:-istio}" = "istio-existing" ]; then
    case "$ns" in
      "${ISTIO_NAMESPACE:-istio-system}"|"${ISTIO_GATEWAY_NAMESPACE:-istio-ingress}") ours=0 ;;
    esac
  fi

  eff="${cur:-restricted}"           # unlabelled => VKS's default
  verdict="OK"
  if [ -z "$need" ]; then
    verdict="UNKNOWN (even privileged warned)"; rc=1
  elif [ "$pods" = "0" ]; then
    verdict="no pods yet — level unproven"
  elif [ "$ours" -eq 0 ]; then
    verdict="platform-owned (needs ${need}) — informational, not ours to label"
  elif [ "$(psa_rank "$eff")" -lt "$(psa_rank "$need")" ]; then
    if [ -z "$cur" ]; then
      verdict="UNLABELLED -> VKS default 'restricted' REJECTS these pods (need ${need})"
    else
      verdict="TOO STRICT — pods would be REJECTED on VKS (need ${need})"
    fi
    rc=1
  elif [ "$(psa_rank "$eff")" -gt "$(psa_rank "$need")" ]; then
    verdict="looser than necessary (could tighten to ${need})"
  fi
  printf '  %-22s %-8s %-12s %-12s %s\n' "$ns" "$pods" "${need:-?}" "${cur:-<UNLABELLED>}" "$verdict" >&2
  [ "$ours" -eq 1 ] && [ -n "$labelled" ] && [ "$labelled" != "$cur" ] && \
    printf '      configured level is %s but the namespace carries %s — re-run the installer to apply it\n' \
      "$labelled" "${cur:-<none>}" >&2

  # When a namespace cannot run restricted, SAY WHY — a bare level is not actionable.
  if [ -n "$need" ] && [ "$need" != "restricted" ] && [ "$pods" != "0" ]; then
    kubectl label --dry-run=server --overwrite namespace "$ns" \
      pod-security.kubernetes.io/enforce=restricted 2>&1 >/dev/null \
      | sed -e 's/^Warning: //' -e "s/^/      why not restricted: /" | head -3 >&2 || true
  fi
done <<EOF
$(printf '%s' "$NS_SPEC")
EOF

echo >&2
# THE DENOMINATOR IS PART OF THE VERDICT. A gate that cannot tell you what it looked at cannot be
# trusted to have looked.
log_info "measured ${measured} namespace(s) with running pods · ${unproven} present-but-empty · ${skipped} absent"
if [ "$rc" -eq 0 ] && [ "$measured" -eq 0 ]; then
  log_warn "PSA UNPROVEN — this run measured NOTHING. Every namespace is absent or has no pods yet, so PSA"
  log_warn "  admission was never actually exercised. This is the EXPECTED state before 'make platform'; it is"
  log_warn "  NOT evidence that the cluster will admit our workloads."
  log_warn "  Come back and re-run 'make psa-check' AFTER 'make platform' — that run is the one that proves it."
elif [ "$rc" -eq 0 ]; then
  log_info "PSA OK — every namespace we create is labelled at a level that admits its pods (${measured} measured)."
else
  log_error "PSA FINDINGS above — on a real VKS guest cluster (enforce=restricted by default) those pods would be REJECTED."
  log_error "  Fix by setting the level in .env (PSA_LEVEL_GITEA / _TEKTON / _CI / _APP / _INGRESS / _ISTIO_SYSTEM),"
  log_error "  or by making the workload restricted-compliant (runAsNonRoot, drop ALL caps, seccompProfile RuntimeDefault)."
fi
echo "=====================================================" >&2
exit "$rc"
