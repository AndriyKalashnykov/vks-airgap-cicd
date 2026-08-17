#!/usr/bin/env bash
# test-argocd-await-revision.sh — offline, hermetic. Drives argocd_await_revision with a STUB `ka`.
#
# WHY THIS EXISTS. Certification row 5 (2026-08-17) failed here and reported:
#   "Most likely GITEA_ARGOCD_URL is not reachable from the ArgoCD cluster"
# MEASURED FALSE the same day — from inside the repo-server pod the real clone handshake
# (/info/refs?service=git-upload-pack) returned http=200, and the Application was Synced/Healthy.
# The check had named a cause it never probed, because BOTH its reads were `2>/dev/null || true`,
# so a NotFound, a Forbidden, a wrong namespace and a missing CRD all collapsed into one empty
# string. It then promised "Its own words:" and printed NOTHING.
#
# The property under test is therefore NOT "does it wait" — it is: **can it still tell the
# difference between "I could not READ the Application" and "the Application's revision is
# genuinely EMPTY"?** Those have different remedies and only one of them implicates the repo.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# The function's whole environment, pinned so nothing leaks in from the operator's box.
export ARGOCD_NAMESPACE=test-ns
export ARGOCD_API=https://api.example:6443
export ARGOCD_KUBECONFIG=/tmp/nonexistent.kubeconfig
export ARGOCD_REPO_TIMEOUT_SECONDS=2      # keep the suite fast; the count is not what is under test
export GITEA_ARGOCD_URL=http://gitea.example:3000
export GITEA_ORG=demo

# `run <mode>` executes the function in a SUBSHELL (it calls die, which exits) with a stub `ka`,
# and returns its combined output. STUB_MODE selects the fault being simulated.
run() {
  ( export STUB_MODE="$1"
    ka() {
      case "$STUB_MODE" in
        readfail)  echo 'Error from server (Forbidden): applications.argoproj.io is forbidden' >&2; return 1 ;;
        nocrd)     echo 'error: the server doesn'"'"'t have a resource type "application"' >&2; return 1 ;;
        empty)     case " $* " in *annotate*) return 0 ;; esac; printf '' ;;   # read SUCCEEDS, value empty
        haverev)   case " $* " in *annotate*) echo "ANNOTATE-WAS-CALLED" ; return 0 ;; esac; printf 'abc123' ;;
      esac
      return 0
    }
    argocd_await_revision testapp 2>&1 ) || true
}

echo
echo "════════ argocd_await_revision — does it still distinguish the failure modes? ════════"

echo
echo "== a FAILED read must name the READ, never the repo URL =="
out="$(run readfail)"
case "$out" in *"could not READ"*)          ok "a Forbidden names the READ" ;;
  *) bad "a Forbidden names the READ" "got: ${out:0:150}" ;; esac
case "$out" in *"$GITEA_ARGOCD_URL"*)       bad "a Forbidden must NOT blame the repo URL" "it printed $GITEA_ARGOCD_URL" ;;
  *) ok "a Forbidden does NOT mention the repo URL" ;; esac
case "$out" in *test-ns*)                   ok "it reports the resolved namespace" ;;
  *) bad "it reports the resolved namespace" "got: ${out:0:150}" ;; esac
case "$out" in *api.example*)               ok "it reports the API server it actually talked to" ;;
  *) bad "it reports the API server" "got: ${out:0:150}" ;; esac
case "$out" in *Forbidden*)                 ok "it surfaces kubectl's OWN words (stderr no longer discarded)" ;;
  *) bad "it surfaces kubectl's stderr" "got: ${out:0:150}" ;; esac

echo
echo "== a MISSING CRD is a read fault too, not a repo fault =="
out="$(run nocrd)"
case "$out" in *"could not READ"*)          ok "a missing CRD names the READ" ;;
  *) bad "a missing CRD names the READ" "got: ${out:0:150}" ;; esac
case "$out" in *"resource type"*)           ok "it quotes the CRD error verbatim" ;;
  *) bad "it quotes the CRD error" "got: ${out:0:150}" ;; esac

echo
echo "== an EMPTY revision (reads SUCCEEDED) is the ONLY case that may suspect the repo =="
out="$(run empty)"
case "$out" in *"EMPTY revision"*)          ok "an empty value is reported as an empty value" ;;
  *) bad "an empty value is reported as such" "got: ${out:0:150}" ;; esac
case "$out" in *"reads SUCCEEDED"*)         ok "it states that the reads worked, so this is real state" ;;
  *) bad "it states the reads worked" "got: ${out:0:150}" ;; esac
case "$out" in *"info/refs"*)               ok "it hands over the command that CONFIRMS the repo instead of guessing" ;;
  *) bad "it offers the confirming command" "got: ${out:0:150}" ;; esac
case "$out" in *"ONE candidate"*)           ok "the repo is offered as A candidate, not asserted as THE cause" ;;
  *) bad "the repo is offered as a candidate" "got: ${out:0:150}" ;; esac

echo
echo "== an Application that ALREADY has a revision must not be disturbed =="
out="$(run haverev)"
case "$out" in *"already at revision abc123"*) ok "an existing revision short-circuits the wait" ;;
  *) bad "an existing revision short-circuits" "got: ${out:0:150}" ;; esac
case "$out" in *ANNOTATE-WAS-CALLED*)       bad "it must NOT annotate an app that already answered" "refresh=hard rewrites .status.sync wholesale — needless risk of blanking the field we poll for" ;;
  *) ok "it does NOT annotate an app that already answered (read BEFORE annotate)" ;; esac

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
