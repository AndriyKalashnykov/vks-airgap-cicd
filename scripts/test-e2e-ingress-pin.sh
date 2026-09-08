#!/usr/bin/env bash
# The e2e's ingress pin must DEFAULT to istio and still HONOUR the operator's command line.
#
# B569. `e2e-kind` pinned the controller TWICE: a target-specific `export` using
# `$(origin INGRESS_CONTROLLER)`, and a literal `INGRESS_CONTROLLER=istio` in the `$(MAKE)` goal
# list. The second one is a sub-make COMMAND-LINE variable, which outranks the caller's own command
# line -- so `make e2e-kind INGRESS_CONTROLLER=traefik` silently ran istio. That is verbatim the bug
# the comment above the target says it FIXED, and an inversion of the invariant at Makefile:147.
#
# ⚠️ THE OBVIOUS RED-PROOF DOES NOT WORK, and an adversary round prescribed it anyway: comparing
# `make -n e2e-kind INGRESS_CONTROLLER=traefik` against plain `make -n e2e-kind`. `make -n` prints
# recipe TEXT, and a target-specific `export` lives in the ENVIRONMENT -- so once the goal-list
# literal is gone the two are byte-identical BY DESIGN, in both the fixed and the broken tree. That
# instrument cannot see this defect at all. What discriminates is what the CHILD make receives.
#
# MEASURED semantics of the export (exact replica, 2026-09-08):
#     operator says nothing                  -> istio    (default holds; the stale-state hole stays shut)
#     make e2e-kind INGRESS_CONTROLLER=x     -> x        (honoured; was `istio` before the fix)
#     INGRESS_CONTROLLER=x make e2e-kind     -> istio    (NAMED RESIDUAL, see below)
#
# ⚠️ RESIDUAL, deliberate: an operator who EXPORTS the variable instead of passing it on the command
# line still gets istio, because `$(origin)` reads `environment`, not `command line`. Makefile:147's
# invariant is about the command line, and for an e2e an ambient exported value is exactly the
# stale-state class this pin exists to defeat -- so the narrowing is defensible. It is named here
# rather than left silent.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# 1. STRUCTURAL: no e2e target may re-pin the controller in its own goal list. This is the defect
#    itself, and it is what a future edit would reintroduce.
# ⚠️ SCOPED TO e2e-kind's OWN RECIPE, and both halves of that are load-bearing.
# `verify-ingress-both` (and the istio-existing e2e) pin the controller in their goal lists
# DELIBERATELY -- running both controllers is the entire point of those targets -- so a repo-wide
# grep would flag 4 correct lines and the only way to green it would be to break them.
#
# ⚠️ AND DO NOT WRITE `^\t` HERE. There are TWO greps on this box: the interactive shell resolves
# `grep` to ugrep 7.8.4, which honours `\t` in an ERE, while a script gets GNU grep 3.11, which
# does NOT -- it matches a literal `t`. MEASURED on the same file, same pattern: ugrep 4 matches,
# GNU grep 0. So a pattern "verified" at the prompt can be DEAD in the test, which is exactly how
# the first version of this guard passed over a Makefile that had the defect reinstated.
_recipe=$(awk '/^e2e-kind:/{f=1; next} /^\t/{if(f) print; next} /^#/{next} /^[[:space:]]*$/{next} {f=0}' Makefile)
if [ -z "$_recipe" ]; then
  bad "could not extract e2e-kind's recipe — the extractor is broken, not the Makefile"
elif printf '%s\n' "$_recipe" | grep -qE '\$\(MAKE\).*INGRESS_CONTROLLER='; then
  bad "e2e-kind re-pins INGRESS_CONTROLLER in a \$(MAKE) goal list — that outranks the operator's own command line"
else
  ok "e2e-kind does not re-pin INGRESS_CONTROLLER in a \$(MAKE) goal list"
fi

# 2. The export must still EXIST -- deleting it is the other way to break this, and it would leave
#    a stale `.env.state` free to choose the controller (the hole the pin was added to close).
if grep -qE '^e2e-kind: export INGRESS_CONTROLLER' Makefile; then
  ok "e2e-kind still exports INGRESS_CONTROLLER (the stale-.env.state guard)"
else
  bad "e2e-kind no longer exports INGRESS_CONTROLLER — a stale .env.state can pick the controller"
fi

# 3. BEHAVIOURAL, against an exact replica of the export line lifted FROM the Makefile, so the test
#    cannot pass over a rewritten one. Reading the real line is the point: a hand-copied replica
#    would keep asserting the old semantics after someone changed it.
_line=$(grep -E '^e2e-kind: export INGRESS_CONTROLLER' Makefile | head -1)
if [ -n "$_line" ]; then
  _mk=$(mktemp); trap 'rm -f "$_mk"' EXIT
  {
    printf '%s\n' "${_line/e2e-kind:/t:}"
    # shellcheck disable=SC2016  # single quotes REQUIRED: $(MAKE) and $$VAR are make/shell syntax
    # for the generated makefile, and must reach it literally rather than expanding here.
    printf 't:\n\t@$(MAKE) -s --no-print-directory -f %s child\n' "$_mk"
    # shellcheck disable=SC2016  # ditto -- $$ is make's escape for a literal $ in a recipe
    printf 'child:\n\t@echo "$$INGRESS_CONTROLLER"\n'
  } > "$_mk"
  _default=$(make -s -f "$_mk" t 2>/dev/null)
  _cli=$(make -s -f "$_mk" t INGRESS_CONTROLLER=traefik 2>/dev/null)
  # if/fi, not `A && B || C` -- that idiom runs C when B fails, and it is the linter class that
  # reddened main for six hours earlier today.
  if [ "$_default" = istio ]; then ok "with no override the CHILD make receives istio"
  else bad "default: child received [$_default], want istio"; fi
  if [ "$_cli" = traefik ]; then ok "with 'make ... INGRESS_CONTROLLER=traefik' the CHILD receives traefik"
  else bad "command line DISCARDED: child received [$_cli], want traefik"; fi
else
  bad "could not read the export line from the Makefile — the extractor is broken, not the Makefile"
fi

printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
