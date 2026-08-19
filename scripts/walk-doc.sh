#!/usr/bin/env bash
# walk-doc.sh — execute docs/scenario-1.md ITSELF, block by block, in document order.
#
# WHY THIS REPLACES A HAND-WRITTEN DRIVER. The previous walker carried ~50 hardcoded steps that were
# a SECOND COPY of the runbook, and second copies drift: it encoded the OLD document's ordering
# defects as workarounds, never opened <details> blocks, and after a renumbering its labels named
# steps that no longer existed. A walker that does not READ the document validates the author's
# memory of it, not the document.
#
# ⚠️ THE FIRST VERSION OF THIS SCRIPT REPORTED "0 failed" OVER A WALK IN WHICH EVERY BLOCK DIED WITH
# `make: command not found`. An adversary round measured why, and most of what follows is the fix.
# Read the numbered notes before "simplifying" any of it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The document comes from WALK_DOC, NEVER from $1. A positional argument used to be SILENTLY
# IGNORED, which is the worst possible behaviour: `walk-doc.sh docs/scenario-2.md` walked
# scenario-1 and reported scenario-1's numbers with no hint that it had substituted a different
# document. MEASURED 2026-08-16: a one-block probe document invoked that way reported "40
# extracted, 29 Expect" — scenario-1's figures exactly — and I believed a scenario-2 measurement
# that had never looked at scenario-2. Refuse instead; the default stays for the no-argument case.
if [ "$#" -gt 0 ]; then
  printf 'walk-doc.sh takes NO positional arguments (got %s: %s).\n' "$#" "$*" >&2
  printf '  The document is chosen with WALK_DOC. You almost certainly meant:\n' >&2
  printf '      WALK_DOC=%s bash %s\n' "$1" "$0" >&2
  printf '  Ignoring it silently would walk the DEFAULT document and report ITS numbers as yours.\n' >&2
  exit 2
fi
DOC="${WALK_DOC:-${SCRIPT_DIR}/../docs/scenario-1.md}"
[ -s "$DOC" ] || { echo "no document at $DOC"; exit 1; }
# (8) NO DEFAULT. `WALK_EXISTS:-1` skipped all four provisioning blocks, so a row meant to exercise
# the install path scored green having installed nothing. Forgetting must not be the cheap option.
: "${WALK_EXISTS:?set 0 (install path) or 1 (already-exists path) explicitly}"
# A SEPARATE axis from WALK_EXISTS: a Harbor robot can already exist on a lab whose namespace and
# cluster do not (a previous jump box minted it), and the reverse. Harbor shows a robot secret
# ONCE, so `make harbor-robot` CANNOT be re-run to recover it -- stopping is correct, and a walk
# must not score that as a document defect.
: "${WALK_ROBOT_EXISTS:?set 0 (mint a robot) or 1 (one already exists elsewhere) explicitly}"
# PER-RESOURCE AXES. "everything exists" and "nothing exists" are not the only two states a real lab
# is in, and treating them as such cost a matrix row: Harbor deregistered cleanly while ArgoCD would
# not, leaving a lab that is genuinely "Harbor absent, ArgoCD present" -- a legitimate cell that one
# boolean cannot express. Each defaults to WALK_EXISTS, so the simple case stays one knob.
WALK_NS_EXISTS="${WALK_NS_EXISTS:-$WALK_EXISTS}"
WALK_HARBOR_EXISTS="${WALK_HARBOR_EXISTS:-$WALK_EXISTS}"
WALK_ARGOCD_EXISTS="${WALK_ARGOCD_EXISTS:-$WALK_EXISTS}"
WALK_CLUSTER_EXISTS="${WALK_CLUSTER_EXISTS:-$WALK_EXISTS}"
# NO DEFAULT, and it cost a row to learn why. Step 12 says to run the command `make istio-preflight`
# PRINTS. With WALK_ISTIO defaulting to `existing`, the walk ran the ATTACH variant on a cluster
# whose preflight had just said, in the block immediately before, "NO Istio detected -> use
# 'make install-ingress' to INSTALL it". The walk contradicted the document and then scored the
# resulting failure against the document. A default here is a silent wrong answer.
: "${WALK_ISTIO:?set to 'install', 'existing', or 'auto' — 'auto' READS 'make istio-preflight' for THIS cluster, which is what the document tells the reader to do}"

# WALK_ISTIO=auto — NAVIGATE, do not be told.
#
# Step 12 says, in bold: "istio-preflight is read-only and it ends by naming the exact command to
# run next — run the one it prints", and "⚠️ Never run the bare `make install-ingress` against a
# mesh you did not install." A walk that is HANDED the branch is not walking the document; it is
# walking a decision someone made outside it.
#
# MEASURED 2026-08-12: walk-matrix.sh:257 hardcoded `WALK_ISTIO=install` for EVERY row -- including
# rows 2 and 4, which walk the guest cluster where rows 1 and 3 had just INSTALLED Istio. So the
# harness did precisely what that warning forbids, on half the matrix, and scored it.
#
# `auto` resolves the same way the reader does: by reading what `make istio-preflight` printed
# earlier in this step. Undecided is a SKIP, never a guess -- same rule as an unsubstituted
# <placeholder>.
_istio_mode() {
  case "${WALK_ISTIO:-}" in install|existing) printf '%s' "$WALK_ISTIO"; return ;; esac
  # KEY ON THE VERDICT, NOT THE FLAG. `INGRESS_CONTROLLER=istio-existing` has FIVE emit sites in
  # 48-istio-preflight.sh (:72 :91 :126 :139 :217) and TWO of them are FAILURE paths:
  #   :126 is a log_error followed by `exit 1` (:128) — discovery was REFUSED, here is what to set;
  #   :139 (the "someone else installed it" MODE line) prints BEFORE the RBAC checks at :171-177,
  #        :201 and :212 that can set rc=1 -> `:219 PREFLIGHT INCOMPLETE` -> exit 1.
  # STEP_OUT_FILE captures stderr (:566 redirects 2>&1), so both were visible to the old grep, which
  # therefore classified EVERY failed/incomplete preflight as "a mesh is here, attach to it".
  #
  # ⚠️ THE ANCHOR IS LOAD-BEARING — do NOT "simplify" it to a bare `PREFLIGHT OK`. That substring is
  # also emitted by TWO OTHER scripts: 24-lab-preflight.sh:171 ("LAB PREFLIGHT OK — ...") and
  # 23-argocd-preflight.sh:309 ("PREFLIGHT OK — clusters answer, ..."). They are harmless today only
  # because STEP_OUT_FILE is truncated per `## ` heading (:530) and those blocks live under different
  # headings — an accident that a shared-step extraction which MERGES headings would silently undo.
  # The anchored form is immune, and was measured identical to the bare form on all six real istio
  # paths. Only :91 and :217 (both success verdicts; :217 is gated on rc==0 at :216-220) emit it.
  if   grep -q 'NO Istio detected'                    "$STEP_OUT_FILE" 2>/dev/null; then printf 'install'
  elif grep -q "PREFLIGHT OK — 'make install-ingress" "$STEP_OUT_FILE" 2>/dev/null; then printf 'existing'
  else printf 'undecided'; fi
}

