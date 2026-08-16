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

# ca_status_report — the whole check, as ONE function, so `make ca-status` and lab-preflight share
# it instead of each carrying a copy. (An inline copy in the preflight was the first draft; two
# copies of one predicate is the shape this repo keeps getting bitten by.)
# Prints to stderr; returns the number of STALE anchors.
ca_status_report() {
  local stale=0 pair label file host port remedy rc

  # The pairs are DERIVED from the env, not enumerated in a list that rots: each is a *_CA_FILE key
  # and the endpoint key that names what it anchors. Adding a third anchor means adding it here AND
  # to .env.example, which check-env-coverage already enforces.
  #
  # THE LABEL IS A HUMAN NAME, NOT THE VARIABLE NAME. This printed "HARBOR_CA_FILE: verifies ..." in
  # its first version, and scenario-1 mentions HARBOR_CA_FILE exactly ZERO times — so the operator
  # following that runbook would have been shown an internal name they had never met. The file PATH
  # is what they recognise, and the remedy command is what they act on; the variable is our business.
  #
  # NEWLINE-separated + `while read`, not space-separated + `for` — the labels contain spaces, and a
  # `for x in $var` would split them mid-label (and does not word-split at all under zsh).
  local pairs=""
  [ -n "${HARBOR_CA_FILE:-}" ]   && [ -n "${HARBOR_URL:-}" ]      && pairs="${pairs}Harbor CA|${HARBOR_CA_FILE}|${HARBOR_URL%%/*}|443|fetch-harbor-ca"$'\n'
  [ -n "${VKS_CA_CERT_FILE:-}" ] && [ -n "${SUPERVISOR_HOST:-}" ] && pairs="${pairs}Supervisor CA|${VKS_CA_CERT_FILE}|${SUPERVISOR_HOST}|443|fetch-supervisor-ca"$'\n'

  # THE DENOMINATOR. Set for the caller, because "checked nothing" and "checked three and all were
  # fine" must not print the same sentence. The first version said "all CA certificates match their
  # servers" with NOTHING configured — a green over zero work, which is the one failure this whole
  # script exists to prevent, committed by the script itself.
  CA_STATUS_CHECKED=0

  if [ -z "$pairs" ]; then
    log_info "no CA certificate is configured, so there is nothing to check."
    log_info "  A CA certificate needs a server to check it against: set HARBOR_CA_FILE + HARBOR_URL,"
    log_info "  or VKS_CA_CERT_FILE + SUPERVISOR_HOST, in ./.env"
    return 0
  fi

  # A herestring, NOT `printf | while` — a pipe makes the loop a subshell and `stale` would be lost,
  # so the report would count correctly and then return 0.
  while IFS='|' read -r label file host port remedy; do
    [ -n "$label" ] || continue

    if [ ! -s "$file" ]; then
      # NOT counted as stale: a missing anchor fails loudly at first use and is a different problem
      # from one that is present and WRONG. Saying so is the point.
      #
      # "run: make fetch-*" would be a CIRCLE on the commonest real-lab shape. MEASURED 2026-08-16
      # on the scenario-2 walk: fetch-harbor-ca refused with "presents ONE certificate that is NOT
      # self-signed ... Its CA is not on the wire" — correct, and unfixable from the tenant's side.
      # So name the command as an ATTEMPT, not as the answer.
      log_warn "${label} (${file}) is missing or empty."
      log_warn "  Try  make ${remedy}  — it works only when the issuing CA is sent by the server."
      log_warn "  Many servers do not send it, and it will say so: ask for the CA file instead."
      continue
    fi

    rc=0; ca_verifies_endpoint "$host" "$port" "$file" >/dev/null 2>&1 || rc=$?
    CA_STATUS_CHECKED=$((CA_STATUS_CHECKED + 1))
    # EVERY STRING BELOW IS READ BY AN OPERATOR, so it says "CA certificate" and "matches", not
    # "trust anchor" and "STALE" — neither runbook uses those words, and printing them at someone
    # who has only ever been told to "save Harbor's CA certificate" is our jargon leaking out. The
    # internals may keep calling it an anchor; the output may not.
    case "$rc" in
      0) log_info "${label} (${file}) matches ${host}" ;;
      1) log_error "${label} (${file}) does NOT match ${host} — this is a leftover certificate."
         log_error "  A rebuilt lab issues a NEW certificate at the SAME address, so the old file"
         log_error "  still looks perfectly valid and is not."
         log_error "  Get it again — this overwrites in place and cannot lose anything:  make ${remedy}"
         stale=$((stale + 1)) ;;
      2) # ABSTAIN. Without this arm, every certificate reads as wrong whenever the lab is powered
         # off, and the first person to see that rightly deletes the check. rc=1 and rc=2 being
         # DISTINCT is what makes this safe to ship; test-ca-staleness-check.sh asserts they differ.
         log_warn "${label}: ${host} did not answer — skipping. This says nothing about the certificate." ;;
      5) log_warn "${label} (${file}) is not a usable CA certificate — run: make ${remedy}" ;;
      *) log_warn "${label}: could not check it against ${host} (code ${rc})" ;;
    esac
  done <<< "$pairs"
  return "$stale"
}

# Sourced (by lab-preflight) -> provide the function and stop. Executed -> run it and report.
(return 0 2>/dev/null) && return 0

printf '\n================= CA certificate check =================\n' >&2
_stale=0; ca_status_report || _stale=$?
if [ "${CA_STATUS_CHECKED:-0}" -eq 0 ]; then
  log_info "checked nothing — see above. This is not a pass."
elif [ "$_stale" -eq 0 ]; then
  log_info "all ${CA_STATUS_CHECKED} CA certificate(s) match their servers."
else
  log_error "${_stale} CA certificate(s) above do not match. Each one fails LATER, as an error about"
  log_error "  TLS rather than about the file — and a rebuilt lab reproduces it every time."
fi
printf '========================================================\n' >&2
exit "$_stale"
