#!/usr/bin/env bash
# 44-install-ingress.sh — install the selected ingress controller (ONE
# LoadBalancer fronting the browser UIs at *.vks.local). Dispatches on
# INGRESS_CONTROLLER: `istio` (default) or `traefik`. Both expose the same
# *.vks.local hostnames and publish INGRESS_LB_IP to .env.state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

# Capture an EXPLICIT override (env / `make install-ingress INGRESS_CONTROLLER=...`)
# BEFORE load_env sources .env.state — otherwise the persisted .env.state value would
# clobber the override, so `make verify-ingress-both` (which flips the controller per
# leg) would silently install the same controller twice.
_override="${INGRESS_CONTROLLER:-}"
load_env

# Precedence: explicit override > persisted .env.state/.env value > default. Persist the
# choice so a later `make verify-ingress` (a fresh make with no override) reads the
# controller that was actually installed from .env.state, not the .env.example default.
CONTROLLER="${_override:-${INGRESS_CONTROLLER:-istio}}"
# NOTE: the controller is published by the INSTALLER, next to its `state_set INGRESS_LB_IP`, NOT here.
# Publishing it before the `exec` split the two halves of one fact across a failure boundary: an
# install that died before resolving its LB IP left .env.state carrying the NEW controller with the
# PREVIOUS controller's IP, so a standalone `make verify-ingress` then passed while reporting
# "reachable through the <new> ingress at <old controller's IP>" — the UIs really were reachable, so
# nothing looked broken; only the label was a lie. 47-attach-istio.sh:119 already published them
# together; 45 and 46 now do too, so the pair is written atomically-enough or not at all.
case "$CONTROLLER" in
  istio)
    log_info "INGRESS_CONTROLLER=istio -> installing Istio ingress"
    exec "${SCRIPT_DIR}/46-install-istio.sh"
    ;;
  istio-existing)
    log_info "INGRESS_CONTROLLER=istio-existing -> attaching to an Istio we did NOT install"
    exec "${SCRIPT_DIR}/47-attach-istio.sh"
    ;;
  traefik)
    log_info "INGRESS_CONTROLLER=traefik -> installing Traefik ingress"
    exec "${SCRIPT_DIR}/45-install-traefik.sh"
    ;;
  *)
    die "unknown INGRESS_CONTROLLER='${CONTROLLER}' (expected 'istio', 'istio-existing' or 'traefik')"
    ;;
esac