STEP=0; RAN=0; FAILED=0; SKIPPED=0
# The DOCUMENT's own claims, counted separately from the commands' exit codes. "32 blocks ran"
# says the COMMANDS worked; it says nothing about whether the reader saw what they were told
# they would see. These two numbers answer different questions and must not be conflated.
EXPECT_TOTAL=0; EXPECT_MISS=0; EXPECT_LINES_PARSED=0; EXPECT_UNSEEN=0
SKIP_LOG="$(mktemp)"; NEUT_LOG="$(mktemp)"; CWD_FILE="$(mktemp)"; RC_FILE="$(mktemp)"; UNSAFE_FILE="$(mktemp)"; OUT_FILE="$(mktemp)"; STEP_OUT_FILE="$(mktemp)"; EXPECT_LOG="$(mktemp)"
ENV_FILE="$(mktemp)"; : > "$ENV_FILE"
# ⚠️ EVERY mktemp'd file BELONGS IN THIS TRAP. B186: three of these were absent, so a SECOND COPY
# of every step's output — credentials included — survived on every walk box, one per row, for
# the life of the VM. MEASURED 2026-08-18 by enumerating both sides rather than trusting the
# row: 10 files are mktemp'd (the row says 8) and 4 survived (the row says 3) — it misses
# PREENV_FILE, created LATER at :101, which is exactly how a file escapes a trap written above
# it. OUT_FILE / STEP_OUT_FILE / EXPECT_LOG carry step OUTPUT (the credential-bearing ones);
# PREENV_FILE carries only exported variable NAMES, which is lower risk and still not ours to
# leave behind. The walk boxes are throwaway VMs, which BOUNDS the exposure and does not
# remove it: a box lives for a whole row and anything with shell on it can read the file.
# If you add another mktemp, add it here in the same edit — the trap is not derived, so
# nothing will tell you.
trap 'rm -f "$SKIP_LOG" "$NEUT_LOG" "$CWD_FILE" "$RC_FILE" "$UNSAFE_FILE" "$ENV_FILE" \
             "$OUT_FILE" "$STEP_OUT_FILE" "$EXPECT_LOG" "$PREENV_FILE"' EXIT
# WHO SET IT, snapshotted BEFORE the first block runs. Everything the harness supplies is
# lab-specific and outranks the document's illustrative examples; everything else is the document's
# to set, including overriding a value an EARLIER table row set. Taken here because after the walk
# starts the two are indistinguishable -- see the ENVROWS loop.
PREENV_FILE="$(mktemp)"; compgen -e > "$PREENV_FILE" 2>/dev/null || : > "$PREENV_FILE"
CWD="${WALK_START_DIR:-$PWD}"

# ── Whole-block skips: a block a WALK must not run, never a block that is broken.
# (4) Match COMMAND LINES only. Matching the raw block let a comment that merely WARNS about
# `make uninstall-all` skip the `make verify` beside it -- and label it a teardown block.
should_skip() {
  local code; code="$(printf '%s' "$1" | sed 's/#.*//')"
  case "$code" in
    *"make uninstall-all"*)     printf 'teardown - would destroy the lab mid-walk' ;;
    # ORDER MATTERS: the attach variant's text also contains "make install-ingress", and `case` takes
    # the FIRST match -- with the general pattern first, BOTH blocks were skipped and Step 12 ran no
    # install at all, which is the defect the document was just fixed for.
    *"INGRESS_CONTROLLER=istio-existing"*)
                                case "$(_istio_mode)" in
                                  existing)  ;;
                                  undecided) printf 'istio-preflight has not said which branch this cluster needs — a walk must not guess' ;;
                                  *)         printf 'attach variant; istio-preflight said this cluster has NO Istio' ;;
                                esac ;;
    *"make install-ingress"*)   case "$(_istio_mode)" in
                                  install)   ;;
                                  undecided) printf 'istio-preflight has not said which branch this cluster needs — a walk must not guess' ;;
                                  *)         printf 'install variant; istio-preflight named the ATTACH command for this cluster' ;;
                                esac ;;
    *"install-harbor-service"*) [ "$WALK_HARBOR_EXISTS" = 1 ] && printf 'Harbor already exists (this row)' ;;
    *"install-argocd-service"*) [ "$WALK_ARGOCD_EXISTS" = 1 ] && printf 'ArgoCD already exists (this row)' ;;
    *"make vsphere-namespace"*) [ "$WALK_NS_EXISTS" = 1 ] && printf 'namespace already exists (this row)' ;;
    *"make harbor-robot"*)      [ "$WALK_ROBOT_EXISTS" = 1 ] && printf 'a Harbor robot already exists; its secret is shown ONCE and cannot be re-read' ;;
    *"vks-cluster-create"*)     [ "$WALK_CLUSTER_EXISTS" = 1 ] && printf 'cluster already exists (this row)' ;;
    *"git clone https"*)        [ "${WALK_SKIP_CLONE:-0}" = 1 ] && printf 'already cloned by the harness' ;;
    *"apt-get install"*)        [ "${WALK_OS:-}" = photon ] && printf 'Ubuntu block; this box is Photon' ;;
    *"tdnf install"*)           case "${WALK_OS:-}" in ubuntu|debian) printf 'Photon block; this box is %s' "$WALK_OS" ;; esac ;;
  esac
}

# (6) Substitute ONLY when the value is non-empty. Replacing the placeholder with "" deleted the
# evidence the guard keys on, so two blocks ran `export VCF_CLI_VSPHERE_PASSWORD=''` and were counted
# as RAN -- then failed downstream on an auth error that reads like a document defect. An empty
# string IS an invented value.
#
# 🔴 A `<argocd-lb-ip>` SUBSTITUTION WAS ADDED HERE ON 2026-08-18 AND REVERTED THE SAME DAY.
# It is recorded rather than deleted so nobody rebuilds it. Three independent reasons, all measured:
#
#   (1) IT WAS INERT. Its comment asserted, as a measured fact, that the harness "exports it as
#       ARGOCD_LB_IP". It does not: `ARGOCD_LB_IP` occurs ZERO times in the whole
#       nested-vsphere-lab repo, and walk-matrix.sh:541 emits `ARGOCD_SERVER=$(cat …/.as)`.
#       ARGOCD_LB_IP is published ONLY by scripts/07-install-argocd.sh — the KinD flow — into
#       .env.state, and row 5's own log prints "state: no overlay (.env.state does not exist)".
#       Running the new substitute() with the exact harness env left `<argocd-lb-ip>` in place and
#       the block still SKIPPED. It changed nothing while reading as a fix.
#
#   (2) POINTING IT AT ARGOCD_SERVER WOULD NOT HAVE HELPED EITHER, because the block it un-skips
#       CANNOT COMPLETE ITS OWN PURPOSE: scenario-2.md's step 3 of that 3-step procedure ("put the
#       NAME in .env") is COMMENTS ONLY, and fetch-ca.sh merely PRINTS "set it in .env, e.g.
#       ARGOCD_CA_FILE=…" without publishing the var. After the block, ARGOCD_SERVER is still the
#       bare IP — i.e. exactly the IP-endpoint + CA-present combination B148 lab-verified can NEVER
#       verify (the cert carries DNS SANs and no IP SAN).
#
#   (3) IT WOULD HAVE ADDED A NEW FAILURE MODE TO A CERTIFYING ROW. fetch-ca.sh is
#       `set -euo pipefail`, so the change converts a counted SKIP into a block that can FAIL — on
#       rows 5/6, which already carry one. And `tee -a` APPENDS, so a retried row duplicates the
#       /etc/hosts line.
#
# The honest state is: that block is deliberately NOT walked, because its third step is unwalkable.
# Making it walkable is a DOCUMENT change (a real state_set/sed line), not a substitution.
#
# (6) Substitute ONLY when the value is non-empty. Replacing the placeholder with "" deleted the
# evidence the guard keys on, so two blocks ran `export VCF_CLI_VSPHERE_PASSWORD=''` and were counted
# as RAN -- then failed downstream on an auth error that reads like a document defect. An empty
# string IS an invented value.
#
# ⚠️ NOT `${s//pat/repl}`. On bash >= 5.2 an `&` in the REPLACEMENT expands to the whole match, so a
# password containing `&` reinserts the literal placeholder, has_live_placeholder then fires, and the
# block is SKIPPED with a message blaming the DOCUMENT. MEASURED on bash 5.2.21:
#     s="pw=<P> end"; v="Q&Z";  ${s//<P>/$v}  ->  pw=Q<P>Z end        (and "a&&b" -> two placeholders)
# It is bash-VERSION-dependent (literal on < 5.2), so the Photon and Ubuntu rows can disagree on the
# same password — a divergence that would read as an OS bug. `\`, `*`, `%`, `#`, `"` are all safe.
#
# ⚠️ AND NOT the obvious `while [[ $s == *"$ph"* ]]; do s="${s%%…}$v${s#*…}"; done` repair either: it
# RE-SCANS the text it just inserted, so a value that CONTAINS the placeholder loops FOREVER —
# measured, it hung a 3s probe. A hang inside the walker burns an entire lab cut, which is worse than
# the bug being fixed. The form below consumes left-to-right into `out` and never re-scans, so it
# terminates on every input (verified: value-contains-placeholder returns in milliseconds).
_subst_literal() {              # $1 haystack  $2 needle  $3 replacement (all literal, no globbing)
  local rest="$1" needle="$2" repl="$3" out=''
  while case "$rest" in *"$needle"*) true ;; *) false ;; esac; do
    out="${out}${rest%%"$needle"*}${repl}"
    rest="${rest#*"$needle"}"
  done
  printf '%s' "${out}${rest}"
}

