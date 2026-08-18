#!/usr/bin/env bash
# test-argocd-await-revision.sh — offline, hermetic. Drives argocd_await_revision with a STUB `ka`.
#
# ⚠️ THIS SUITE HAS TWICE ENCODED THE BUG AS CORRECT. Read that before adding a case.
#
# Round 1: the check short-circuited on a pre-existing revision, so it exited 0 with ZERO repo
# contact. The suite's case asserted only that it did NOT annotate — and the product's own
# `>/dev/null 2>&1` ate the stub's echo, so a mutant that annotated FIRST still scored 13/13.
#
# Round 2: the short-circuit was removed and the OUTCOME kept. The check still tested PRESENCE of a
# revision, which persists across runs because both apply paths are UPSERT — so a stale revision
# plus GITEA_ARGOCD_URL pointed at a nonexistent host STILL exited 0 printing "the repo is
# reachable", after one annotate and two reads and no repo contact at all. The suite scored 16/16
# because its cases asserted the WORDING ("re-probing anyway") and the mechanism (an annotate in the
# witness), never the VERDICT.
#
# So the property under test is not "does it wait" and not "does it annotate". It is:
#     can this check still distinguish a FRESH fetch from a STALE value it merely found lying there?
# Every case below is written to fail if the answer becomes no. `.env.example` states the contract:
# "the gate that proves ArgoCD's repo-server can reach GITEA_ARGOCD_URL — a wrong URL used to sync
# green forever".
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/argocd.sh
. "${SCRIPT_DIR}/lib/argocd.sh"

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n       %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

export ARGOCD_NAMESPACE=test-ns
export ARGOCD_API=https://api.example:6443
export ARGOCD_KUBECONFIG=/tmp/nonexistent.kubeconfig
export ARGOCD_REPO_TIMEOUT_SECONDS=2      # keep it fast; the count is not the property
export GITEA_ARGOCD_URL=http://this-host-does-not-exist.invalid:3000
export GITEA_ORG=demo

