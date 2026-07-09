#!/usr/bin/env bash
# 44-install-ingress.sh — install the selected ingress controller (ONE
# LoadBalancer fronting the browser UIs at *.vks.local). Dispatches on
# INGRESS_CONTROLLER: `istio` (default) or `traefik`. Both expose the same
# *.vks.local hostnames and publish INGRESS_LB_IP to .env.kind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

case "${INGRESS_CONTROLLER:-istio}" in
  istio)
    log_info "INGRESS_CONTROLLER=istio -> installing Istio ingress"
    exec "${SCRIPT_DIR}/46-install-istio.sh"
    ;;
  traefik)
    log_info "INGRESS_CONTROLLER=traefik -> installing Traefik ingress"
    exec "${SCRIPT_DIR}/45-install-traefik.sh"
    ;;
  *)
    die "unknown INGRESS_CONTROLLER='${INGRESS_CONTROLLER}' (expected 'istio' or 'traefik')"
    ;;
esac