substitute() {
  local s="$1"
  [ -n "${VCF_CLI_VSPHERE_PASSWORD:-}" ] \
    && s="$(_subst_literal "$s" '<your SSO password>' "$VCF_CLI_VSPHERE_PASSWORD")"
  printf '%s' "$s"
}

# (5) A line a walk cannot run is COMMENTED OUT and counted -- not grounds to drop the whole block,
# which would also drop the runnable commands beside it (block [13]: `argocd login` sits next to the
# credential read the walk needs). BUT a matched line inside a `\` continuation cannot be commented
# out in isolation: doing so silently DELETES an argument from the surviving command and still
# reports "1 line neutralized". Refuse the block instead -- half-executing is worse than not.
# $2 = "log" -> record what was neutralized. Called twice per block (once to build the text that is
# PRINTED, once to build the text that RUNS), so exactly one caller may log or the count doubles.
#
# ⚠️ THE REASON IS PER-ARM. It used to be ONE shared string, "needs a TTY / blocks forever",
# which was FACTUALLY WRONG for two of the three arms — a false fact inside a control, which is
# worse than no comment because it sends the next reader to fix the wrong thing. Corrected
# 2026-08-17 with each arm's measured reason, plus what (if anything) covers the lost claim:
# a neutralized line whose claim NOTHING else proves is a coverage hole, while one that merely
# duplicates a proven path is not, and the old output conflated the two (B152).
neutralize() {
  local out="" line prev="" why="" cov=""
  while IFS= read -r line; do
    why=""; cov=""
    case "$line" in
      *"argocd login"*)
        # MEASURED (argocd v3.0.19+d67e6eb90-vcf; also absent from upstream's docs): there is
        # NO `--password-stdin` — passing it errors `unknown flag`. The ONLY non-interactive
        # form is `--password <string>`, i.e. the secret in ARGV, which security.md forbids;
        # and the prompt reads the TTY directly (terminal.ReadPassword on stdin's fd), so
        # piping into a bare `argocd login` fails too. Do NOT "fix" this by rewriting the line:
        # scenario-1:384 DELIBERATELY describes an interactive step ("prompts … paste what
        # `make argocd-password` printed"), so a rewrite would test a command no reader types.
        # The argv-safe way to prove this credential is the session-API POST already working in
        # scripts/91-e2e-tenant-mechanism.sh:241+ — which belongs in a TARGET, not in here.
        why='TTY-bound, and there is NO argv-safe non-interactive form (no --password-stdin)'
        cov='UNCOVERED — nothing else in the matrix authenticates to ArgoCD (B152)' ;;
      *"argocd account update-password"*)
        # NOT a TTY problem — `--current-password`/`--new-password` DO exist. Two reasons to
        # refuse anyway: they put secrets in ARGV, and it MUTATES the only ArgoCD admin
        # credential on a SHARED lab. scenario-1:830-831 already records the fallout ("it can
        # only show the generated one"), so walking it would poison every later step in this
        # row AND every later row on the same cut. This one must stay neutralized forever.
        why='a MUTATION a walk must not perform on a shared lab (NOT a TTY problem)'
        cov='UNCOVERED — deliberately, see the reason' ;;
      *"port-forward"*)
        # A non-terminating FOREGROUND process: it blocks forever. It does NOT need a TTY.
        why='never terminates — a foreground port-forward blocks forever'
        cov='ingress path proven by "make verify-ingress"; the port-forward FALLBACK is UNCOVERED' ;;
    esac
    if [ -n "$why" ]; then
      case "$line" in *\\) echo 1 > "$UNSAFE_FILE" ;; esac   # continues into the next line
      case "$prev" in *\\) echo 1 > "$UNSAFE_FILE" ;; esac   # is a continuation of the previous
      out+="# WALK-NEUTRALIZED (${why}): ${line}"$'\n'
      # ⚠️ EXACTLY ONE LINE PER ITEM. The verdict's neutralized count is `wc -l < "$NEUT_LOG"`
      # (line ~704), so a multi-line record here silently MULTIPLIES the reported count — an
      # inflated denominator, which reads as more thorough and is a lie. Keep why/covered-by on
      # this same line, or change the count's source in the same edit.
      [ "${2:-}" = log ] && printf '  neutralized: %s\n' \
        "${line# }   [why: ${why} | covered-by: ${cov}]" >> "$NEUT_LOG"
    else
      out+="${line}"$'\n'
    fi
    prev="$line"
  done <<< "$1"
  printf '%s' "$out"
}

# (7) `[a-z]` missed `<EXTERNAL-IP>`, `<NS>`, `<YOUR-TOKEN>` -- every conventional UPPERCASE
# placeholder. (Comments are prose: checking the raw block skipped the LOGIN block, the most
# important one in the walk, over `# note the <ctx>:<ns> colon form`.)
has_live_placeholder() {
  printf '%s' "$1" | sed 's/#.*//' | grep -q '<[A-Za-z][^>]*>'
}

