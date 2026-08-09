#!/usr/bin/env bash
# check-classifier-consumers.sh — every case-form consumer of classify_kube_failure must handle
# every class the classifier can emit.
#
# WHY THIS GATE EXISTS. The consumer set DRIFTS from the classifier every time a class is added, and
# the drift is silent: an unhandled class falls to `*)`, whose text is "the error is not one we
# classify" — literally false, since it WAS classified, and it costs the operator the one remedy
# that class carries. Measured twice: PLAINTEXT was added in PR #469 and reached ONE of four
# consumers; KUBECONFIG_UNUSABLE was added this session and reached two. Neither was noticed by any
# test, because the classifier's own suite tests the CLASSIFIER and is structurally blind to a
# consumer losing an arm.
#
# BOTH LISTS ARE DERIVED, NEVER HAND-TYPED — a second hand-typed list is the same rot one level up.
#
# ⚠️ SCOPED TO `case`-FORM CONSUMERS ONLY. `02-env.sh`'s `elif [ "$(classify…)" = STALE_CA ]` is a
# single-class test, and the app-namespace check interpolates the class into a warning without
# branching; demanding arms of those would be a false RED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

LIB="${REPO_ROOT}/scripts/lib/os.sh"
_U="_"   # composes the function name so this file never matches its own grep
_PAT="case \"\$(classify_kube${_U}failure"

# 1. What can the classifier EMIT? Read it out of the function body.
CLASSES="$(sed -n '/^classify_kube_failure()/,/^}/p' "$LIB" \
            | grep -oE "printf '[A-Z_]+'" | grep -oE "[A-Z_]+" | sort -u)"
[ -n "$CLASSES" ] || die "could not derive the class list from ${LIB} — refusing to guess.
  (A gate that cannot read its own ground truth must fail, not pass.)"
n_classes="$(printf '%s\n' "$CLASSES" | grep -c .)"

# UNKNOWN is the catch-all itself: a consumer handles it BY having `*)`, so requiring a named arm
# for it would demand dead code.
CLASSES="$(printf '%s\n' "$CLASSES" | grep -vx UNKNOWN || true)"

log_info "check-classifier-consumers: classifier emits ${n_classes} class(es): $(printf '%s' "$CLASSES" | tr '\n' ' ') UNKNOWN"

# 2. Find every case-form dispatch on the classifier and read the arms it declares.
#    (The literal form is NOT written here on purpose — see the composition note above. A comment
#     that spells the pattern out is enough to make this file match its own scan.)
rc=0; checked=0
while IFS= read -r hit; do
  f="${hit%%:*}"; rest="${hit#*:}"; ln="${rest%%:*}"
  # The case block runs from the `case` line to its `esac`.
  body="$(awk -v s="$ln" 'NR>=s{print} NR>=s && /^[[:space:]]*esac/{exit}' "$f")"
  case "$body" in *esac*) : ;; *) log_warn "  ${f}:${ln}: no esac found — skipping"; continue ;; esac
  checked=$((checked+1))
  missing=""
  for c in $CLASSES; do
    printf '%s' "$body" | grep -qE "^[[:space:]]*(\*?\|?)?[A-Z_|]*\b${c}\b[A-Z_|]*\)" || missing="${missing} ${c}"
  done
  if [ -n "$missing" ]; then
    log_error "  ${f}:${ln}: does NOT handle:${missing}"
    log_error "     Those fall to \`*)\`, whose text says the error is 'not one we classify' — which is"
    log_error "     false, and drops the remedy that class exists to carry."
    rc=1
  else
    log_info "  ${f}:${ln}: handles every class"
  fi
# ⚠️ THE SEARCH PATTERN IS COMPOSED AT RUNTIME so this file cannot match itself. A gate that lives
# in the tree it scans and spells out the form it hunts for will FLAG ITS OWN SOURCE — measured: it
# reported itself as a consumer handling zero classes. Do NOT "fix" that by excluding this file by
# name: that blinds the gate to every future real finding in it. Composing the literal is what keeps
# the scan honest, and a self-test below proves this file contributes zero hits.
done < <(grep -rn "$_PAT" "${REPO_ROOT}/scripts" --include='*.sh' | grep -v '/test-')

# SELF-TEST: this file must contribute ZERO hits. If it ever does, the composition above broke and
# the gate is scanning itself again — which is a false finding, not a real one.
if grep -qn "$_PAT" "${BASH_SOURCE[0]}"; then
  die "this gate matches its OWN source — the runtime-composed pattern has been replaced by a
  literal. Re-compose it; do NOT exclude this file by name."
fi

[ "$checked" -gt 0 ] || die "found NO case-form consumers — the grep must have drifted. Refusing to
  report OK over a search that found nothing (that is a pass-by-not-looking)."

if [ "$rc" -eq 0 ]; then
  log_info "check-classifier-consumers: OK — ${checked} case-form consumer(s), all classes handled."
else
  log_error "check-classifier-consumers: FAILED"
fi
exit "$rc"
