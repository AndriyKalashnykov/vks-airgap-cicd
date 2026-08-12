#!/usr/bin/env bash
# 28-harbor-admin-password.sh — put a WORKING Harbor admin credential into ./.env, for the case
# where Harbor was installed by someone else (or by an earlier run) and you do not have its password.
#
# WHAT IT REPLACES — a hand-paste the walk proved nobody completes
# ---------------------------------------------------------------
# scenario-1 Step 4's "If Harbor already exists" told the reader to run three kubectl commands, read
# a password off the screen, and paste it into .env. MEASURED 2026-08-12 on a real VCF 9.1 lab: the
# commands ran and printed a real password, the paste did not happen, `make env-populate` had already
# GENERATED a random HARBOR_PASSWORD (which cannot authenticate against a Harbor that already
# exists), and the run died 605 seconds into `make install-all` pushing an image.
#
# THE PREMISE, AND ITS LIMIT (measured, not assumed)
# --------------------------------------------------
# goharbor src/core/main.go:96-114 applies HARBOR_ADMIN_PASSWORD only at FIRST bootstrap:
#     if user.Salt == "" { UpdatePassword(...) } else { log.Warning("...ignored: password already
#     exists in database. Use Harbor UI or API to change.") }
# So the secret holds the last value SUBMITTED to the package, which is not necessarily the one
# Harbor authenticates. MEASURED 2026-08-12 against a Supervisor-installed Harbor: the read-back
# value returned HTTP 200 -- so for a Harbor installed and left alone, the secret IS the credential.
# It is NOT proven for a Harbor whose admin password was later changed in the UI or by the API; that
# is exactly why this script VERIFIES before it writes anything, and refuses rather than publish a
# credential it has not seen work.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
load_env
require_cmd kubectl

: "${HARBOR_URL:?HARBOR_URL is not set - the FQDN Harbor serves on (bare host, no scheme). Step 4 sets it.}"

# ── already have a working one? then do not touch it ─────────────────────────────────────────────
# NON-DESTRUCTIVE ON PURPOSE. On the install path 04-install-harbor-service.sh already published the
# password it installed Harbor with, and Step 9's robot is the credential the pipeline SHOULD run as.
# Overwriting either with the admin secret would silently downgrade a least-privilege setup to admin
# -- so a credential that already authenticates wins, and this script says so and exits.
if ! is_placeholder "${HARBOR_PASSWORD:-}"; then
  # harbor_auth_ok, NOT harbor_auth_report: the reporter returns 0 for "nothing to report", which
  # includes an INCONCLUSIVE probe. Measured 2026-08-12 -- with a stale CA and a deliberately wrong
  # password the reporter returned 0, and this guard would have said the wrong credential works and
  # exited without doing its job.
  if [ "$(harbor_auth_verdict)" = accepted ]; then
    log_info "HARBOR_USERNAME=${HARBOR_USERNAME:-admin} already authenticates against ${HARBOR_URL} - leaving it alone"
    log_info "  (re-run after 'make harbor-robot' and this stays out of the way: a working credential is never replaced)"
    exit 0
  fi
  log_warn "the HARBOR_PASSWORD currently in your .env does NOT authenticate - reading the installed one"
fi

# ── the Supervisor kubeconfig ────────────────────────────────────────────────────────────────────
# The SAME chain 27-harbor-ca-from-cluster.sh uses, and VKS_SUPERVISOR_KUBECONFIG FIRST because that
# is the name the WRITER (30-vks-login.sh) honours. Harbor is a SUPERVISOR Service: $KUBECONFIG from
# Step 6 onward is the GUEST cluster, which has no harbor namespace at all.
SUP="${VKS_SUPERVISOR_KUBECONFIG:-${SUPERVISOR_KUBECONFIG:-${REPO_ROOT}/secrets/supervisor.kubeconfig}}"
[ -f "$SUP" ] || die "no Supervisor kubeconfig at '$SUP' - run 'make vks-login' (scenario-1 Step 3) first.
  Harbor is a SUPERVISOR Service; the guest cluster has no harbor namespace."

# ── the namespace, BY LABEL ──────────────────────────────────────────────────────────────────────
# Not `get ns | grep harbor`: zero matches yields an EMPTY namespace and kubectl then silently runs
# against `default`, and two matches feeds a multi-line value. Neither is detected. (The doc's old
# hand-run pipeline had exactly this shape, and under `set -euo pipefail` its `grep -oE` also killed
# the script with no message when it matched nothing.)
ns="$(kubectl --kubeconfig "$SUP" get ns -l appplatform.vmware.com/serviceId=harbor -o name 2>/dev/null || true)"
n="$(printf '%s\n' "$ns" | grep -c . || true)"
if [ "$n" != 1 ]; then
  log_error "expected EXACTLY ONE namespace labelled serviceId=harbor, got ${n}:"
  printf '%s\n' "$ns" | sed 's/^/    /' >&2
  [ "$n" = 0 ] && log_error "  no Harbor Supervisor Service on this Supervisor - install it (Step 4) or ask your platform admin."
  die "refusing to guess - an empty value would silently target the 'default' namespace"