# LINE BY LINE, as a reader runs it. Executing a whole block as ONE `bash -c` collapses four
# commands into one exit code and one lump of output -- so a reader who runs them one at a time,
# looking at each result before typing the next, is NOT what was tested. The unit must be the
# STATEMENT.
#
# Where a statement ENDS is decided by BASH ITSELF (`bash -n` on the accumulated text), not by a
# regex: `\`-continuations, `if/then/fi`, `for/do/done`, heredocs and multi-line quotes are all
# incomplete until they are complete, and any hand-rolled splitter gets one of them wrong and then
# executes a fragment.
split_statements() {   # <block text> -> NUL-separated statements on stdout
  local acc="" line
  while IFS= read -r line || [ -n "$line" ]; do
    acc="${acc}${line}"$'\n'
    # skip blank/comment-only accumulations rather than emitting them as "commands"
    case "$(printf '%s' "$acc" | sed 's/#.*//' | tr -d '[:space:]')" in '') continue ;; esac
    # ⚠️ `bash -n` accepts a TRAILING BACKSLASH as complete -- the backslash-newline is simply
    # removed and the command ends at EOF. So the completeness test alone CUTS A CONTINUATION INTO
    # SEPARATE COMMANDS. MEASURED on a real walk: the runbook's three-line
    #     vcf context create "$CTX" --endpoint "$SUP" \
    #         --ca-certificate ./secrets/supervisor-ca.crt \
    #         --username "$USER" --type kubernetes --auth-type basic
    # ran as THREE commands -- `[x] : accepts at most 1 arg(s), received 2`, then
    # `--ca-certificate: command not found`, then `--username: command not found`. The walk was
    # executing something no reader ever would, which makes every verdict about it worthless.
    _last="${acc%$'\n'}"
    case "$_last" in
      *\\)  # an ODD number of trailing backslashes is a continuation; an EVEN number is an
             # escaped backslash and the statement really does end here.
             _bs="${_last##*[!\\]}"
             [ $(( ${#_bs} % 2 )) -eq 1 ] && continue ;;
    esac
    if bash -n <<< "$acc" 2>/dev/null; then
      printf '%s\0' "${acc%$'\n'}"
      acc=""
    fi
  done <<< "$1"
  # An unterminated remainder is a DOC BUG (an unclosed quote or heredoc). Emit it so it runs and
  # fails loudly, rather than silently dropping the tail of a block.
  case "$(printf '%s' "$acc" | tr -d '[:space:]')" in '') : ;; *) printf '%s\0' "${acc%$'\n'}" ;; esac
}

# (3) FENCE-AWARE, not regex. A ```bash nested inside another fenced block -- an illustrative
# snippet, a doc-about-docs example, a command the reader must NOT run -- was extracted and
# scheduled for execution. Tracking fence state also makes ```sh / ```bash-with-attributes an
# explicit decision rather than a silent zero.
# ── walk-include: the document may DELEGATE a step to a SHARED file ──────────────────────────────
# `<!-- walk-include: common-steps.md -->` splices that file in AT THIS POINT, so the walker executes
# what the reader reads. WITHOUT it, a scenario that LINKS to a shared document walks only its own
# blocks and every counter still reconciles -- MEASURED: a 2-block doc linking a 2-block+1-claim file
# walked 2 blocks, printed "2 extracted, 2 counted independently", 0 claims, EXIT 0.
#
# The marker is an HTML comment: invisible in rendered markdown, accepted by markdownlint (rc=0), and
# invisible to the OLD parser -- which is exactly why adding it WITHOUT teaching the parser is the
# fake-green. Both measured 2026-08-16.
#
# ⚠️ THE INCLUDE SET IS RESOLVED TWICE, ON PURPOSE, AND THE FLOORS COUNT THE *SOURCES*.
# The obvious implementation -- have Python write the expansion and grep THAT -- DESTROYS the only
# real floor in this script. MEASURED: on an extractor death it yields EXPECT_LINES_PARSED=0 AND
# INDEP_E=0, so `0 >= 0` PASSES, where counting the SOURCES gives `0 >= 26` and REFUSES. A floor
# computed from the parser's own output cannot detect the parser being wrong -- that is the whole
# point of the floor. So bash resolves the list itself, below, and cross-checks it against the set
# Python actually used.
DOC_DIR="$(cd "$(dirname "$DOC")" && pwd)"
DOC_SET=("$DOC")
_incs="$(sed -nE 's|^[[:space:]]*<!--[[:space:]]*walk-include:[[:space:]]*([^[:space:]]+)[[:space:]]*-->[[:space:]]*$|\1|p' "$DOC" || true)"
while IFS= read -r _i; do
  # An empty $() in a herestring STILL yields one empty line -- without this the loop body runs once
  # on nothing and inflates the set.
  [ -n "$_i" ] || continue
  _p="${DOC_DIR}/${_i}"
  [ -f "$_p" ] || { echo "REFUSING: walk-include names a file that does not exist: ${_i} (from $(basename "$DOC"))"; exit 1; }
  for _seen in "${DOC_SET[@]}"; do
    [ "$_seen" = "$_p" ] && { echo "REFUSING: walk-include repeats ${_i} — a walk must not execute a step twice"; exit 1; }
  done
  DOC_SET+=("$_p")
done <<< "$_incs"

# A CLOSING </details> MUST BE ALONE ON ITS LINE — see the block comment above the parser's
# details handling. `.</details>` and `</details> more` are both rejected; the fix is one newline.
_bad_close="$(grep -hnE '(.\S|\S.)</details>|</details>[[:space:]]*\S' "${DOC_SET[@]}" || true)"
[ -z "$_bad_close" ] || {
  echo "REFUSING: a closing </details> is not alone on its line. The parser only resets its"
  echo "  'inside a <details>' state on a line that STARTS with </details>, so everything after"
  echo "  this point would be silently SKIPPED while every counter still reconciles and rc=0:"
  printf '%s\n' "$_bad_close" | sed 's/^/    /'
  echo "  Put </details> on a line of its own."
  exit 1
}

mapfile -t PARSED < <(python3 - "$DOC" <<'PY'
import json, os, re, sys
heading, fence, body, out = "(preamble)", None, [], []
# <details> is the document's way of saying "this is an ALTERNATIVE, expand it only if the summary
# describes you". A reader does not run a collapsed block; the walker used to run every one of them.
# MEASURED: it executed the block under "No Supervisor access (the Scenario-2 tenant)? Ask the vcf
# CLI instead", which failed with exactly the `pinniped-info` error the document PREDICTS two lines
# later, and told the reader to use the other route -- which had already worked.
# (That block was REMOVED from scenario-1.md on 2026-08-13 -- Scenario-1 is admin-only -- so a grep
# for its summary now finds nothing. The rule is GENERIC and unaffected: it skips ANY collapsed
# <details>. Kept as the incident that motivated it.)
details = None
# The document also instructs through TABLES ("set in ./.env:"), not only through commands. Those
# rows are instructions: Step 6's table says to change VKS_AUTH_METHOD back to `kubeconfig`, and a
# walk that ignores it keeps talking to the SUPERVISOR for every step after.
env_rows, pending, pending_manual = [], [], []

# Splice each `<!-- walk-include: <path> -->` in at its own position, so the walk's ORDER is the
# READER's order by construction rather than by assertion. DEPTH 1 ONLY: a marker inside an included
# file REFUSES rather than recursing, which keeps "what runs, and when" answerable by reading two
# files. The resolved set is echoed back as __INCLUDE__ rows so bash can prove it resolved the SAME
# set -- two independent resolutions that must agree.
INC = re.compile(r'^\s*<!--\s*walk-include:\s*(\S+?)\s*-->\s*$')
SRC, used = [], []
_base = os.path.dirname(os.path.abspath(sys.argv[1]))
for _ln in open(sys.argv[1]):
    _m = INC.match(_ln)
    if not _m:
        SRC.append(_ln); continue
    _p = os.path.normpath(os.path.join(_base, _m.group(1)))
    if not os.path.isfile(_p):
        sys.exit("walk-include UNRESOLVABLE: %s -> %s" % (_m.group(1), _p))
    if _p in used:
        sys.exit("walk-include REPEATS: %s" % _m.group(1))
    used.append(_p)
    for _sub in open(_p):
        if INC.match(_sub):
            sys.exit("walk-include NESTED inside %s — depth 1 only" % _m.group(1))
        SRC.append(_sub)
for _u in used:
    print(json.dumps({"__INCLUDE__": _u}))

for line in SRC:
    # CommonMark: a fence is >=3 backticks and closes on a run of AT LEAST that many with no
    # info string. Assuming exactly 3 mis-parses the ````markdown wrapper people use to SHOW a
    # ```bash block -- and the inner one then gets extracted and EXECUTED.
    m = re.match(r'^(\s*)(`{3,})(\S*)', line)
    if fence is None:
        if line.lstrip().startswith('<details'):
            details = line.split('<summary>')[-1].split('</summary>')[0].strip() or 'an alternative'
        elif line.lstrip().startswith('</details>'):
            details = None
        # A `| \`KEY\` | example | ... |` row under a "set in ./.env" heading is an instruction.
        elif details is None and re.match(r'^\s*\|\s*`[A-Z][A-Z0-9_]*`\s*\|', line):
            # `details is None`: a table inside <details> is an ALTERNATIVE, exactly like a code
            # block inside one -- the walker already refuses to RUN those. Honouring it for blocks
            # and ignoring it for rows applied 7 rows from sections headed "Optional -- skip unless
            # you want to change it", including one whose value is the words "(unset -- probes skip)".
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            k = cells[0].strip('`')
            v = cells[1].strip('`').strip() if len(cells) > 1 else ''
            # A row is an INSTRUCTION only if its value is a literal safe in BOTH parsers that read
            # .env -- `make -include` AND a shell `source`. There is no quoting that satisfies both
            # (measured: `U=robot$vks-cicd` -> make `robotks-cicd`, bash `robot-cicd`; single quotes
            # fix bash and make keeps them literally), so an unsafe value CANNOT be written at all.
            # MEASURED on this document, where a shell syntax error ABORTS the rest of the file:
            #   VCF_CLI_VSPHERE_PASSWORD=*your value*       -> `value*: command not found`, Error 127
            #   VKS_CLUSTER_COMPUTE=*(leave unset)*         -> syntax error; 20 LATER KEYS never assigned
            #   VKS_VM_CLASSES=a b   (a LEGITIMATE value)   -> the space ends the assignment
            #   HARBOR_USERNAME=robot$vks-cicd (LEGITIMATE) -> $vks expands to '' -> robot-cicd, SILENTLY
            # So italics are only half of it: two of those are real values the document means. This
            # is the same principle the walker already applies to an unsubstituted <placeholder> --
            # a walk must not invent a value.
            if v and re.fullmatch(r'[A-Za-z0-9_./:@=+-]+', v):
                pending.append([k, v])
            elif v:
                pending_manual.append([k, v])
        if m: fence = (m.group(3).split(':')[0].lower(), len(m.group(2))); body = []
        elif line.startswith('## '): heading = line[3:].strip()
        # The document's CONTRACT WITH THE READER. `**Expect:** ...` states what they will SEE, and
        # nothing has ever checked it -- a walk that reports rc=0 for every block proves the COMMANDS
        # ran, not that the DOCUMENT is truthful. Attach it to the block it follows.
        elif line.startswith('**Expect') and out: out[-1]["e"].append(line.rstrip())
    elif m and not m.group(3) and len(m.group(2)) >= fence[1]:
        if fence[0] in ('bash', 'sh', 'shell'):
            out.append({"h": heading, "b": "".join(body), "e": [],
                        "details": details or "", "env": pending,
                        "envmanual": pending_manual}); pending, pending_manual = [], []
        fence = None
    else:
        body.append(line)
if fence is not None: sys.exit("UNCLOSED fence in the document")
for o in out: print(json.dumps(o))
# LAST, deliberately — the same discipline PYX already uses, which this extractor never had.
# `mapfile`'s exit status is ITS OWN, never the substituted process's, so the `||` below is DEAD
# CODE and always has been. MEASURED both ways: a sys.exit() before any output yields len=0 and
# "NOT-CAUGHT", and a sys.exit() after one row yields a TRUNCATED parse that reads as SUCCESS.
# A terminal sentinel is the only thing that can distinguish "finished" from "died partway".
print(json.dumps({"__EXTRACTOR_OK__": True}))
PY
) || { echo "EXTRACTOR FAILED — refusing to report a walk"; exit 1; }

# The sentinel must be the LAST row, or the extractor died mid-stream and everything above it is a
# partial document. This is the check the `||` above only appeared to perform.
if [ "${#PARSED[@]}" -eq 0 ] || [ "${PARSED[-1]}" != '{"__EXTRACTOR_OK__": true}' ]; then
  echo "REFUSING: the extractor did not run to completion — a walk must not report on a partial parse"
  exit 1
fi
unset 'PARSED[-1]'

# Pull the resolved include set back out and prove BOTH resolutions agree. Two independent
# resolutions that must match: if they ever diverge, one of them is wrong and neither can be trusted
# to have counted the right files.
_pyincs=()
for _row in "${PARSED[@]}"; do
  case "$_row" in '{"__INCLUDE__":'*) _pyincs+=("$(printf '%s' "$_row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["__INCLUDE__"])')") ;; esac
