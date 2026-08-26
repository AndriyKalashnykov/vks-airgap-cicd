#!/usr/bin/env bash
# check-notfound-discriminator.sh — no script may decide "absent" from a bare "not found" substring.
#
# WHY (measured, 2026-08-25, real kubectl 1.36.4):
#
#   $ kubectl get crd virtualservices.networking.istio.io          # dangling current-context
#   Error in configuration: context was not found for specified context: ghost
#
# That is a CLIENT-SIDE kubeconfig fault and says nothing about the resource — but it contains
# the phrase, so every site that grepped for it classified the resource ABSENT. A second
# instance is any endpoint answering HTTP 404 ("the server could not find the requested
# resource"). Five sites had it, and "absent" is not cosmetic at any of them:
#
#   48-istio-preflight     -> emits the string walk-doc.sh greps to choose the INSTALL branch,
#                             so a tenant with a stale kubeconfig was steered into helm-installing
#                             a SECOND mesh over the platform team's
#   43-install-istio-package -> skips the air-gap check and installs from Broadcom, reporting success
#   08-install-argocd-service -> waits out the full timeout instead of naming the real fault
#   98-uninstall-all       -> reports a resource cleaned up that it never managed to read
#   23 / 26                -> report a namespace / cluster absent that they could not see
#
# THE ONLY TWO ACCEPTED FORMS:
#   kube_is_notfound <errfile> <token>          (lib/os.sh — server prefix AND the resource token)
#   *"Error from server (NotFound)"*            (a shell case on a STRING, same anchor)
#
# SELF-MATCH: this gate lives in the tree it scans, so the pattern it hunts is COMPOSED at
# runtime and never appears as a literal here. Its own selftest asserts this file contributes
# zero hits — do NOT "fix" a future finding by excluding this file, which would blind the gate
# to the one file most likely to grow one.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

# Composed, so this file is invisible to its own scan.
#
# ⚠️ The pattern must match the SOURCE TEXT, which is itself usually a regex. The first draft
# used `not ?found` as the pattern -- which matches "not found"/"notfound" but NOT the literal
# `not ?found` a script actually contains, so it could never have flagged the two sites it was
# written for. It was VACUOUS and its RED-proof is what exposed that.
# `[[:space:]?_]*` spans the separator in every real spelling: NotFound, not found, notfound,
# not_found, and the regex source `not ?found`.
_nf="$(printf '[Nn]ot[[:space:]?_]*[Ff]%sund' 'o')"
_NF="$(printf 'Not%s' 'Found')"            # -> NotFound

scanned=0; bad=0
while IFS= read -r f; do
  scanned=$((scanned + 1))
  # grep -n on the FILE, so reported line numbers are real; comment lines are dropped after.
  # A DECISION keyed on the phrase, applied to an ERROR BUFFER — that is what separates
  # "classify a cluster read" from "assert on a message", which is all the test-*.sh do.
  # TWO passes, because the shapes need different context.
  #  (a) a grep/case ON ONE LINE, filtered to lines that name an error buffer -- that is what
  #      separates "classify a cluster read" from "assert on a message" (all the test-*.sh do the
  #      latter, which is why they are excluded wholesale above).
  #  (b) a `case` ARM: the arm and its subject `case "$_SOME_ERR" in` are on DIFFERENT lines, so a
  #      per-line err filter can never see the subject. Fold continuations and match the arm itself.
  #      A bare-substring arm is wrong regardless of subject, so no err filter is applied here.
  hits_a="$(grep -nE "(grep|case)[^|]*${_nf}" "$f" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -iE '_?err|stderr|2>' \
    || true)"
  #      A case arm is a VIOLATION only when it does not CONSTRAIN the message beyond the bare
  #      phrase. Strip the wildcards, the quotes, the alternation and the phrase itself; if any
  #      word survives, the arm named something specific and is fine:
  #        *NotFound*|*"not found"*)                  -> nothing survives           -> FLAG
  #        *'namespaces "'*'" not found'*)            -> "namespaces" survives      -> ok
  #        *"signature verification result not found"*) -> "signature ..." survives -> ok
  #      That is a rule, not an allowlist, so it does not rot as new call sites appear.
  hits_b=""
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    rest="${arm#*:}"        # drop the line number
    rest="${rest%%)*}"        # ...and the arm's BODY: keep only the PATTERN, up to the first ')'
    rest="$(printf '%s' "$rest" | sed -E "s/${_nf}//g; s/[*|]/ /g; s/[\"']/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//")"
    [ -n "$rest" ] && continue          # the arm named something -> not a bare-substring decision
    hits_b="${hits_b}${arm}
"
  done <<ARMS
$(grep -nE "^[[:space:]]*\*[^)]*${_nf}[^)]*\)" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
ARMS
  hits="$(printf '%s\n%s\n' "$hits_a" "$hits_b" | grep -v '^$' | sort -t: -k1,1n -u || true)"
  [ -n "$hits" ] || continue
  # Accepted: the anchored server prefix, on the same line.
  remaining="$(printf '%s\n' "$hits" | grep -vF "Error from server (${_NF})" || true)"
  [ -n "$remaining" ] || continue
  bad=$((bad + 1))
  printf 'FAIL %s\n' "$f"
  printf '%s\n' "$remaining" | sed 's/^/       /'
done < <(git ls-files 'scripts/*.sh' 'scripts/lib/*.sh' 2>/dev/null | grep -v '/test-')

if [ "$bad" -ne 0 ]; then
  cat >&2 <<EOF

check-notfound-discriminator: $bad file(s) decide "absent" from a bare substring, over $scanned scanned.

  Use  kube_is_notfound <errfile> <resource-token>  (scripts/lib/os.sh), or — for a shell case on
  a STRING — anchor on the server's own prefix:  *"Error from server (${_NF})"*)

  Both require the API SERVER to have said it. A client-side config error must classify as
  UNKNOWN, never as absence.
EOF
  exit 1
fi
printf 'check-notfound-discriminator: OK — %s script(s) scanned, none decides absence from a bare substring\n' "$scanned"
