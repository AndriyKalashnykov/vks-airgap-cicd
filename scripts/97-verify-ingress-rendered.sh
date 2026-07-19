#!/usr/bin/env bash
# 97-verify-ingress-rendered.sh — assert the ingress ROUTES WERE RENDERED, in a scope where the app
# backends deliberately do not exist.
#
# WHY THIS IS SEPARATE FROM 98-verify-ingress.sh, WHICH IT DOES NOT TOUCH.
# 98 asserts the full user-facing contract: every host routes to a LIVE backend serving its own body
# marker. That is the right gate for a complete stack, and it correctly FAILS in the air-gap
# sneakernet leg, where `gitops` is out of scope so javawebapp/gowebapp have no pods at all. Narrowing
# 98 with a host-subset knob to make it pass there is exactly the "loosen a verification gate to
# obtain green" anti-pattern this repo exists to prevent (B50 refuted that design in full).
#
# So this is an ADDITIVE check with its own fixed scope. It cannot shrink 98, because it is not 98.
#
# WHAT IT PROVES THAT NOTHING ELSE DOES. In the air-gap leg the CARRIED toolchain renders the routes:
# the carried `yq` appends each app host to the Gateway (lib/istio.sh) and the carried
# `envsubst`+`kubectl` render the per-app VirtualServices. Nothing verifies that rendering path. A
# 503 is the evidence: Envoy matched a route and resolved a cluster with no healthy endpoints. A 404
# means the route was never configured at all.
#
# THE 404-vs-503 SPLIT IS MEASURED, NOT INFERRED (2026-07-19, KinD + istio, backends absent):
#     nosuch.vks.local      -> 404   (no VirtualService: the route was never configured)
#     javawebapp.vks.local  -> 503   (VirtualService rendered, zero endpoints)
#     gowebapp.vks.local    -> 503   (same)
#     gitea.vks.local       -> 200   (rendered AND backed)
#     tekton.vks.local      -> 200   (same)
# That split is the whole basis of this gate. If a future controller collapses 404 into 503, the app
# assertion weakens to "not 000" and this file must say so rather than keep implying the stronger
# claim — re-measure with a host that has no VirtualService before trusting it on a new controller.
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

: "${INGRESS_LB_IP:?INGRESS_LB_IP not set — run 'make install-ingress' first (it publishes the LB IP to .env.state)}"
: "${GITEA_HOST:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
: "${INGRESS_CONTROLLER:=istio}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-10}"

route_code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" \
  --max-time "$CURL_MAX_TIME_SECONDS" "http://${INGRESS_LB_IP}/" 2>/dev/null || echo "000"; }

rc=0
infra_checked=0
app_checked=0

# --- the infra hosts DO have backends here: they must route AND serve their own marker -----------
for pair in "${GITEA_HOST}|gitea|Gitea UI" "${TEKTON_DASHBOARD_HOST}|tekton|Tekton Dashboard UI"; do
  host="${pair%%|*}"; rest="${pair#*|}"; marker="${rest%%|*}"; label="${rest#*|}"
  code=""; end=$((SECONDS + READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$end" ]; do
    code="$(route_code "$host")"
    case "$code" in 2??|3??) break ;; esac
    sleep "$POLL_INTERVAL_SECONDS"
  done
  infra_checked=$((infra_checked + 1))
  case "$code" in
    2??|3??)
      body="$(curl -sL -H "Host: $host" --max-time "$CURL_MAX_TIME_SECONDS" "http://${INGRESS_LB_IP}/" 2>/dev/null || true)"
      # Drain grep (no -q): on a page larger than the pipe buffer, -q SIGPIPEs the writer and
      # pipefail misreads that as "marker absent". Same trap 98-verify-ingress.sh documents.
      if printf '%s' "$body" | grep -iE "$marker" >/dev/null; then
        log_info "  OK    ${host} -> ${code} and served the ${label}"
      else
        log_error "  FAIL  ${host} -> ${code} but did NOT serve the ${label} (wrong backend?)"; rc=1
      fi ;;
    *) log_error "  FAIL  ${host} -> ${code} (the ingress did not route it within ${READY_TIMEOUT_SECONDS}s)"; rc=1 ;;
  esac
done

# --- the app hosts have NO backend here: a 5xx is the PROOF the route was rendered ---------------
while read -r a; do
  [ -n "$a" ] || continue
  host="$(app_host "$a")"
  code="$(route_code "$host")"
  app_checked=$((app_checked + 1))
  case "$code" in
    000) log_error "  FAIL  ${host} -> 000: nothing answered at ${INGRESS_LB_IP}. The gateway itself is not serving."; rc=1 ;;
    404) log_error "  FAIL  ${host} -> 404: the ingress is up but has NO ROUTE for this host — the carried yq/envsubst/kubectl did NOT render its Gateway host + VirtualService."; rc=1 ;;
    2??|3??) log_error "  FAIL  ${host} -> ${code}: a backend ANSWERED. This check asserts the rendered-but-unbacked state; a live backend means the scope is wrong (did 'gitops' run?), so it proves nothing about rendering."; rc=1 ;;
    5??) log_info "  OK    ${host} -> ${code} (route RENDERED, backend absent as expected in this scope)" ;;
    *) log_error "  FAIL  ${host} -> ${code}: unexpected status; expected 5xx (rendered, unbacked)."; rc=1 ;;
  esac
done <<EOF
$(app_names)
EOF

# ITEM counts, guarded. A run that checked nothing must not report OK — the failure this repo spent a
# session removing from its gates. Both counts, because they go to zero independently: an empty app
# registry zeroes app_checked while infra_checked stays healthy.
[ "$infra_checked" -gt 0 ] || die "97-verify-ingress-rendered: checked 0 infra host(s) — the gate has gone BLIND."
[ "$app_checked" -gt 0 ] || die "97-verify-ingress-rendered: checked 0 app host(s) — apps/registry.tsv is empty or app_names is broken. The gate has gone BLIND."

if [ "$rc" -ne 0 ]; then
  log_error "ingress RENDERING verification FAILED at ${INGRESS_LB_IP} (controller=${INGRESS_CONTROLLER})"
  exit 1
fi
log_info "97-verify-ingress-rendered: OK — ${infra_checked} infra host(s) routed and served their marker; ${app_checked} app host(s) RENDERED (5xx, unbacked) by the carried toolchain"