done
PARSED=("${PARSED[@]/#\{\"__INCLUDE__\":*/}")
mapfile -t PARSED < <(printf '%s\n' "${PARSED[@]}" | grep -v '^$' || true)
if [ "${#_pyincs[@]}" -ne "$(( ${#DOC_SET[@]} - 1 ))" ]; then
  echo "REFUSING: the parser resolved ${#_pyincs[@]} walk-include(s) but this script resolved $(( ${#DOC_SET[@]} - 1 )) — the two resolutions disagree"
  exit 1
fi

# (2) A zero-block extraction reported "0 blocks: 0 ran, 0 failed" and EXIT 0. Three reachable
# paths measured: a fence attribute, ```sh, and one invalid UTF-8 byte. That state HAS occurred here
# (a greedy `.` under re.S).
#
# INDEP IS NOW A FLOOR, NOT A DECORATION. It used to be printed-only, on the stated grounds that it
# "cannot equal ${#PARSED[@]} because that counts ```sh and ```shell too". MEASURED: both documents
# contain ZERO ```sh and ZERO ```shell fences, so once this grep is widened to the same three
# languages the parser accepts, INDEP == ${#PARSED[@]} exactly (39/39 and 14/14). The obstacle was
# real in principle and absent in fact.
#
# BLOCKQUOTE-TOLERANT (`>` allowed before the fence) on purpose, and that is the half that earns its
# keep: the parser only sees a fence at the start of a line, so a `> ```bash ` block is invisible to
# it — and a hand-typed constant can NEVER catch that, because the human types the number to match
# whatever the parser happened to see. A derived floor catches it as an arithmetic contradiction.
#
# `cat` and not `grep -c "${DOC_SET[@]}"`: with MORE THAN ONE file grep prints `file:count` per
# file, so the multi-file form yields text where a total is wanted.
INDEP="$(cat "${DOC_SET[@]}" | grep -cE '^[[:space:]]*>?[[:space:]]*```(bash|sh|shell)' || true)"
# Claims, counted independently of the parser -- same discipline, different unit. INDENT-TOLERANT
# on purpose: the parser only sees `**Expect` at COLUMN 0, so a column-0-only grep would share its
# blindness and an indented claim would be invisible to both. A blockquoted `> **Expect:` still is.
# Counted over the SOURCE files -- $DOC plus each included file -- and NEVER over the parser's own
# expansion. That distinction is the whole floor: an expansion-side count makes an extractor death
# read `0 >= 0` PASS, while a source-side count makes the same death read `0 >= 26` and REFUSE.
INDEP_E="$(cat "${DOC_SET[@]}" | grep -cE '^[[:space:]]*\*\*Expect' || true)"
printf '\n======== walking %s ========\n' "$(basename "$DOC")"
printf 'blocks: %d extracted, %d counted independently | os=%s\n' "${#PARSED[@]}" "$INDEP" "${WALK_OS:-?}"
# Print the RESOLVED per-resource row, not the WALK_EXISTS shorthand -- the whole point is that they
# can differ, and a reader of the log must be able to see which cell of the matrix this run was.
printf 'row: ns=%s harbor=%s argocd=%s cluster=%s robot=%s clone-skipped=%s istio=%s\n' \
  "$WALK_NS_EXISTS" "$WALK_HARBOR_EXISTS" "$WALK_ARGOCD_EXISTS" "$WALK_CLUSTER_EXISTS" \
  "$WALK_ROBOT_EXISTS" "${WALK_SKIP_CLONE:-0}" "${WALK_ISTIO:-existing}"