# run <mode> [witness] — the function calls `die` (exit 1), so it runs in a subshell.
# The witness is a FILE: the product redirects the annotate, so anything the stub PRINTS on that
# path is swallowed by the product's own redirect and an assertion on it measures the redirect.
run() {
  ( # ⚠️ PRODUCTION OPTIONS, NOT THE SUITE'S. This file runs `set -uo pipefail`; the code under
    # test has NO `set` line of its own and inherits scripts/70-configure-argocd.sh:21, which is
    # `set -euo pipefail`. Running the subject under weaker options is why this suite has now
    # scored a clean green over a broken implementation THREE times: an errexit death in the
    # function is simply invisible here. MEASURED: a candidate fix passed 28/28 under the suite's
    # options and killed `make gitops` on the HEALTHY path under production's.
    set -euo pipefail
    export STUB_MODE="$1" WITNESS="${2:-/dev/null}"
    # shellcheck disable=SC2329  # invoked indirectly by argocd_await_revision
    ka() {
      case " $* " in
        *" annotate "*)
          printf 'annotate\n' >> "$WITNESS"
          case "$STUB_MODE" in
            annotate_denied) echo 'Error from server (Forbidden): applications.argoproj.io "x" is forbidden: cannot patch' >&2; return 1 ;;
          esac
          return 0 ;;
      esac
      printf 'read\n' >> "$WITNESS"
      # ⚠️ THESE STUBS MODEL ARGO-CD, NOT THIS IMPLEMENTATION. The previous version's `fresh` stub
      # advanced reconciledAt whenever an annotate had happened — which, per argo-cd v3.5.1's
      # source, is EXACTLY the state of an app whose repo is UNREACHABLE, and the suite asserted it
      # must PASS. A forced refresh is a Level-3 comparison, and Level 3 disables the repo-error
      # short-circuit (state.go:700-712), so reconciledAt advances and .status.sync.revision holds
      # the BRANCH NAME (state.go:653-655) even when nothing was fetched.
      case " $* " in
        *reconciledAt*)
          case "$STUB_MODE" in
            stale)  printf '2026-01-01T00:00:00Z' ;;
            *)      if [ -s "$WITNESS" ] && grep -q '^annotate$' "$WITNESS"; then printf '2026-06-06T12:00:00Z'; else printf '2026-01-01T00:00:00Z'; fi ;;
          esac
          return 0 ;;
        *ComparisonError*)
          # unreachable_real: the fetch FAILED, so argo-cd appends a ComparisonError (state.go:699)
          # signalfail: the READ ITSELF fails. Until this mode existed NO stub could fail these two
          # reads — both arms returned 0 unconditionally — so the suite had ZERO coverage of the
          # exact defect it was built to catch: `2>/dev/null || true` made an unreadable signal
          # indistinguishable from a healthy one, and the gate PASSED.
          case "$STUB_MODE" in
            signalfail) echo 'Error from server (Forbidden): applications.argoproj.io is forbidden: cannot get conditions' >&2; return 1 ;;
            # ⚠️ THE PREFIX IS PART OF THE FIXTURE. state.go:698 is
            #   msg := "Failed to load target state: " + err.Error()
            # so real argo-cd NEVER emits the bare rpc error. Without the prefix this fixture makes
            # the flagship case classify `notrepo` and lose "FETCH FAILED" (measured: 33/1 vs 34/0),
            # and the natural repair — editing the assertion — would pin a fixture asserting that a
            # genuine repo failure is NOT the repo.
            # The LEADING '; ' is what the real read emits: the jsonpath is
            #   {range .status.conditions[?(@.type=="ComparisonError")]}{"; "}{.message}{end}
            # so every message is separator-prefixed. The stub emulates kubectl, so it must too —
            # otherwise the prefix test sees a bare message and classifies a genuine repo failure as
            # `notrepo`. This is the stub tracking the product's read, not an assertion being bent.
            unreachable_real) printf '; Failed to load target state: rpc error: failed to get git client for repo http://this-host-does-not-exist.invalid:3000/demo/testapp-deploy.git' ;;
            # ── the four states the classifier distinguishes, none of which had ANY fixture ────────
            # advisory_real: argo-cd appended a ComparisonError from a site that does NOT set
            #   failedToLoadObjs (state.go:1053, "error setting app health: "), so sync.status stays
            #   Synced. The old `[ -n "$_cerr" ]` predicate KILLED install-all here on a deployment
            #   that is fine. This is the case with no prior coverage at all.
            advisory_real) printf '; error setting app health: some health error' ;;
            # notrepo_real: "Failed to load live state: " is the DESTINATION CLUSTER (state.go:777),
            #   not the repo. Must die, and must NOT offer the Gitea repo-server probe.
            notrepo_real)  printf '; Failed to load live state: the server could not find the requested resource' ;;
            # unjudged_real: Unknown with NO condition — the controller has not judged it.
            unjudged_real) printf '' ;;
            # repo_notfirst: argo-cd appends SEVERAL conditions to one list and the repo message is
            #   not always first (in v3.4.5 the GPG sites at 512-524 precede the repo site at 628).
            #   With a trailing/absent separator this classifies `notrepo` and tells the operator NOT
            #   to start at Gitea when Gitea IS the fault. The LEADING separator makes it positional-
            #   independent. The third entry MENTIONS the phrase inline and must NOT be matched.
            repo_notfirst) printf '; gpg signature check failed; Failed to load target state: rpc error: repo unreachable; a note mentioning Failed to load target state: inline' ;;
          esac
          return 0 ;;
        *sync.status*)
          case "$STUB_MODE" in
            signalfail) echo 'Error from server (Forbidden): applications.argoproj.io is forbidden: cannot get sync.status' >&2; return 1 ;;
            unreachable_real|notrepo_real|unjudged_real|repo_notfirst) printf 'Unknown' ;;
            # advisory_real is the whole point: the comparison COMPLETED, so argo-cd's own verdict is
            # Synced even though a condition is present.
            *) printf 'Synced' ;;
          esac
          return 0 ;;
      esac
      case "$STUB_MODE" in
        readfail) echo 'Error from server (Forbidden): applications.argoproj.io is forbidden' >&2; return 1 ;;
        nocrd)    echo 'error: the server doesn'"'"'t have a resource type "application"' >&2; return 1 ;;
        empty)    printf '' ;;
        condfail) case " $* " in *conditions*) echo 'Error from server (Forbidden): cannot read conditions' >&2; return 1 ;; esac; printf '' ;;
        signalfail) printf 'freshSHA9999' ;;                # healthy-looking: ONLY the signal read fails
        unreachable_real|notrepo_real|unjudged_real|repo_notfirst) printf 'main' ;;  # the BRANCH NAME - what argo-cd leaves after a FAILED fetch
        advisory_real) printf 'freshSHA9999' ;;             # the fetch SUCCEEDED — a real revision
        *)        printf 'staleSHA1234' ;;                  # a revision that PERSISTS from an earlier run
      esac
      return 0
    }
    # BARE call, deliberately: putting it in a `||`/`if` context would suspend `set -e` for the
    # ENTIRE function body and hide precisely the deaths this suite must see. Production calls it
    # bare too. RC therefore comes from an EXIT trap, which fires on a `die`, on an errexit death,
    # and on a normal return alike.
    trap 'printf "RC=%s\n" "$?"' EXIT
    # ⚠️ NO `|| true`, and its ABSENCE is the point. A trailing `||` makes the subshell the LEFT
    # OPERAND of an AND-OR list, and bash then suppresses errexit INSIDE it — the `set -euo pipefail`
    # on the first line of this subshell does NOT restore it. So the suite was blind to exactly the
    # deaths the comment above says it must see. MEASURED: a planted `_mut="$(grep NOPE /dev/null)"`
    # on the HEALTHY path scored 43 passed / 0 failed, rc=0, while the same tree under production's
    # options died at rc=1 without reaching the line after the call. That is verbatim the incident
    # the comment cites. Removing it is safe because THIS file runs `set -uo pipefail` with no `-e`,
    # so the non-zero subshell is absorbed by the `out="$(run …)"` capture. Proven both directions:
    # clean 43/0 (no false RED), mutant 39/4.
    argocd_await_revision testapp 2>&1 )
}

