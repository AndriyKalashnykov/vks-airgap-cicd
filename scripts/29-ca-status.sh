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

  # ⚠️ WITHOUT openssl EVERY probe returns 5 and this reports "your CA is not usable" — the WRONG
  # cause, with a remedy that cannot help. MEASURED with PATH stripped. It matters because a bare
  # Photon jump box has no openssl until `make deps` runs, and scenario-2 reaches this step first.
  if ! command -v openssl >/dev/null 2>&1; then
    log_warn "openssl is not installed, so no certificate can be checked. Run: make deps"
    CA_STATUS_CHECKED=0
    return 0
  fi

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
  # ⚠️ `${HARBOR_URL%%/*}` WAS NOT A HOST PARSER, and two ordinary spellings produced a FALSE SKIP —
  # a live, healthy endpoint reported as "did not answer". MEASURED:
  #     HARBOR_URL=https://harbor.x  -> host became "https:"        -> rc=2, "did not answer"
  #     HARBOR_URL=harbor.x:8443     -> host kept the port, probe 443 -> rc=2, "did not answer"
  # lib/harbor.sh already answers "which host and port is this" (it strips the scheme with a warning,
  # strips a trailing slash, and splits the port). Two implementations of one predicate is exactly the
  # hazard this script's own header claims to avoid — so split it here the same way, in one helper.
  _ca_hostport() {                       # <url> -> "host|port"
    local u="$1" h p
    h="${u#http://}"; h="${h#https://}"  # a scheme is a documented .env mistake, not a crash
    h="${h%%/*}"; h="${h%/}"             # drop any path, then a trailing slash
    case "$h" in
      \[*\]:*) p="${h##*:}"; h="${h%:*}" ;;               # [v6]:port
      \[*\])   p=443 ;;                                    # [v6]
      *:*)     p="${h##*:}"; h="${h%:*}" ;;                # host:port
      *)       p=443 ;;
    esac
    case "$p" in ''|*[!0-9]*) p=443 ;; esac
    printf '%s|%s' "$h" "$p"
  }

  local pairs=""
  [ -n "${HARBOR_CA_FILE:-}" ]   && [ -n "${HARBOR_URL:-}" ]      && pairs="${pairs}Harbor CA|${HARBOR_CA_FILE}|$(_ca_hostport "$HARBOR_URL")|fetch-harbor-ca"$'\n'
  [ -n "${VKS_CA_CERT_FILE:-}" ] && [ -n "${SUPERVISOR_HOST:-}" ] && pairs="${pairs}Supervisor CA|${VKS_CA_CERT_FILE}|$(_ca_hostport "$SUPERVISOR_HOST")|fetch-supervisor-ca"$'\n'

  # THE DENOMINATOR. Set for the caller, because "checked nothing" and "checked three and all were
  # fine" must not print the same sentence. The first version said "all CA certificates match their
  # servers" with NOTHING configured — a green over zero work, which is the one failure this whole
  # script exists to prevent, committed by the script itself.
  CA_STATUS_CHECKED=0; CA_STATUS_MATCHED=0

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
      # WARN or PROBLEM depends on WHO IS ASKING, and the difference is not cosmetic.
      #   bare `make lab-preflight` — scenario-1 §7 legitimately runs BEFORE §8 saves the CA, so a
      #     missing file is expected and must not fail. WARN.
      #   `make preflight` (the first prerequisite of install-all) — here a missing CA is fatal and
      #     NOTHING ELSE CATCHES IT: _harbor_serving_code probes with `curl -sk` (skip-verify, so
      #     reachability passes without a CA), _harbor_ca_args returns non-zero when HARBOR_CA_FILE
      #     is unset so harbor_auth_report prints "skipping the auth probe" and returns 0, and
      #     `preflight` runs env-check, NOT env-validate — env-validate being the one gate that does
      #     catch it (measured on the row-5 walk: curl exit 60). So install-all printed a three-line
      #     all-clear and died 8-20 minutes later inside `mirror`. PROBLEM.
      if [ "${CA_STATUS_STRICT:-0}" = 1 ]; then
        log_error "${label} (${file}) is missing or empty — and the install cannot finish without it."
        log_error "  Try  make ${remedy}  — it works only when the issuing CA is sent by the server."
        log_error "  Many servers do not send it, and it will say so: ask for the CA file instead."
        stale=$((stale + 1))
      else
        log_warn "${label} (${file}) is missing or empty."
        log_warn "  Try  make ${remedy}  — it works only when the issuing CA is sent by the server."
        log_warn "  Many servers do not send it, and it will say so: ask for the CA file instead."
      fi
      continue
    fi

    rc=0; ca_verifies_endpoint "$host" "$port" "$file" >/dev/null 2>&1 || rc=$?
    CA_STATUS_CHECKED=$((CA_STATUS_CHECKED + 1))
    # EVERY STRING BELOW IS READ BY AN OPERATOR, so it says "CA certificate" and "matches", not
    # "trust anchor" and "STALE" — neither runbook uses those words, and printing them at someone
    # who has only ever been told to "save Harbor's CA certificate" is our jargon leaking out. The
    # internals may keep calling it an anchor; the output may not.
    # ALL SIX of ca_verifies_endpoint's documented verdicts get an arm. The first version handled
    # 0/1/2/5 and let 3 and 4 fall through to a catch-all that printed "could not check" and exited
    # 0 — and rc=3 (chain fine, NAME wrong) is the MODAL shape here, because scenario-2 tells the
    # tenant to put Harbor's LB *IP* in HARBOR_URL while its certificate usually carries only a DNS
    # name. So the commonest real failure was being reported as "could not check", with a green exit.
    case "$rc" in
      0) log_info "${label} (${file}) matches ${host}"
         CA_STATUS_MATCHED=$((CA_STATUS_MATCHED + 1)) ;;
      1) log_error "${label} (${file}) does NOT match ${host} — this is a leftover certificate."
         log_error "  A rebuilt lab issues a NEW certificate at the SAME address, so the old file"
         log_error "  still looks perfectly valid and is not."
         log_error "  Get it again — this overwrites in place and cannot lose anything:  make ${remedy}"
         stale=$((stale + 1)) ;;
      2) # ABSTAIN. Without this arm, every certificate reads as wrong whenever the lab is powered
         # off, and the first person to see that rightly deletes the check. rc=1 and rc=2 being
         # DISTINCT is what makes this safe to ship; test-ca-staleness-check.sh asserts they differ.
         # It is NOT a pass either — see the ALL-MATCH token below, which this arm cannot reach.
         log_warn "${label}: ${host}:${port} did not answer — skipping. This says nothing about the certificate."
         log_warn "  (the address is printed WITH its port so a skip is diagnosable: a mis-parsed"
         log_warn "   HARBOR_URL used to land here as a false 'did not answer' on a healthy server.)" ;;
      3) log_error "${label} (${file}) issued the certificate at ${host}, but that certificate is"
         log_error "  NOT VALID FOR THIS ADDRESS. Your certificate is fine; the address is wrong."
         log_error "  Use the DNS name the certificate was issued for, not an IP — set it in ./.env."
         stale=$((stale + 1)) ;;
      4) log_error "${label}: ${host} answered, but did not present a certificate at all."
         log_error "  Something other than ${label} is listening there, or it is serving plain HTTP."
         stale=$((stale + 1)) ;;
      5) log_error "${label} (${file}) is not a usable CA certificate — run: make ${remedy}"
         stale=$((stale + 1)) ;;
      *) log_error "${label}: unrecognised result ${rc} checking ${host} — treat as unchecked."
         stale=$((stale + 1)) ;;
    esac
  done <<< "$pairs"
  return "$stale"
}