fi
ns="${ns#namespace/}"
log_info "harbor namespace: ${ns}  (by label, not by grep)"

# ── the secret: harbor-core, HIGHEST -ver-N ──────────────────────────────────────────────────────
# `-ver-N` is KAPP's versioned-resource suffix (carvel-dev/kapp diff/versioned_resource.go:18) and
# kapp keeps numToKeep=5, so up to five can coexist -- and the LEXICALLY first is the OLDEST:
#     harbor-core-ver-1  harbor-core-ver-10  harbor-core-ver-11  harbor-core-ver-2 ...
# Sort NUMERICALLY and take the newest.
#
# ⚠️ AND THE BASE NAME IS LOAD-BEARING, measured: `harbor-exporter-ver-1` ALSO carries a
# HARBOR_ADMIN_PASSWORD key on a real Supervisor Harbor. "the first secret that has the key" is
# therefore a coin flip between two secrets, not a robust discovery.
secs="$(kubectl --kubeconfig "$SUP" -n "$ns" get secret -o name 2>/dev/null | sed 's|^secret/||' \
        | grep -E '^harbor-core(-ver-[0-9]+)?$' || true)"
[ -n "$secs" ] || die "no harbor-core secret in namespace ${ns} - is this a Harbor Supervisor Service?"
latest="$(printf '%s\n' "$secs" | sed 's/.*-ver-//' | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
sec="${latest:+harbor-core-ver-${latest}}"; sec="${sec:-harbor-core}"
log_info "reading ${sec} (newest of $(printf '%s\n' "$secs" | grep -c .) harbor-core secret(s))"

pw="$(kubectl --kubeconfig "$SUP" -n "$ns" get secret "$sec" \
        -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[ -n "$pw" ] || die "${sec} carries no HARBOR_ADMIN_PASSWORD - this Harbor was not installed the way scenario-1 installs it.
  Ask whoever installed it for the admin credential, or create a robot and use that instead."

# ── VERIFY BEFORE PUBLISHING ─────────────────────────────────────────────────────────────────────
# The premise above holds for a Harbor installed and left alone and is NOT proven for one whose
# password was later changed. So the value is proven against the live Harbor BEFORE it is written:
# publishing an unverified credential would just move the 401 later, which is the whole defect.
# THREE outcomes, not two. "Harbor said no" and "I could not ask" need DIFFERENT messages: the
# second one printed as the first tells the operator their password was changed, about a password
# that was never sent anywhere (measured, row 4 -- see harbor_auth_verdict in lib/harbor.sh).
verdict="$(HARBOR_USERNAME=admin HARBOR_PASSWORD="$pw" harbor_auth_verdict)"
case "$verdict" in
  accepted) HARBOR_USERNAME=admin HARBOR_PASSWORD="$pw" harbor_auth_report || true ;;
  rejected)
    die "the password in ${sec} does NOT authenticate against ${HARBOR_URL} (Harbor returned 401).
  Harbor applies HARBOR_ADMIN_PASSWORD only at its FIRST bootstrap, so a Harbor whose password was
  later changed (UI, API, or a re-install over a surviving database) keeps the OLD one and this
  secret is stale. Nothing was written to .env.
  Ask whoever installed Harbor for the admin credential, or use a robot ('make harbor-robot')." ;;
  unchecked:*)
    die "could NOT check the password in ${sec} against ${HARBOR_URL}: ${verdict#unchecked:}.
  This is NOT a statement about the password - nothing was sent to Harbor, and nothing was written
  to .env. Run this AFTER 'make fetch-harbor-ca' (scenario-1 Step 8), which is where the CA that
  verifies Harbor's TLS comes from. On a Harbor with a publicly-trusted certificate, or with
  HARBOR_INSECURE=1, it can run any time." ;;
  *) die "internal: unrecognised auth verdict '${verdict}'" ;;
esac

# ── publish to .env, NOT to the state overlay ────────────────────────────────────────────────────
# load_env sources .env.state LAST, so a credential written there would outrank .env AND the command
# line -- silently clobbering the robot Step 9 tells the reader to put in .env, and running the whole
# pipeline as Harbor admin. .env is the sink Step 9 uses, and set_env_var upserts, so the robot
# written later simply replaces this. Same file, same mode, same exposure as the value
# `make env-populate` already writes there today.
set_env_var HARBOR_USERNAME admin      "${REPO_ROOT}/.env"
set_env_var HARBOR_PASSWORD "$pw"      "${REPO_ROOT}/.env"
log_info "wrote HARBOR_USERNAME and HARBOR_PASSWORD to ./.env  (verified against ${HARBOR_URL} first)"
log_info "the password is NOT printed here - read it back with 'make creds-show'"
