#!/usr/bin/env bash
# 44-install-ingress.sh — install the selected ingress controller (ONE
# LoadBalancer fronting the browser UIs at *.vks.local). Dispatches on
# INGRESS_CONTROLLER: `istio` (default) or `traefik`. Both expose the same
# *.vks.local hostnames and publish INGRESS_LB_IP to .env.kind.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

# Capture an EXPLICIT override (env / `make install-ingress INGRESS_CONTROLLER=...`)
# BEFORE load_env sources .env.kind — otherwise the persisted .env.kind value would
# clobber the override, so `make verify-ingress-both` (which flips the controller per
# leg) would silently install the same controller twice.
_override="${INGRESS_CONTROLLER:-}"
load_env

# Precedence: explicit override > persisted .env.kind/.env value > default. Persist the
# choice so a later `make verify-ingress` (a fresh make with no override) reads the
# controller that was actually installed from .env.kind, not the .env.example default.
CONTROLLER="${_override:-${INGRESS_CONTROLLER:-istio}}"
set_env_var INGRESS_CONTROLLER "$CONTROLLER"

case "$CONTROLLER" in
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