echo
echo "════════ argocd_await_revision — can it still tell FRESH from STALE? ════════"

echo
echo "== THE ROUND-2 CASE: a stale revision + an unreachable repo must NOT pass =="
# MEASURED on the previous version: exit 0, "the repo is reachable", zero repo contact.
W="$(mktemp)"; out="$(run stale "$W")"; wit="$(cat "$W")"; rm -f "$W"
case "$out" in *RC=0*) bad "a stale revision must NOT report success" "it exited 0 with GITEA_ARGOCD_URL pointing at a nonexistent host — presence is not freshness" ;;
  *) ok "a stale revision does NOT report success" ;; esac
case "$out" in *"did NOT re-reconcile"*) ok "it says WHY: reconciledAt never advanced" ;;
  *) bad "it explains the staleness" "got: ${out:0:170}" ;; esac
# ⚠️ Match the SUCCESS sentence, not the substring: the honest FAILURE message contains
# "...obtained NO evidence the repo is reachable now", so a bare "the repo is reachable" grep
# fires on the correct text and reports a product defect that is really a test defect.
case "$out" in *"is reachable NOW"*) bad "it must not claim reachability it never established" "that claim is the whole defect" ;;
  *) ok "it does NOT claim the repo is reachable" ;; esac
case "$wit" in *annotate*) ok "it did force a refresh (so the failure is a real negative, not a skip)" ;;
  *) bad "it forced a refresh" "witness=[$wit]" ;; esac

echo
echo "== a FRESH reconcile (reconciledAt advances past the refresh) must pass =="
W="$(mktemp)"; out="$(run fresh "$W")"; rm -f "$W"
case "$out" in *RC=0*) ok "a fresh reconcile reports success" ;;
  *) bad "a fresh reconcile reports success" "got: ${out:0:170}" ;; esac
