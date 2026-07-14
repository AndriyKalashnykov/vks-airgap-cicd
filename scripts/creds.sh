#!/usr/bin/env bash
# creds.sh — print the access summary (URLs + logins) for the CURRENT context, AND SAY WHICH CONTEXT
# THAT IS.
#
# One command for every flow: it resolves URLs from `.env` plus the state overlay the installers publish
# (`.env.state` — NOT `.env.kind`, which was renamed in #192), and the ArgoCD password via
# argocd-password.sh (which self-selects the right source).
#
# It leads with a CONTEXT block, because the table alone is a lie of omission: with nothing installed it
# prints the `.env.example` DEFAULTS (`harbor.vks.local` / `Gitea12345!`), which look exactly like real,
# live credentials. The reader must be told whether the values are DISCOVERED or DEFAULT before they read
# a single row.
#
# Printing these to the operator's own terminal is the intended function, not a leak (no value touches
# argv). On a real lab the passwords are the operator's own or the lab's; they are only "demo" credentials
# in the KinD stand-in.
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
  # A SENTENCE IN A URL COLUMN DESTROYS THE TABLE. Keep the cell short and put the instruction in a
  # footnote under the table — the reader still gets the whole message, and every other row stays legible.
  #
  # The note must be right in EVERY flow. Two earlier drafts were not:
  #   1. "discover it, then set ARGOCD_SERVER in .env (see docs/scenario-2.md)" — TENANT advice, and it
  #      sent the KinD reader (the likeliest reader of this table) to edit a file they must not edit.
  #   2. "KinD: run 'make install-argocd'" — an instruction they do not need: the KinD flow installs
  #      ArgoCD as part of `make e2e-kind` / `make install-all` and PUBLISHES the address itself.
  # In KinD there is nothing for the operator to DO here, so do not give them a chore — tell them it fills
  # itself in. Only the real lab needs an action.
  argocd_url="<not set>"
  argocd_note="ArgoCD's address is not set yet.  KinD: it is discovered and filled in automatically when ArgoCD is installed.  Real lab: set ARGOCD_SERVER in .env."
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

# --- CONTEXT: where do these values COME FROM? ----------------------------------------
#
# Without this block the table is a LIE OF OMISSION. With no cluster and no state overlay it prints
# `harbor.vks.local` / `Gitea12345!` under the header "local demo credentials" — but those are
# .env.example DEFAULTS, not anything that exists. The reader cannot tell whether they are looking at
# values DISCOVERED from a live cluster or at placeholders for a cluster nobody has built, nor which flow
# they are in. A table that looks authoritative and is not is worse than no table.
#
# So: say which state sink is in effect, whose it is, whether the cluster answers, and — the line that
# actually matters — whether the values below are DISCOVERED or DEFAULT.
_sink="$(state_file)"
_have_sink=0; [ -f "$_sink" ] && _have_sink=1

# Whose state is it? The KinD flow STAMPS the sink (VKS_STATE_KIND=1); a real lab's does not.
if [ "$_have_sink" = 1 ] && grep -q '^VKS_STATE_KIND=1' "$_sink" 2>/dev/null; then
  _flow="KinD stand-in (the state overlay is stamped by the KinD flow)"
elif [ "$_have_sink" = 1 ]; then
  _flow="real lab (a state overlay exists and is NOT KinD-stamped)"
elif [ "${VKS_AUTH_METHOD:-}" = "vcf" ]; then
  _flow="real VKS lab (VKS_AUTH_METHOD=vcf), nothing installed yet"
else
  _flow="undetermined — nothing installed yet (KinD: 'make e2e-kind' · lab: docs/scenario-1.md or scenario-2.md)"
fi

# Does the cluster actually answer? Bounded — never hang the summary on an unreachable API server.
_cluster="not reachable (or KUBECONFIG unset)"
if [ -n "${KUBECONFIG:-}" ] && have kubectl \
   && kubectl --request-timeout=3s version -o json >/dev/null 2>&1; then
  _cluster="reachable — context '$(kubectl config current-context 2>/dev/null || echo '?')'"