# Sourced (by lab-preflight) -> provide the function and stop. Executed -> run it and report.
(return 0 2>/dev/null) && return 0

printf '\n================= CA certificate check =================\n' >&2
_stale=0; ca_status_report || _stale=$?
# THE TOKEN IS THE POINT, and it is the fix for a fake-green I shipped hours earlier. The runbooks
# quote a line from this output as their **Expect:**, and walk-doc PASSES A BLOCK WHEN ANY QUOTED
# LITERAL MATCHES. My first Expect quoted "Harbor CA" — which every per-certificate line begins
# with, INCLUDING every failure arm and the file-is-missing arm. So the step added to catch the
# failure printed a literal that MATCHED ON THAT FAILURE and scored the block green.
# ALL-MATCH is emitted on exactly one path: at least one certificate checked, and every one matched.
# No failure arm, no skip, and no empty configuration can produce it.
if [ "${CA_STATUS_CHECKED:-0}" -eq 0 ]; then
  log_error "checked nothing — see above. This is NOT a pass."
  printf '========================================================\n' >&2
  exit 1
elif [ "$_stale" -eq 0 ] && [ "${CA_STATUS_MATCHED:-0}" -eq "$CA_STATUS_CHECKED" ]; then
  log_info "CA-STATUS: ALL-MATCH n=${CA_STATUS_MATCHED}"
elif [ "$_stale" -eq 0 ]; then
  # Everything that ran was fine, but something was SKIPPED (an endpoint did not answer). Not a
  # failure, and emphatically not ALL-MATCH.
  log_warn "CA-STATUS: INCOMPLETE — ${CA_STATUS_MATCHED} of ${CA_STATUS_CHECKED} checked; the rest were skipped above."
else
  log_error "${_stale} of ${CA_STATUS_CHECKED} CA certificate(s) above are wrong. Each one fails LATER,"
  log_error "  as an error about TLS rather than about the file — and a rebuilt lab reproduces it."
fi
printf '========================================================\n' >&2
exit "$_stale"