case "$out" in *"re-reconciled after a forced refresh"*) ok "...and says what the evidence WAS" ;;
  *) bad "it names its evidence" "got: ${out:0:170}" ;; esac

echo "== THE DECISIVE CASE: argo-cd's REAL unreachable-repo state must NOT pass =="
# This is the property; everything else in this file is scaffolding. Per argo-cd v3.5.1, an app
# whose repo cannot be reached, AFTER A FORCED REFRESH, presents as:
#     reconciledAt ADVANCED  ·  sync.revision = the BRANCH NAME (non-empty)
#     sync.status  = Unknown ·  a ComparisonError condition
# Two previous versions of this check asserted exactly that state was SUCCESS. MEASURED then:
# "re-reconciled ... reports revision main - the repo is reachable NOW", rc=0, against
# this-host-does-not-exist.invalid.
W="$(mktemp)"; out="$(run unreachable_real "$W")"; rm -f "$W"
case "$out" in *RC=0*) bad "argo-cd's real unreachable state must NOT report success" "reconciledAt advances on a forced refresh even when the fetch failed - that is the whole trap" ;;
  *) ok "argo-cd's real unreachable state does NOT report success" ;; esac
case "$out" in *"is reachable NOW"*) bad "it must not claim reachability" "the fetch demonstrably failed" ;;
  *) ok "it does NOT claim the repo is reachable" ;; esac
case "$out" in *"FETCH FAILED"*) ok "it names the FETCH as what failed, not the reconcile" ;;
  *) bad "it names the fetch" "got: ${out:0:190}" ;; esac
case "$out" in *ComparisonError*|*"failed to get git client"*) ok "it surfaces argo-cd's OWN ComparisonError message" ;;
  *) bad "it surfaces the ComparisonError" "got: ${out:0:190}" ;; esac

echo
echo "== a REFUSED refresh is an RBAC fault and must not be swallowed =="
# MEASURED on the previous version: annotate Forbidden -> "re-probing anyway (a stale revision is
# not proof)" -> "the repo is reachable", rc=0, the Forbidden never mentioned. The write was the one
# call left with `2>/dev/null || true` while both reads had been fixed.
out="$(run annotate_denied)"
case "$out" in *RC=0*) bad "a refused refresh must NOT report success" "nothing after it can prove anything" ;;
  *) ok "a refused refresh does NOT report success" ;; esac
case "$out" in *"could not force a refresh"*) ok "it names the REFRESH as the failure" ;;
  *) bad "it names the refresh" "got: ${out:0:170}" ;; esac
case "$out" in *Forbidden*) ok "it surfaces kubectl's own words (the write's stderr is no longer discarded)" ;;
  *) bad "it surfaces the Forbidden" "got: ${out:0:170}" ;; esac
case "$out" in *"RBAC fault, not a repo fault"*) ok "and it says this is RBAC, not the repo" ;;
  *) bad "it distinguishes RBAC from the repo" "got: ${out:0:170}" ;; esac

echo
echo "== a FAILED read must name the READ, never the repo URL =="
out="$(run readfail)"
case "$out" in *"could not READ"*) ok "a Forbidden read names the READ" ;;
  *) bad "a Forbidden read names the READ" "got: ${out:0:150}" ;; esac
case "$out" in *"$GITEA_ARGOCD_URL"*) bad "a read fault must NOT blame the repo URL" "it printed the URL" ;;
  *) ok "a read fault does NOT mention the repo URL" ;; esac
out="$(run nocrd)"
case "$out" in *"could not READ"*) ok "a missing CRD is a read fault too" ;;
  *) bad "a missing CRD names the READ" "got: ${out:0:150}" ;; esac

echo
echo "== an EMPTY revision still offers the repo as ONE candidate, with the confirming command =="
out="$(run empty)"
case "$out" in *"EMPTY revision"*|*"did NOT re-reconcile"*) ok "an empty value is reported honestly" ;;
  *) bad "an empty value is reported" "got: ${out:0:150}" ;; esac
