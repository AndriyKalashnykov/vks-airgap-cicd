#!/usr/bin/env bash
# creds.sh — print the access summary (URLs + logins) for the CURRENT context.
#
# One command for both contexts: it resolves URLs from .env (+ the .env.kind overlay the
# KinD flow writes) and the ArgoCD password via argocd-password.sh (which self-selects the
# right source). These are LOCAL DEMO credentials the operator set in .env — printing them
# to the operator's own terminal is the intended function, not a leak (no value touches argv).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# --- resolve URLs ---------------------------------------------------------------------
# Harbor keeps its OWN LB (not behind the ingress); http when HARBOR_INSECURE=1 (KinD).
harbor_scheme="https"; [ "${HARBOR_INSECURE:-0}" = "1" ] && harbor_scheme="http"
harbor_url="${harbor_scheme}://${HARBOR_URL:-harbor.vks.local}"
# Gitea/app/Tekton are fronted by the ingress at their *.vks.local hosts (http in the demo).
gitea_url="${GITEA_URL:-http://${GITEA_HOST:-gitea.vks.local}}"
# ArgoCD is on its OWN LoadBalancer (like real VKS): KinD publishes ARGOCD_LB_IP to .env.kind
# (scheme https unless ARGOCD_INSECURE=1); a real lab uses the lab's own ArgoCD URL.
argo_scheme="https"; [ "${ARGOCD_INSECURE:-0}" = "1" ] && argo_scheme="http"
if [ -n "${ARGOCD_LB_IP:-}" ]; then
  argocd_url="${argo_scheme}://${ARGOCD_LB_IP} (self-signed; --insecure)"
elif [ -n "${ARGOCD_SERVER:-}" ]; then
  # A REAL LAB. ARGOCD_LB_IP is published only by the KinD flow (07-install-argocd.sh), so on a lab
  # this used to print the literal '<your lab's ArgoCD URL>' — while the operator had ALREADY told us
  # the address in ARGOCD_SERVER (both scenario runbooks have them discover and set it, and every
  # argocd-CLI call uses it). We were asking them to look up a value we were holding.
  case "$ARGOCD_SERVER" in
    http://*|https://*) argocd_url="$ARGOCD_SERVER" ;;
    *)                  argocd_url="${argo_scheme}://${ARGOCD_SERVER}" ;;
  esac
else
  argocd_url="<not set — discover it, then set ARGOCD_SERVER in .env (see docs/scenario-2.md)>"
fi
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
tekton_url="http://${TEKTON_DASHBOARD_HOST:-tekton.vks.local}"  # Tekton Dashboard (read-only UI)

# --- resolve logins -------------------------------------------------------------------
harbor_user="${HARBOR_USERNAME:-admin}"
harbor_pw="${HARBOR_PASSWORD:-<set HARBOR_PASSWORD in .env>}"
gitea_user="${GITEA_ADMIN_USER:-gitea_admin}"
gitea_pw="${GITEA_ADMIN_PASSWORD:-<set GITEA_ADMIN_PASSWORD in .env>}"
# ArgoCD via the context-aware resolver; exit 3 => VKS-provided / not knowable locally.
if argo_pw="$("${SCRIPT_DIR}/argocd-password.sh" 2>/dev/null)"; then :; else
  argo_pw="<VKS-provided — get it from your lab>"
fi

# --- /etc/hosts helper (KinD ingress) -------------------------------------------------
echo "Access the UIs (local demo credentials):"
if [ -n "${INGRESS_LB_IP:-}" ]; then
  echo
  echo "  add once to /etc/hosts so the *.vks.local hosts resolve to the ingress LB:"
  echo "    ${INGRESS_LB_IP}  ${GITEA_HOST:-gitea.vks.local} ${TEKTON_DASHBOARD_HOST:-tekton.vks.local} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
fi

# --- table ----------------------------------------------------------------------------
printf '\n  %-9s %-32s %-14s %s\n' "Service" "URL" "Username" "Password"
printf '  %-9s %-32s %-14s %s\n'   "-------" "---" "--------" "--------"
# Ordered by the pipeline flow: Gitea (push) -> Tekton (build) -> Harbor (registry)
# -> ArgoCD (deploy) -> App. Tekton is in-cluster CI with no web UI.
printf '  %-9s %-32s %-14s %s\n'   "Gitea"   "$gitea_url"  "$gitea_user"  "$gitea_pw"
printf '  %-9s %-32s %-14s %s\n'   "Tekton"  "$tekton_url" "-"            "(no login; read-only dashboard)"
printf '  %-9s %-32s %-14s %s\n'   "Harbor"  "$harbor_url" "$harbor_user" "$harbor_pw"
printf '  %-9s %-32s %-14s %s\n'   "ArgoCD"  "$argocd_url" "admin"        "$argo_pw"
while read -r _a; do
  [ -n "$_a" ] || continue
  printf '  %-9s %-32s %-14s %s\n' "$_a" "http://$(app_host "$_a")" "-" "(no login; health at $(app_health_path "$_a"))"
done <<EOF
$(app_names)
EOF
echo