# Disclosed, because it is a real trade: carrying the environment means a block that forgot to
# source ./.env is rescued by the previous one -- exactly as it would be for a reader in one terminal.
printf 'shell: ONE INTERACTIVE bash per STATEMENT, ENV AND CWD CARRIED FORWARD (a reader has one terminal,\n        and runs one command at a time -- each result is printed under the command that produced it)\n'
# THE FLOOR, DERIVED — per-document by construction, and nothing to keep in sync. A hand-typed
# constant is a number someone maintains to match the parser, so it can only ever detect the parser
# getting WORSE than the day the number was written; it cannot detect a block the parser never saw.
#
# TWO conditions, because the derived one alone has a hole the constant did not: a document with NO
# fences at all yields `0 >= 0` and PASSES. "Nothing failed" must never equal "nothing happened", so
# a walk that walks nothing is refused outright. (Found by the constant-era test failing against the
# derived floor — the test was right and the first version of this change was wrong.)
[ "${#PARSED[@]}" -gt 0 ] || {
  echo "REFUSING: the parser extracted ZERO command blocks from ${DOC} — there is nothing to walk,"
  echo "  and a walk that runs nothing must not report a clean result."
  exit 1
}
[ "${#PARSED[@]}" -ge "$INDEP" ] || {
  echo "REFUSING: the document has ${INDEP} fenced command block(s) but the parser extracted only ${#PARSED[@]}."
  echo "  A block is present in the source and invisible to the parser. The usual cause is a"
  echo "  BLOCKQUOTED fence (\`> \`\`\`bash\`) — the parser only sees a fence at the start of a line, so the"
  echo "  block is silently dropped while every other counter reconciles. Unindent it, or move the"
  echo "  commands out of the blockquote."
  exit 1
}

for row in "${PARSED[@]}"; do
  H="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["h"])')"
  B="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["b"])')"
  E="$(printf '%s' "$row" | python3 -c 'import sys,json;print("\n".join(json.load(sys.stdin).get("e",[])))')"
  DET="$(printf '%s' "$row" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("details",""))')"
  ENVROWS="$(printf '%s' "$row" | python3 -c 'import sys,json;[print(k+"="+v) for k,v in json.load(sys.stdin).get("env",[])]')"
  ENVMANUAL="$(printf '%s' "$row" | python3 -c 'import sys,json;[print(k+"="+v) for k,v in json.load(sys.stdin).get("envmanual",[])]')"
  # COUNT THE CLAIMS THE PARSER ATTACHED -- here, UNCONDITIONALLY, above should_skip and above the
  # WALK_DRY gate. 7 of the document's 26 Expect lines sit on blocks a row legitimately SKIPS (two in
  # EVERY cell: the teardown block and one carrying a live <EXTERNAL-IP> placeholder), so counting
  # after the skip yields 24 in one row and 20 in another -- a floor at the document's real 26 would
  # then REFUSE a healthy walk on day one, which is the false-RED shape this file keeps re-learning.
  EXPECT_LINES_PARSED=$(( EXPECT_LINES_PARSED + $(printf '%s' "$E" | grep -c . || true) ))
  STEP=$((STEP + 1))
  # THE DOCUMENT INSTRUCTS THROUGH TABLES TOO. "set in ./.env:" rows are instructions, not
  # decoration: Step 6's table says to change VKS_AUTH_METHOD back to `kubeconfig`, and a walk that
  # ignores it keeps every later guest-cluster check pointed at the SUPERVISOR -- where they fail
  # with true-but-irrelevant errors ("may NOT create CustomResourceDefinitions") that name neither
  # the variable nor the cluster. MEASURED: that one missed cell cost Steps 7-13 of row 1.
  #
  # A value the HARNESS supplied wins (it is lab-specific and the doc's example is illustrative),
  # but the divergence is PRINTED rather than swallowed -- silently overriding the document is how
  # a walk stops being a walk.
  if [ -n "${ENVROWS:-}" ]; then
    while IFS='=' read -r _k _v; do
      [ -n "${_k:-}" ] || continue
      # WHOSE value is already there decides everything, and "is it set right now" cannot tell you:
      # by Step 6 the walker has itself exported what Step 5's table said. MEASURED -- Step 5 sets
      # VKS_AUTH_METHOD=vcf, so Step 6's `kubeconfig` (the cell this whole feature exists for, and
      # the one that cost row 1 its Steps 7-13) was REJECTED as "the harness supplied vcf", a false
      # attribution that sends the reader to debug the harness. So compare against the PRE-WALK
      # snapshot: the harness outranks the document, a later row outranks an earlier row.
      if grep -qxF "$_k" "$PREENV_FILE" 2>/dev/null; then
        _cur="$(eval "printf '%s' \"\${$_k:-}\"")"
        [ "$_cur" != "$_v" ] && \
          printf '    (doc says %s=%s; the harness supplied %s before the walk — keeping it)\n' "$_k" "$_v" "$_cur"
        continue
      fi
      printf '    (doc: setting %s=%s in ./.env)\n' "$_k" "$_v"
      export "$_k=$_v"
      # ...and into the CARRIED state, or the export is invisible to the very commands it is for.
      # Statements run in a child that FIRST sources the previous statement's variable dump, so that
      # dump outranks anything the parent exported afterwards. MEASURED: Step 5's table set
      # VKS_AUTH_METHOD=vcf, Step 6's set kubeconfig, ./.env correctly ended up `kubeconfig` -- and
      # the next command still SAW `vcf`. Checking the file instead of what a command sees is the
      # proxy-not-result trap; appending here makes the new value win when the child sources it.
      printf 'declare -x %s=%q\n' "$_k" "$_v" >> "$ENV_FILE"
      if [ -f "${CWD}/.env" ]; then
        sed -i "/^${_k}=/d" "${CWD}/.env"; printf '%s=%s\n' "$_k" "$_v" >> "${CWD}/.env"
      else
        printf '    (WARNING: no %s/.env yet — exported for this walk, NOT persisted)\n' "$CWD"
      fi
    done <<< "$ENVROWS"
  fi
  # Rows the document states but a walk must NOT invent (a placeholder, or a value no dual-parser
  # .env can hold). Printing them is the honest half: the reader is told to set them by hand.
  if [ -n "${ENVMANUAL:-}" ]; then
    while IFS='=' read -r _k _v; do
      [ -n "${_k:-}" ] || continue
      printf '    (doc asks you to set %s=%s BY HAND — not a literal a walk can write)\n' "$_k" "$_v"
    done <<< "$ENVMANUAL"
  fi
  reason="$(should_skip "$B")"
  # A COLLAPSED <details> IS AN ALTERNATIVE, not a step. Its summary says who it is for; a reader
  # expands it only if that is them. MEASURED: the walker ran "No Supervisor access (the Scenario-2
  # tenant)? Ask the vcf CLI instead" during a Scenario-1 walk, it failed with the exact
  # `pinniped-info` error the document predicts two lines later, and the route the document actually
  # prescribes had already succeeded.
  [ -z "$reason" ] && [ -n "${DET:-}" ] && reason="inside a <details> alternative: ${DET}"
  : > "$UNSAFE_FILE"
  RAWB="$B"                           # pre-substitution, so statements are split on the DOCUMENT's text
  # The RESULT is unused now (each statement renders its own safe text), but the CALL is not: it is
  # what arms the UNSAFE_FILE guard below on the pre-substitution text. Deliberately WITHOUT `log`,
  # or every neutralized line would be counted twice -- once here and once per statement.
  neutralize "$B" >/dev/null
  B="$(neutralize "$(substitute "$B")")"   # what actually RUNS -- may carry a real credential
  [ -s "$UNSAFE_FILE" ] && [ -z "$reason" ] \
    && reason='a TTY-bound command sits inside a \-continued command - neutralizing one line would delete an argument from the survivor'
  # $B, not $SHOWN: the guard asks whether a placeholder SURVIVED substitution.
  if [ -z "$reason" ] && has_live_placeholder "$B"; then
    reason='unsubstituted <placeholder> in a COMMAND - a walk must not invent a value'
  fi
  if [ -n "$reason" ]; then
    printf '\n--- [%02d] %s  SKIPPED: %s\n' "$STEP" "$H" "$reason"
    SKIPPED=$((SKIPPED + 1)); printf '  skipped: [%02d] %s - %s\n' "$STEP" "$H" "$reason" >> "$SKIP_LOG"
    continue
  fi
  printf '\n=== [%02d] %s\n' "$STEP" "$H"
  t0=$SECONDS
  if [ "${WALK_DRY:-0}" = 1 ]; then printf '    (dry run - not executed)\n'; rc=0
  else
    # The document attaches `Expect:` to a STEP, and a step often has several blocks. Checking a
    # claim against only the block it follows produced a FALSE UNMET on
    # `7 secrets generated, 0 placeholders left` -- text plainly present in the log. A reader reads
    # the whole step, so a claim is checked against the whole step.
    #
    # THE MOTIVATING EXAMPLE IS HISTORICAL: step 4's claim was moved to sit directly after the block
    # that produces it, so step 4 no longer needs step-scoping. KEEP THE MECHANISM ANYWAY -- two live
    # instances still depend on it (`PREFLIGHT OK`, whose claim is produced by the PRECEDING block and
    # not by the one it follows; and the CA step's `0644`), and any new document will grow more.
    [ "$H" = "${LAST_H:-}" ] || { : > "$STEP_OUT_FILE"; LAST_H="$H"; }
    : > "$OUT_FILE"
    rc=0
    # ONE STATEMENT AT A TIME, each with its own output and its own rc printed underneath it --
    # because that is what the reader sees. Running the block as one `bash -c` produced ONE exit
    # code for four commands: a reader who runs them individually, reading each result before
    # typing the next, was never what got tested.
    #
    # `done < <(...)` and NOT a pipe: the loop body must run in THIS shell so the cwd it learns
    # carries to the next statement, exactly as it would in the reader's one terminal.
    while IFS= read -r -d '' _raw; do
      _show="$(neutralize "$_raw" log)"
      _run="$(neutralize "$(substitute "$_raw")")"
      printf '%s\n' "${_show%$'\n'}" | sed 's/^/    $ /'
      : > "$CWD_FILE"; : > "$RC_FILE"
      # (1) `bash -c` exits with its LAST command's status and the marker printf ALWAYS succeeds --
      # so capture the statement's own status FIRST, then emit the markers, then exit with it.
      # (11) the leading newline is load-bearing: a statement ending in `\` would swallow `__rc=$?`.
      # (9) the cwd goes in as an ARGUMENT, never interpolated -- a balanced quote pair in a path
      # was a proven injection.
      #   -i  : ~/.bashrc's `case $- in *i*` guard passes, so `make shell-init`'s PATH survives.
      #   env : `export -p` at the end, sourced at the start of the next -- ONE terminal.
      bash -i -c '. "$2" 2>/dev/null; cd "$1" || exit 1
