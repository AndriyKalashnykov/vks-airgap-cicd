#!/usr/bin/env bash
# 29-ca-status.sh — READ-ONLY: does each configured trust anchor still verify the endpoint it
# anchors? Prints a verdict per anchor and names the exact re-fetch command for any that is stale.
#
# WHY THIS EXISTS
# ---------------
# A CA file that no longer matches its endpoint is the one kind of dead file in secrets/ that is
# actively WIRED: `.env` names it, lib/tls.sh's vks_ca_default auto-points at it, and it is handed
# to `vcf context create --ca-certificate`. NOTHING re-fetches it when the lab is rebuilt, and a
# rebuilt lab mints a new CA at the SAME address — so the stale file still looks valid.
#
# MEASURED 2026-08-16 on a twice-rebuilt lab: secrets/supervisor-ca.crt AND secrets/harbor-ca.crt
# both failed to verify their live endpoints (openssl "Verify return code: 21") while the lab's
# current anchor returned 0. harbor-ca.crt was SIX HOURS old and already dead, and
# supervisor.kubeconfig was TWELVE hours old and perfectly current — so AGE IS NOT THE SIGNAL.
# Only the probe separates them. Re-fetching both moved them 21 -> 0.
#
# IT DETECTS; IT NEVER FETCHES. Deliberate. Both fetch commands print a SHA-256 and tell the
# operator to confirm it out of band, because a CA taken over the connection it is meant to protect
# is not authenticated by the act of downloading it. Automating the fetch would remove the only step
# that makes it trustworthy. And the route that works for a cert-manager Harbor
# (`make harbor-ca-from-cluster`) needs an ADMIN grant, which a tenant does not have. So this prints
# the command and stops.
#
# EXIT CODE: the number of STALE anchors. Unreachable and missing are NOT counted — see below.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
load_env

# The report itself is ca_status_report in lib/tls.sh (ONE definition, two entry points:
# `make ca-status` runs it here, 24-lab-preflight.sh calls it directly).
#
# The body lives in a FUNCTION rather than after an early `return`, because an early return at file
# scope makes shellcheck read EVERY LINE AFTER IT as unreachable (SC2317) — and that propagates into
# 24-lab-preflight.sh, which sources this file with `# shellcheck source=`. Measured: 6 SC2317s in
# the SOURCING file, which is what turned `make lint` red. Same guard, no dead-looking code.
_ca_status_main() {
  printf '\n================= CA certificate check =================\n' >&2
  local _stale=0
  # RESOLVE THE DEFAULT FIRST, or this report is BLIND to the Supervisor CA on a doc-following box.
  # ca_status_report builds its Supervisor pair only when VKS_CA_CERT_FILE is non-empty (tls.sh),
  # and .env.example ships that COMMENTED — docs/scenario-1.md even says "Set it only if you moved
  # it." So without this line the shipped default examines ZERO pairs and prints "no CA certificate
  # is configured, so there is nothing to check", while a stale anchor sits unexamined.
  # MEASURED 2026-08-18, same fixture, only this line differing: pairs examined 0 -> 1.
  # vks_ca_default is a pure default-setter — no network, and it early-returns when the operator
  # set VKS_CA_CERT_FILE themselves, so it cannot override an explicit choice.
  vks_ca_default
  ca_status_report || _stale=$?
  if [ "${CA_STATUS_CHECKED:-0}" -eq 0 ]; then
    log_error "checked nothing — see above. This is NOT a pass."
    printf '========================================================\n' >&2
    exit 1
  elif [ "$_stale" -eq 0 ] && [ "${CA_STATUS_MATCHED:-0}" -eq "$CA_STATUS_CHECKED" ]; then
    # THE TOKEN, and it is the fix for a fake-green shipped hours earlier. The runbooks quote a line
    # from this output as their **Expect:**, and walk-doc PASSES A BLOCK WHEN ANY QUOTED LITERAL
    # MATCHES. The first Expect quoted "Harbor CA" — which every per-certificate line begins with,
    # INCLUDING every failure arm and the file-is-missing arm — so the step added to catch the
    # failure printed a literal that MATCHED ON THAT FAILURE and scored the block green.
    # ALL-MATCH is emitted on exactly one path: at least one certificate checked, and every one
    # matched. No failure arm, no skip, and no empty configuration can produce it.
    log_info "CA-STATUS: ALL-MATCH n=${CA_STATUS_MATCHED}"
  elif [ "$_stale" -eq 0 ]; then
    log_warn "CA-STATUS: INCOMPLETE — ${CA_STATUS_MATCHED} of ${CA_STATUS_CHECKED} checked; the rest were skipped above."
  else
    log_error "${_stale} of ${CA_STATUS_CHECKED} CA certificate(s) above are wrong. Each one fails LATER,"
    log_error "  as an error about TLS rather than about the file — and a rebuilt lab reproduces it."
  fi
  printf '========================================================\n' >&2
  exit "$_stale"
}

(return 0 2>/dev/null) || _ca_status_main "$@"