case "$out" in *"info/refs"*) ok "it hands over the command that CONFIRMS the repo instead of guessing" ;;
  *) bad "it offers the confirming command" "got: ${out:0:150}" ;; esac
case "$out" in *"ONE candidate"*) ok "the repo is A candidate, not asserted as THE cause" ;;
  *) bad "the repo is offered as a candidate" "got: ${out:0:150}" ;; esac

echo
echo "== a failed CONDITIONS read must not be reported as 'no conditions' =="
out="$(run condfail)"
case "$out" in *"could not read the conditions"*) ok "a Forbidden on the conditions read is named as a READ fault" ;;
  *) bad "conditions read fault is named" "got: ${out:0:200}" ;; esac
case "$out" in *"reports NO conditions"*) bad "it must NOT claim 'no conditions' when the read FAILED" "an affirmative falsehood pointing at the repo" ;;
  *) ok "it does NOT claim 'no conditions' when the read failed" ;; esac

echo
echo "== the attempts guard must reject what it claims to, INCLUDING empty =="
# The '' arm used to be unreachable: `${VAR:-180}` had already substituted the default, so an EMPTY
# value silently took 180 attempts — and empty was the OLD code's real trigger (`seq 1 ""` = 0).
for v in abc 0 -5 '' '12s'; do
  o="$( ARGOCD_REPO_TIMEOUT_SECONDS="$v" run stale )"
  case "$o" in *'must be a positive integer'*) ok "ARGOCD_REPO_TIMEOUT_SECONDS='${v}' is rejected" ;;
    *) bad "ARGOCD_REPO_TIMEOUT_SECONDS='${v}' rejected" "it was accepted — got: ${o:0:90}" ;; esac
done

echo
echo "== the diagnostic must survive UNSET variables (it runs under set -u and its job is to PRINT) =="
o="$( unset ARGOCD_API ARGOCD_KUBECONFIG GITEA_ARGOCD_URL GITEA_ORG; run readfail )"
case "$o" in *"could not READ"*) ok "with ARGOCD_API/KUBECONFIG/GITEA_* unset it still prints the diagnosis" ;;
  *) bad "it survives unset variables" "got: ${o:0:150} — it likely died mid-print under set -u" ;; esac

echo
echo
echo "== a FAILED read of the FETCH SIGNAL must not be mistaken for a healthy fetch =="
# THE DEFECT THIS GROUP EXISTS FOR. Both signal reads used `2>/dev/null || true`, so a Forbidden
# gave two empty strings, the predicate was FALSE, `! _await_fetch_failed` was TRUE, and the gate
# set _fresh=1 and PASSED — a false green inside the gate built to prevent false greens. In this
# mode the Application looks entirely healthy (revision advances, reconciledAt advances); ONLY the
# signal read fails. So a pass here means the check cannot tell "the fetch is fine" from "I could
# not ask".
W="$(mktemp)"; out="$(run signalfail "$W")"; rm -f "$W"   # witness => reconciledAt ADVANCES, so ONLY the signal read is broken
case "$out" in *'RC=0'*) bad "an unreadable fetch signal must NOT pass the gate" "it exited 0 — the false green is back" ;;
  *) ok "an unreadable fetch signal does NOT pass the gate" ;; esac
case "$out" in *"could not READ the fetch signal"*) ok "it names the READ as the fault" ;;
  *) bad "it names the READ" "got: ${out:0:200}" ;; esac
case "$out" in *Forbidden*) ok "it surfaces kubectl's OWN words (the read's stderr is captured, not /dev/null'd)" ;;
  *) bad "it surfaces kubectl's stderr" "got: ${out:0:200}" ;; esac
case "$out" in *"NO evidence either way about the repo"*) ok "it declines to say anything about the repo" ;;
  *) bad "it declines to implicate the repo" "got: ${out:0:200}" ;; esac