'"$_run"'
__rc=$?
# ALL variables, not just exported ones. `export -p` carries only the exported set, so a plain
# `V=present` on one line was GONE by the next -- measured: `echo "$V"` printed empty where a
# reader in one terminal would see the value. That is the one-terminal property, and executing
# statement-by-statement is exactly what put it at risk.
# The readonly/special names are filtered: re-assigning UID, BASHOPTS, PIPESTATUS et al. errors
# on the way back in, and one error there would poison every later statement.
{ declare -p 2>/dev/null | grep -vE "^declare -[a-zA-Z]*r" \
    | grep -vE "^declare -[a-zA-Z-]+ (BASH|BASHOPTS|BASHPID|BASH_[A-Z]+|COMP_[A-Z]+|DIRSTACK|EPOCH[A-Z]*|EUID|FUNCNAME|GROUPS|HISTCMD|LINENO|OPTARG|OPTIND|PIPESTATUS|PPID|RANDOM|SECONDS|SHELLOPTS|SRANDOM|UID|_)="
  declare -f 2>/dev/null
} > "$2" 2>/dev/null
printf "\n__WALK_RC__%s\n__WALK_CWD__%s\n" "$__rc" "$PWD"
exit $__rc' _ "$CWD" "$ENV_FILE" 2>&1 \
        | grep -vE '^bash: (cannot set terminal process group|no job control)' \
        | while IFS= read -r l; do
          case "$l" in
            __WALK_RC__*)  printf '%s' "${l#__WALK_RC__}"  > "$RC_FILE" ;;
            __WALK_CWD__*) printf '%s' "${l#__WALK_CWD__}" > "$CWD_FILE" ;;
            *) printf '    %s\n' "$l"; printf '%s\n' "$l" >> "$OUT_FILE"; printf '%s\n' "$l" >> "$STEP_OUT_FILE" ;;
          esac
        done
      _src=${PIPESTATUS[0]}
      _mrc="$(cat "$RC_FILE" 2>/dev/null || true)"
      [ -n "$_mrc" ] && _src="$_mrc"       # the marker is authoritative when the statement finished
      _nc="$(cat "$CWD_FILE" 2>/dev/null || true)"
      if [ -n "$_nc" ] && [ "$_nc" != "$CWD" ]; then printf '    (cwd -> %s)\n' "$_nc"; CWD="$_nc"; fi
      # The per-statement result, printed where the reader would see it -- not folded into a block.
      printf '      -> rc=%d\n' "$_src"
      [ "$_src" -ne 0 ] && rc=1
    done < <(split_statements "$RAWB")
  fi
  RAN=$((RAN + 1)); [ "$rc" -ne 0 ] && FAILED=$((FAILED + 1))
  if [ -n "$E" ] && [ "${WALK_DRY:-0}" != 1 ]; then
    _seen=0; _tot=0; _missed=""
    _pyx_ok=0
    while IFS=$'\t' read -r verdict lit; do
      case "$verdict" in __PYX_OK__) _pyx_ok=1; continue ;; esac
      [ -n "${lit:-}" ] || continue
      printf '    expect: %-56s %s\n' "$lit" "$verdict"
      _tot=$((_tot + 1))
      if [ "$verdict" = "SEEN" ]; then _seen=$((_seen + 1)); else _missed="${_missed}
      - ${lit}"; fi
    done < <(EXPECT_TEXT="$E" BLOCK_TEXT="$B" python3 - "$STEP_OUT_FILE" <<'PYX'
import os, re, sys
out  = open(sys.argv[1], errors='replace').read()
blk  = os.environ.get('BLOCK_TEXT', '')
for line in os.environ.get('EXPECT_TEXT', '').splitlines():
    for lit in re.findall(r'`([^`]+)`', line):
        lit = lit.strip()
        # A literal carrying a placeholder or an ellipsis cannot be matched verbatim -- the document
        # is telling the reader the SHAPE, not the text.
        if len(lit) < 6 or re.search(r'[<>]|\.\.\.|…', lit):      continue
        # Skip the literals that name the COMMAND the reader just ran: they appear in the block
        # itself, so finding them in the output proves nothing about the claim.
        if lit in blk:                                            continue
        # A COMMAND NAMED IN PROSE IS NOT AN OUTPUT CLAIM. `**Expect:** re-running `make
        # argocd-preflight` now says `PREFLIGHT OK`` names a thing to RUN; the existing `lit in blk`
        # filter drops command literals only when they are in THIS block. One SHAPE, not a list of
        # strings -- a list would rot on the first new command.
        if re.fullmatch(r'make [a-z][a-z0-9-]*', lit):            continue
        print(("SEEN" if lit in out else "NOT SEEN") + "\t" + lit)
# LAST, deliberately. Printed first it would already be consumed when the producer dies mid-loop,
# certifying a TRUNCATED extraction; measured -- a SystemExit after one row still set the flag.
# It runs in a process substitution and this script has no `set -e`, so a broken extractor otherwise
# yields _tot=0 and the walk reports "0 UNMET" having checked nothing.
print("__PYX_OK__")
PYX
    )
    # THE UNIT IS THE BLOCK. A single literal missing is prose noise (the doc hedges, abbreviates,
    # and mixes the command with the output). A block whose claims produced NOTHING is the document
    # telling the reader they will see something they do not -- which is the whole question this
    # walk exists to answer, and which an rc-only report is structurally blind to.
    # A BROKEN EXTRACTOR MUST NOT READ AS "NO CLAIMS". It runs in a process substitution and this
    # script has no `set -e`, so a SystemExit or a syntax error inside PYX yields _tot=0 silently --
    # and the walk then reports "0 UNMET" having checked nothing. Measured both ways.
    [ "$_pyx_ok" = 1 ] || { echo "REFUSING: the Expect extractor did not complete for block [$STEP] — a walk must not report 0 claims because its own parser died"; exit 1; }
    if [ "$_tot" -gt 0 ]; then
      EXPECT_TOTAL=$((EXPECT_TOTAL + 1))
      if [ "$_seen" -eq 0 ]; then
        EXPECT_MISS=$((EXPECT_MISS + 1))
        printf '    EXPECT UNMET: the document promises output this block did not produce\n'
        printf '  expect-unmet: [%02d] %s%s\n' "$STEP" "$H" "$_missed" >> "$EXPECT_LOG"
      elif [ -n "$_missed" ]; then
        # MASKED, and previously discarded. A block passes when ANY literal matches, so a claim that
        # was NOT seen vanished whenever a sibling on the same line matched. Measured over two real
        # rows: 2 and 3 such literals, every one invisible in the report.
        # PRINTED, NOT RATCHETED -- deliberately. The count varies by CELL, not by document quality:
        # `PSA UNPROVEN` is correctly absent on a row whose cluster is not bare (the document says so
        # in the same sentence), so a ratchet would RED a healthy row and would be measuring which
        # cell ran. Some of these are also permanently unmatchable (a claim that a FILE now exists
        # can never appear in stdout). A number nobody can act on is not a gate.
        EXPECT_UNSEEN=$((EXPECT_UNSEEN + 1))
        printf '  unseen-literal: [%02d] %s%s\n' "$STEP" "$H" "$_missed" >> "$EXPECT_LOG"
      fi
    fi
  fi
  printf -- '--- [%02d] rc=%d (%ds)\n' "$STEP" "$rc" "$((SECONDS - t0))"
