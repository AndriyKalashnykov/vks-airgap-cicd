#!/usr/bin/env bash
# check-pull-secret-alignment.sh — every app's deploy manifest must reference the SAME image-pull
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
done <<EOF
$(app_names)
EOF

if [ "$rc" = 0 ]; then
  log_info "check-pull-secret-alignment: OK — all ${n} app(s) reference the pull Secret the flow actually creates."
else
  log_error "check-pull-secret-alignment: FAILED (checked ${n} app(s))"
fi
exit "$rc"