case "$out" in *"$GITEA_ARGOCD_URL"*) bad "a read fault must NOT blame the repo URL" "it printed $GITEA_ARGOCD_URL" ;;
  *) ok "a read fault does NOT mention the repo URL" ;; esac
# CONTROL: the SAME app shape with a READABLE signal must still pass, or the case above would be
# satisfied by any regression that simply breaks the gate.
W="$(mktemp)"; out="$(run fresh "$W")"; rm -f "$W"
case "$out" in *'RC=0'*) ok "CONTROL — a healthy app with a readable signal still PASSES" ;;
  *) bad "CONTROL: healthy still passes" "got: ${out:0:200}" ;; esac

echo
echo "== a ComparisonError is NOT a repo verdict — one arm per cause =="
# THE FALSE RED THIS SECTION EXISTS FOR. `[ -n "$_cerr" ]` treated ANY ComparisonError as a failed
# fetch and killed `make install-all` at configure-argocd. But state.go:1035's
# `if failedToLoadObjs { syncCode = Unknown }` is the ONLY app-level forcing, and the appends at 749
# (normalize), 1053 (health) and 1060 (source-integrity) close their `if err != nil` block with NO
# flag — so an Application can be Synced/Healthy while carrying one. Both unflagged sites sit AFTER a
# successful GetRepoObjs, so they cannot coexist with a failed fetch.
# RED-PROOF: on the pre-fix product this case exits RC=1 with "RECONCILED but the FETCH FAILED" —
# and the output self-contradicts, printing `sync.status=Synced` on the line beneath it.
W="$(mktemp)"; out="$(run advisory_real "$W")"; rm -f "$W"
case "$out" in *'RC=0'*) ok "a NON-repo ComparisonError on a Synced app PASSES (the fetch succeeded)" ;;
  *) bad "advisory must pass" "got: ${out:0:220}" ;; esac
# Assert the WARN, not just the pass: without it a future regression to an unconditional pass scores
# green and nobody sees the difference.
case "$out" in *"NON-repo ComparisonError is present"*) ok "and it is NOT silent — the condition is surfaced as a WARN" ;;
  *) bad "advisory must WARN" "a silent pass is indistinguishable from not checking" ;; esac
case "$out" in *"FETCH FAILED"*) bad "advisory must not claim the fetch failed" "the comparison completed" ;;
  *) ok "it does NOT claim the fetch failed" ;; esac

# The DESTINATION CLUSTER, not the repo (state.go:777). Must die — and must not send the operator to Gitea.
out="$(run notrepo_real)"
case "$out" in *'RC=0'*) bad "a non-repo comparison failure must NOT pass" "sync.status=Unknown means the comparison failed" ;;
  *) ok "a NON-repo comparison failure still FAILS the gate" ;; esac
case "$out" in *"NOT the repo"*) ok "it names the cause as NOT the repo" ;;
  *) bad "notrepo must say so" "got: ${out:0:220}" ;; esac
case "$out" in *"argocd-repo-server"*|*"info/refs?service=git-upload-pack"*)
      bad "notrepo must NOT offer the Gitea repo-server probe" "that is the misdirection this split exists to remove" ;;
  *) ok "and it does NOT offer the Gitea repo-server probe" ;; esac

# Unknown with NO condition: the controller has not judged it. Must die, must not blame the repo.
out="$(run unjudged_real)"
case "$out" in *'RC=0'*) bad "an unjudged Application must NOT pass" "nothing judged it, so nothing is evidence" ;;
  *) ok "an UNJUDGED Application still FAILS the gate" ;; esac
case "$out" in *"has not judged"*) ok "it says the controller has not judged it" ;;
  *) bad "unjudged must say so" "got: ${out:0:220}" ;; esac

# The repo message is NOT first in the list. With a trailing/absent separator this classified
# `notrepo` and told the operator not to start at Gitea when Gitea WAS the fault.
out="$(run repo_notfirst)"
case "$out" in *"FETCH FAILED"*) ok "a repo message that is NOT FIRST is still classified as the repo" ;;
  *) bad "position-independent prefix test" "got: ${out:0:220}" ;; esac

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