done

printf '\n======== WALK DONE - %d blocks: %d ran, %d FAILED, %d skipped, %d line(s) neutralized ========\n' \
  "$STEP" "$RAN" "$FAILED" "$SKIPPED" "$(wc -l < "$NEUT_LOG")"
# TWO different questions, never one number: did the COMMANDS work, and is the DOCUMENT truthful?
# A walk that reports only the first is the failure this line exists to make impossible.
# THE DENOMINATOR, not just the numerator. The previous line printed only EXPECT_TOTAL -- blocks
# with at least one CHECKABLE literal -- and read as "the document makes 13 claims" when it makes 26.
# Half its claims are unverifiable here (a placeholder, an ellipsis, a literal that is also in the
# command, a short token), and a coverage number without its exclusions is a claim, not a measurement.
printf '======== DOCUMENT - %d Expect: lines in the doc, %d parsed, %d blocks CHECKABLE, %d UNMET, %d block(s) with a MASKED literal ========\n' \
  "$INDEP_E" "$EXPECT_LINES_PARSED" "$EXPECT_TOTAL" "$EXPECT_MISS" "$EXPECT_UNSEEN"
# THE FLOOR, reconciled against a count the parser did not produce -- the same discipline the block
# count already uses, because a denominator only the parser can compute cannot detect the parser
# being wrong. It catches an `**Expect:**` that appears BEFORE the first block (the parser requires
# a preceding block and drops it silently). It does NOT catch a blockquoted `> **Expect:` -- neither
# pattern matches that -- so this is a floor on ONE of the three ways a claim can go missing, and
# saying which one is the point.
[ "$EXPECT_LINES_PARSED" -ge "$INDEP_E" ] || {
  echo "REFUSING: the document has ${INDEP_E} Expect: line(s) but the parser attached only ${EXPECT_LINES_PARSED} — a claim was dropped before it could be checked"
  exit 1
}

# A NEGATED LITERAL ON AN `**Expect:**` LINE IS A FALSE GREEN, AND THE CHECKER CANNOT SEE IT.
# The check asks only "is this literal in the output?" and a block PASSES on ANY literal matching
# (`_seen -eq 0` is the only UNMET condition). So `**Expect:** ... `api` (not `request`)` scores a
# PASS on the very output it is warning about, because `request` IS in that output. MEASURED against
# the real extractor: feeding it `write mechanism: request  (kubectl=no, argocd-api=no)` -- the
# documented FAILURE, where the Application is rendered to ./out/ and NOTHING is deployed -- gave
# `NOT SEEN api` + `SEEN request` -> seen=1 -> PASS.
#
# Polarity is undetectable at check time, so it is refused at parse time instead. The pattern is
# TIGHT on purpose: `not` immediately qualifying a backticked literal. Measured over both documents'
# 31 Expect lines it matched 1 (the real defect) and nothing else, while a loose "`not` anywhere on
# the line" would have matched 5 -- four of them legitimate prose.
# shellcheck disable=SC2016  # the backticks are MARKDOWN code-span delimiters we are searching FOR,
                            # not command substitution — single quotes are exactly right here.
_negated="$(grep -hnE '^[[:space:]]*\*\*Expect' "${DOC_SET[@]}" \
            | grep -oE 'not[[:space:]]+`[^`]{6,}`' || true)"
[ -z "$_negated" ] || {
  echo "REFUSING: an **Expect:** line negates a checkable literal — the checker has no concept of"
  echo "  negation, so that literal MATCHES the failure output and scores the block a PASS:"
  printf '%s\n' "$_negated" | sed 's/^/    /'
  echo "  Put the positive claim on the **Expect:** line; move the 'if it says X instead' sentence"
  echo "  to a following line and do NOT backtick its literal."
  exit 1
}
cat "$EXPECT_LOG"
# A coverage number without its exclusions is a claim, not a measurement.
cat "$SKIP_LOG" "$NEUT_LOG"
# (2) "nothing failed" and "nothing happened" must not share an exit code.
[ "$RAN" -gt 0 ] || { echo "REFUSING: the walk executed NOTHING"; exit 1; }
# An UNMET claim fails the walk. WALK_EXPECT_ADVISORY=1 downgrades it -- use it only with a written
# reason, because "the document says something untrue" is exactly what a doc walk is for.
if [ "$EXPECT_MISS" -gt 0 ] && [ "${WALK_EXPECT_ADVISORY:-0}" != 1 ]; then
  exit 1
fi
exit $(( FAILED > 0 ? 1 : 0 ))
