#!/usr/bin/env bash
# 98-verify-ingress.sh — assert the browser UIs are reachable THROUGH the ingress
# LoadBalancer at their *.vks.local hostnames, not via `kubectl port-forward`.
#
# Why this exists: `make verify` (99-verify.sh) port-forwards svc/webui + svc/gitea
# directly, so a broken Ingress / Gateway / VirtualService (wrong backend, host, or
# port) still passes the whole e2e green. This script exercises the real data path:
#   client -> INGRESS_LB_IP (Host: <host>) -> controller route -> backend Service.
#
# It is controller-agnostic: whichever ingress installed last published INGRESS_LB_IP
# to .env.kind, and the route assertion (curl with a Host header) is identical for
# Istio (Gateway/VirtualService) and Traefik (Ingress).
#
# K1.5 (assigned != routable): cloud-provider-kind wires the LB data path (the
# per-Service Envoy) 5-60s AFTER the LoadBalancer IP is assigned, so a curl fired
# right after IP-assignment gets `Connection reset`. The per-host readiness poll
# below IS the data-path gate — it retries transient 000/502/503/504 until the
# route is live, then asserts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd curl
: "${INGRESS_LB_IP:?INGRESS_LB_IP not set — run 'make install-ingress' first (it writes the LB IP to .env.kind)}"
: "${GITEA_HOST:?}"; : "${WEBUI_HOST:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
: "${INGRESS_CONTROLLER:=istio}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-10}"

# HTTP codes that prove the ingress routed to a live backend. 2xx = served;
# 3xx = a backend redirect (e.g. ArgoCD /) — both mean the route works. 5xx and
# 000 (connection reset / no response) mean the data path is NOT yet ready or the
# route is broken.
route_code() { # <host> — echo the HTTP status of GET / through the ingress LB
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: $1" --max-time "$CURL_MAX_TIME_SECONDS" \
    "http://${INGRESS_LB_IP}/" 2>/dev/null || echo "000"
}

# Poll a host until its route is live (K1.5 data-path readiness), then return the code.
wait_route() { # <host> — 0 + echo code when routed; 1 on timeout
  local host="$1" code end=$((SECONDS + READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$end" ]; do
    code="$(route_code "$host")"
    case "$code" in
      2??|3??) echo "$code"; return 0 ;;                 # routed to a live backend
      000|50[234]) : ;;                                   # not routable yet — retry
      *) : ;;                                             # 4xx etc — keep polling briefly
    esac
    sleep "$POLL_INTERVAL_SECONDS"
  done
  echo "$code"; return 1
}

log_info "verifying ingress routing via INGRESS_CONTROLLER=${INGRESS_CONTROLLER} at ${INGRESS_LB_IP}"
rc=0
for host in "$GITEA_HOST" "$WEBUI_HOST" "$TEKTON_DASHBOARD_HOST"; do
  log_info "  route-readiness poll: ${host} (timeout ${READY_TIMEOUT_SECONDS}s)"
  if code="$(wait_route "$host")"; then
    log_info "  OK    ${host} -> HTTP ${code} (routed through the ingress LB)"
  else
    log_error "  FAIL  ${host} -> HTTP ${code} (not routable through ${INGRESS_LB_IP} within ${READY_TIMEOUT_SECONDS}s)"
    rc=1
  fi
done

# Assert each host's body actually comes from ITS backend, not just a 200 from some
# proxy — a wrong Ingress/VirtualService backend still returns 2xx. Markers are the
# apps' own branding: Gitea always emits "gitea" (title/footer/asset paths), the app
# renders class="message", Tekton emits "tekton". curl -L follows any login/dashboard
# redirect to the real page. (ArgoCD is NOT fronted by the ingress — it has its own
# LoadBalancer IP, like real VKS; see scripts/07-install-argocd.sh + make creds.)
if [ "$rc" -eq 0 ]; then
  assert_body() { # <host> <grep-ERE> <label>
    local b
    b="$(curl -sL -H "Host: $1" --max-time "$CURL_MAX_TIME_SECONDS" "http://${INGRESS_LB_IP}/" 2>/dev/null || true)"
    if printf '%s' "$b" | grep -qiE "$2"; then
      log_info "  OK    $1 served the $3 through the ingress"
    else
      log_error "  FAIL  $1 returned 2xx/3xx but not the $3 (wrong backend?)"
      rc=1
    fi
  }
  assert_body "$GITEA_HOST"             'gitea'           "Gitea UI"
  assert_body "$WEBUI_HOST"             'class="message"' "app greeting page"
  assert_body "$TEKTON_DASHBOARD_HOST"  'tekton'          "Tekton Dashboard UI"
fi

if [ "$rc" -ne 0 ]; then
  log_error "ingress verification FAILED — diagnostics:"
  log_error "  INGRESS_LB_IP=${INGRESS_LB_IP} (from .env.kind); check the controller + its route objects:"
  case "${INGRESS_CONTROLLER}" in
    istio)   log_error "    kubectl -n ${ISTIO_GATEWAY_NAMESPACE:-istio-ingress} get gateway,virtualservice,svc; kubectl -n ${ISTIO_NAMESPACE:-istio-system} get pods" ;;
    traefik) log_error "    kubectl -n ${TRAEFIK_NAMESPACE:-traefik} get ingress,svc,pods" ;;
  esac
  die "ingress routing not verified"
fi
log_info "SUCCESS — all UIs reachable through the ${INGRESS_CONTROLLER} ingress at ${INGRESS_LB_IP} (*.vks.local)"
