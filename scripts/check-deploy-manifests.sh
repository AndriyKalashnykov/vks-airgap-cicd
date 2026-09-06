#!/usr/bin/env bash
# check-deploy-manifests.sh — invariants EVERY app's deploy/<app>/deployment.yaml must hold.
#
# Renamed from check-pull-secret-alignment.sh when the second invariant landed. It is ONE loop
# over apps/registry.tsv reading ONE file per app; a second gate would have forked that loop,
# and a third would have forked it again. New deploy-manifest invariants belong HERE.
#
# (1) the image-pull Secret: every manifest must reference the SAME one
# Secret that 70-configure-argocd.sh actually creates.
#
# WHY THIS IS A GATE
# ------------------
# The pull Secret is created by a SCRIPT (into the app's namespace, on the guest cluster); the
# reference to it lives in deploy/<app>/deployment.yaml — a GitOps manifest ArgoCD applies VERBATIM
# from the Gitea repo. Those manifests are never envsubst-rendered, so the name cannot be a variable
# on both sides: it is a constant in scripts/lib/argocd.sh (HARBOR_PULL_SECRET) and a literal in the
# manifest. Two copies of one name is exactly the drift this repo has been bitten by before
# (see check-image-alignment).
#
# And the drift is SILENT in the demo's default configuration: with HARBOR_PUBLIC_PROJECTS=true (the
# KinD default) the pull Secret is not needed at all, so a mismatched name changes nothing. It only
# bites the TENANT (private Harbor project) — as ImagePullBackOff, with no clue pointing here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"

rc=0
n=0
while read -r app; do
  [ -n "$app" ] || continue
  f="${REPO_ROOT}/$(app_deploy "$app")/deployment.yaml"
  n=$((n + 1))
  if [ ! -f "$f" ]; then
    log_error "app '${app}': no deploy manifest at ${f#"${REPO_ROOT}/"}"
    rc=1; continue
  fi
  # The name(s) this Deployment actually asks kubelet for.
  got="$(grep -A3 '^[[:space:]]*imagePullSecrets:' "$f" | sed -n 's/^[[:space:]]*-[[:space:]]*name:[[:space:]]*//p' | tr -d '\r')"
  if [ -z "$got" ]; then
    log_error "app '${app}': ${f#"${REPO_ROOT}/"} declares NO imagePullSecrets."
    log_error "    With a PRIVATE Harbor project (HARBOR_PUBLIC_PROJECTS=false — the tenant default)"
    log_error "    every pod in ns/${app} will ImagePullBackOff. Add:"
    log_error "        imagePullSecrets:"
    log_error "          - name: ${HARBOR_PULL_SECRET}"
    rc=1; continue
  fi
  if ! printf '%s\n' "$got" | grep -qx "$HARBOR_PULL_SECRET"; then
    log_error "app '${app}': deploy manifest asks for pull secret '$(printf '%s' "$got" | tr '\n' ' ')'"
    log_error "    but 70-configure-argocd.sh creates '${HARBOR_PULL_SECRET}' (scripts/lib/argocd.sh)."
    log_error "    kubelet would find no credential -> ImagePullBackOff on a private Harbor project."
    rc=1; continue
  fi
  log_info "ok    ${app}: deploy manifest references '${HARBOR_PULL_SECRET}' (the Secret 70 creates)"

  # ---- (2) revisionHistoryLimit: PRESENT, numeric, and the SAME across every app ----------------
  # Absent means the Kubernetes DEFAULT of 10, which is what this gate exists to move away from:
  # every `make verify` run is one rollout, so the retained ReplicaSets are a log of verify runs.
  # MEASURED 2026-09-06 before the change: 11 ReplicaSets per app at revision 23 -- an ArgoCD
  # resource tree nobody can read, for objects holding 0 replicas.
  #
  # ⚠️ IT ASSERTS AGREEMENT, NOT A PARTICULAR NUMBER. The value is a policy choice; six copies of it
  # is the defect a gate can actually see. Same shape as check-image-alignment. Changing the policy
  # means editing all six -- and this is what catches editing five.
  rhl="$(sed -n 's/^[[:space:]]*revisionHistoryLimit:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$f" | head -1)"
  if [ -z "$rhl" ]; then
    log_error "app '${app}': ${f#"${REPO_ROOT}/"} declares NO revisionHistoryLimit."
    log_error "    Kubernetes then defaults to 10, and every rollout retains another ReplicaSet."
    log_error "    Add it under spec:, alongside replicas:   revisionHistoryLimit: ${_rhl_want:-3}"
    rc=1; continue
  fi
  if [ -z "${_rhl_want:-}" ]; then
    _rhl_want="$rhl"; _rhl_first="$app"
  elif [ "$rhl" != "$_rhl_want" ]; then
    log_error "app '${app}': revisionHistoryLimit=${rhl}, but '${_rhl_first}' declares ${_rhl_want}."
    log_error "    Six copies of one policy value; they must agree or the apps retain different"
    log_error "    amounts of rollback history for no stated reason."
    rc=1; continue
  fi
  log_info "ok    ${app}: revisionHistoryLimit=${rhl}"
done <<EOF
$(app_names)
EOF

if [ "$rc" = 0 ]; then
  [ "$n" -gt 0 ] || die "check-deploy-manifests: checked 0 app(s) — apps/registry.tsv is empty or app_names is broken. The gate has gone BLIND."
  # Report BOTH invariants. A summary naming one of two is a gate that undersells what it proved,
  # and the next reader trusts it for less than it is worth -- or, worse, adds a third invariant and
  # never updates this line.
  log_info "check-deploy-manifests: OK — ${n} app(s): pull Secret '${HARBOR_PULL_SECRET}' referenced, revisionHistoryLimit=${_rhl_want:-?} on all."
else
  log_error "check-deploy-manifests: FAILED (checked ${n} app(s))"
fi
exit "$rc"