fi

printf '\n  Context\n'
printf '    values below : %s\n' \
  "$([ "$_have_sink" = 1 ] \
     && echo "DISCOVERED — read from the state overlay written by the installers" \
     || echo "DEFAULTS from .env / .env.example — NOTHING IS INSTALLED YET, these are placeholders")"
printf '    state overlay: %s\n' \
  "$([ "$_have_sink" = 1 ] && echo "$_sink" || echo "none — no installer has published anything")"
printf '    flow         : %s\n' "$_flow"
printf '    cluster      : %s\n' "$_cluster"

echo
echo "Access the UIs:"

# --- /etc/hosts helper (only when an ingress LB actually exists) -----------------------
if [ -n "${INGRESS_LB_IP:-}" ]; then
  echo
  echo "  add once to /etc/hosts so the *.vks.local hosts resolve to the ingress LB:"
  echo "    ${INGRESS_LB_IP}  ${GITEA_HOST:-gitea.vks.local} ${TEKTON_DASHBOARD_HOST:-tekton.vks.local} $(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done)"
fi

# --- table ----------------------------------------------------------------------------
# WIDTHS ARE COMPUTED FROM THE DATA, never hardcoded. The old `%-9s %-32s %-14s` broke on real input:
# `javawebapp` is 10 chars (so it pushed every following column out of line), and a long value in the URL
# cell shunted Username/Password off into the distance. A table whose alignment depends on nobody ever
# adding a longer app name is a table that will be misaligned — and the registry EXISTS so people add apps.
rows=""
add_row() { rows="${rows}${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4}"$'\n'; }

# Ordered by the pipeline flow: Gitea (push) -> Tekton (build) -> Harbor (registry) -> ArgoCD (deploy) -> apps.
add_row "Gitea"  "$gitea_url"  "$gitea_user"  "$gitea_pw"
add_row "Tekton" "$tekton_url" "-"            "(no login; read-only dashboard)"
add_row "Harbor" "$harbor_url" "$harbor_user" "$harbor_pw"
add_row "ArgoCD" "$argocd_url" "admin"        "$argo_pw"
while read -r _a; do
  [ -n "$_a" ] || continue
  add_row "$_a" "http://$(app_host "$_a")" "-" "(no login; health at $(app_health_path "$_a"))"
done <<EOF
$(app_names)
EOF

# Measure every column against every row (headers included), then print.
w1=7; w2=3; w3=8   # the header widths are the floor: "Service", "URL", "Username"
while IFS=$'\t' read -r c1 c2 c3 _c4; do
  [ -n "$c1" ] || continue
  [ "${#c1}" -gt "$w1" ] && w1="${#c1}"
  [ "${#c2}" -gt "$w2" ] && w2="${#c2}"
  [ "${#c3}" -gt "$w3" ] && w3="${#c3}"
done <<EOF
$rows
EOF

printf '\n  %-*s  %-*s  %-*s  %s\n' "$w1" "Service" "$w2" "URL" "$w3" "Username" "Password"
printf '  %-*s  %-*s  %-*s  %s\n' \
  "$w1" "$(printf '%*s' "$w1" '' | tr ' ' '-')" \
  "$w2" "$(printf '%*s' "$w2" '' | tr ' ' '-')" \
  "$w3" "$(printf '%*s' "$w3" '' | tr ' ' '-')" \
  "$(printf '%*s' 8 '' | tr ' ' '-')"
while IFS=$'\t' read -r c1 c2 c3 c4; do
  [ -n "$c1" ] || continue
  printf '  %-*s  %-*s  %-*s  %s\n' "$w1" "$c1" "$w2" "$c2" "$w3" "$c3" "$c4"
done <<EOF
$rows
EOF

# Footnotes: anything too long for a cell lives here, so the table stays readable.
[ -n "${argocd_note:-}" ] && printf '\n  note: %s\n' "$argocd_note"
echo
