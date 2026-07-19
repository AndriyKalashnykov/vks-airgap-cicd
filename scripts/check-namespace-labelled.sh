#!/usr/bin/env bash
# check-namespace-labelled.sh — every namespace we OWN (the psa-check inventory) must be reached by
# an `ensure_namespace` call somewhere in scripts/, on a path a real operator actually runs.
#
# WHY THIS IS A GATE AND NOT A RULE:
#   lib/psa.sh:104 has said "Use this everywhere instead of a bare `kubectl create namespace`" since
#   #290. Prose. Loaded. And when this gate was written, `make install-all` — the documented real-lab
#   install — labelled NEITHER gitea NOR tekton, because their only ensure_namespace calls lived
#   inside lib/istio.sh's route functions, reachable solely from `make install-ingress`, which
#   install-all (Makefile:459) does not run. The label landed never. On a VKS guest, which enforces
#   Pod Security `restricted` by default, that is the difference between a working demo and every
#   pod rejected.
#
#   It hid for two reasons, and both are why this is a gate:
#     - `make e2e-kind` runs install-ingress EXPLICITLY, so the e2e's own target list made gitea look
#       labelled while an operator following the runbook got nothing. The test was the camouflage.
#     - `49-psa-check.sh` — the one live instrument — reports OK for an unlabelled gitea: its
#       `eff="${cur:-restricted}"` defaults an ABSENT label to `restricted`, gitea's pods are
#       restricted-clean, so need==eff and the verdict is OK. It certifies the exact namespace this
#       gate is about.
#
# WHY THIS SHAPE, AND NOT A SYNTAX GATE. The obvious design — grep for a bare `kubectl create
# namespace` — was built and RUN by an adversary against a corpus of real forms: it caught 0 of 8.
# Namespaces appear on this cluster by SEVEN mechanisms, and a grep for the literal `kubectl` sees
# three of them:
#     1. `kubectl create namespace`            (the only one a naive grep finds)
#     2. a WRAPPER — `hub`/`guest`/`ka`/`kg` (6 wrappers across 5 scripts; `hub create namespace` is
#        live at e2e-cross-cluster.sh:57 and no literal-kubectl grep will ever see it)
#     3. `kind: Namespace` in an in-tree manifest
#     4. `kind: Namespace` in an UPSTREAM manifest we apply (tekton's release YAML) — not in-tree,
#        so no file scan can see it
#     5. helm `--create-namespace`
#     6. ArgoCD `CreateNamespace=true` — a CONTROLLER creates it, from no file at all
#     7. a chart that ships its own Namespace
#   Worse, the enumeration that produced the syntax gate's pattern list was itself made with that
#   same grep — so the gate could not fail on what the premise missed. Self-confirming.
#
#   So this gate keys on the INVENTORY, not the syntax: whatever mechanism creates a namespace, if we
#   own it, an ensure_namespace call must cover it.
#
#   That RELOCATES the blindness rather than removing it, and this header once falsely claimed it was
#   "immune to all six blind spots above". It is not: the gate is only as good as its inventory, and
#   the inventory is hand-typed below. An adversary proved it — `tekton-pipelines-resolvers` (declared
#   by tekton's UPSTREAM manifest, mechanism 4; we even `wait` on it at 41-install-tekton.sh:72) was
#   absent from NS_SPEC, from this list, and from .env.example, so nothing labelled it and this gate
#   could not see it.
#
#   ⚠️ CORRECTED 2026-07-19: this line used to read "It is now listed." IT IS NOT. `tekton-pipelines-
#   resolvers` is STILL in neither NS_SPEC nor the OWNED list below — the sentence certified a
#   coverage the gate does not have, which is the manufactured-confidence failure one level up from a
#   vacuous green: a future session greps for the namespace, finds this claim, and stops looking.
#   Two more are in the same state: `argocd` (07-install-argocd.sh:78) and `harbor`
#   (06-install-harbor.sh:151). All three reach ensure_namespace and are measured by neither
#   inventory.
#
#   AND THE DRIFT CHECK BELOW CANNOT SEE THEM. It compares `owned_rows + 2` against `spec_rows`, so a
#   namespace missing from BOTH lists keeps the arithmetic balanced and is structurally invisible.
#   Only a THIRD, independent ground truth can catch that — the ensure_namespace CALL SITES. Adding
#   them is NOT a one-liner and is tracked as its own backlog row: adding argocd/harbor to NS_SPEC as
#   `ours` would make psa-check RED (both are deliberately UNLABELLED, and an unlabelled namespace
#   evaluates as `restricted`), and psa-check is the first prerequisite of `install-all` — so the
#   naive fix converts a reporting gap into a broken install. The next such namespace will be
#   invisible the same way until
#   the owned set is DERIVED (parse `kind: Namespace` out of bundle/manifests/* + the in-tree
#   manifests) rather than typed — which bundle/ being gitignored currently prevents in CI.
#
# THE CALL MUST LIVE IN THE INSTALLER THAT `install-all` ACTUALLY REACHES — not just "somewhere".
# The first draft of this gate grepped scripts/ repo-wide for `ensure_namespace "$VAR"`. An adversary
# deleted the calls from 40-install-gitea.sh AND 41-install-tekton.sh — restoring F2 exactly, with the
# calls surviving only in lib/istio.sh (reachable solely from `make install-ingress`, which
# `make install-all` does not run) — and the gate reported **OK, rc=0**. It was blind to the precise
# regression it was written for. Its RED-proof had passed only because $TRAEFIK_NAMESPACE happened to
# have no call ANYWHERE; once any call exists, a repo-wide grep is satisfied forever, on any path.
#
# So the inventory maps each namespace to the SCRIPT that must own its call. "A call exists" is not
# the property that matters; "the installer on the reached path makes the call" is. Deleting the call
# from 40-install-gitea.sh now goes RED.
#
# STILL NOT PROVEN BY THIS GATE, stated so its green is not over-read: that the script itself is
# reached (a Makefile edit could strand 40-install-gitea.sh the way install-ingress was stranded),
# and that the label actually lands. `make psa-check` against a live cluster measures the label
# rather than the call, and is the only thing that proves the end result.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

# <VAR>:<script that install-all reaches and that must own the call>
# Single-sourced against 49-psa-check.sh's NS_SPEC — the ROW-COUNT CHECK below fails if they drift.
#
# istio-system + the istio gateway ns are deliberately ABSENT: they are the mesh's own, PSA-labelled
# at 46-install-istio.sh:130-131 via psa_label_namespace (NOT ensure_namespace), because stamping
# istio-injection=disabled on the platform's namespace is exactly what we must never do. That is the
# +2 in the drift arithmetic below.
#
# A row's first field is a VAR when it looks like one (UPPER_SNAKE) and a LITERAL namespace name
# otherwise. No new syntax is needed to tell them apart: a Kubernetes namespace is DNS-1123
# (lowercase alphanumeric and dashes), so it can NEVER be mistaken for a shell variable name. That
# matters because 41-install-tekton.sh:90 passes `tekton-pipelines-resolvers` as a LITERAL, and
# inventing a TEKTON_RESOLVERS_NAMESPACE var purely to satisfy a var-keyed regex would mean four
# coordinated edits (a var in .env.example that nothing else reads, an NS_SPEC row, a call-site
# rewrite, and this row) to record a fact the call site already states plainly.
OWNED='GITEA_NAMESPACE:40-install-gitea.sh
TEKTON_NAMESPACE:41-install-tekton.sh
tekton-pipelines-resolvers:41-install-tekton.sh
CI_NAMESPACE:60-configure-tekton.sh
TRAEFIK_NAMESPACE:45-install-traefik.sh
ISTIO_GWAPI_NAMESPACE:lib/istio.sh'

HITS=()
checked=0

# `while read` from a here-string, not `for v in $OWNED` — zsh does not word-split an unquoted
# parameter expansion, and this repo has been bitten by that exact loop running once.
while IFS=: read -r v script; do
  [ -n "${v:-}" ] || continue
  checked=$((checked+1))
  # Anchored to a COMMAND POSITION and comment-stripped: an unanchored grep matches its own
  # commented-out corpse (`# TODO re-enable: ensure_namespace "$TRAEFIK_NAMESPACE"`), which is the
  # MOST likely regression — commenting-out while debugging — and the first draft was blind to it.
  # VAR rows match `ensure_namespace "${VAR}"`; LITERAL rows match the name verbatim. The shape of
  # the field decides, so neither form needs to be declared.
  case "$v" in
    [A-Z_]*) _pat="\\\$\{?${v}\}?" ;;   # UPPER_SNAKE -> a shell variable
    *)       _pat="${v}" ;;                  # DNS-1123 -> a literal namespace name
  esac
  if sed 's/#.*//' "scripts/${script}" 2>/dev/null \
       | grep -qE "^[[:space:]]*ensure_namespace[[:space:]]+\"?${_pat}\"?"; then
    continue
  fi
  case "$v" in [A-Z_]*) _label="\$${v}" ;; *) _label="${v}" ;; esac
  HITS+=("${_label}: no ensure_namespace call at a command position in scripts/${script} — the installer that 'make install-all' reaches. A call elsewhere (e.g. lib/istio.sh, reached only by install-ingress) does NOT count: that IS the F2 bug.")
done <<EOF
$OWNED
EOF

# The per-app namespaces come from apps/registry.tsv via a loop, so they are covered by var name
# rather than literal. Assert the loop exists at all.
# shellcheck disable=SC2016  # the $ is literal: we grep for the SOURCE TEXT `ensure_namespace "$a"`
if ! grep -rqE 'ensure_namespace "\$(a|APP_NAMESPACE)"' scripts/ 2>/dev/null; then
  HITS+=("app namespaces: no ensure_namespace call in an app loop (expected in 70-configure-argocd.sh and lib/istio.sh)")
fi
checked=$((checked+1))

# --- The denominator is part of the verdict, and the drift check is the point ---------------
# A gate that scanned nothing is BROKEN, not green.
[ "$checked" -gt 0 ] || die "check-namespace-labelled: checked 0 namespaces — OWNED_VARS is empty."

# NS_SPEC drift: this gate's inventory must not silently fall behind psa-check's. Count the
# non-empty, non-app rows of NS_SPEC and compare. (psa-check owns istio-system + the gateway ns
# too, hence the +2 we deliberately do not cover here.)
# This check ONCE only died on 0 while the header promised it "fails when they drift" — a number
# printed as decoration, gating nothing. An adversary added an 8th NS_SPEC row and the gate happily
# printed "declares 8 rows" and passed. A number you print that gates nothing is worse than no number.
# Count LOGICAL rows, not `${VAR`-prefixed ones. The old regex could not see a row whose namespace
# is a LITERAL (`tekton-pipelines-resolvers|...`), so adding one — the very row this gate's own
# header says is needed — made the arithmetic below DIE on a correct change. Behaviour-preserving
# today (still 7): the only non-`${VAR` row right now is the `$(app_names ...)` loop, which expands
# to N app rows and is deliberately excluded from BOTH sides of the comparison (the app namespaces
# get their own assert further up). Excluding it by its `$(` prefix, rather than by requiring `${`,
# is what makes a future literal row countable.
spec_rows=$(sed -n '/^NS_SPEC="/,/^"$/p' scripts/49-psa-check.sh 2>/dev/null \
  | grep -vE '^NS_SPEC="|^"$|^[[:space:]]*$|^\$\(' | grep -c . || true)
if [ "${spec_rows:-0}" -eq 0 ]; then
  die "check-namespace-labelled: could not read NS_SPEC from 49-psa-check.sh — the inventory this gate mirrors is unreadable, so a green here would mean nothing."
fi
# owned rows + the 2 the mesh owns (istio-system, the istio gateway ns), which psa-check measures and
# this gate deliberately does not cover.
owned_rows=$(printf '%s\n' "$OWNED" | grep -c .)

# The `+2` magic constant is GONE. It encoded "istio-system + the istio gateway ns are in NS_SPEC but
# not in OWNED", a fact that now lives in NS_SPEC's own ownership column where a reader meets it,
# instead of as a bare 2 in a different file. `want` is simply how many rows declare themselves ours.
#
# The `^\$\(` exclusion stays as the FIRST filter (it drops the `$(app_names ...)` loop row, which
# expands to N app rows and is deliberately outside this comparison on both sides). Do not let the
# fact that an anchored count would also give the right answer today become load-bearing — that is
# an accident of the printf, not a property.
_spec_body="$(sed -n '/^NS_SPEC="/,/^"$/p' scripts/49-psa-check.sh 2>/dev/null \
                | grep -vE '^NS_SPEC="|^"$|^[[:space:]]*$|^\$\(' || true)"
_ours=$(printf '%s\n' "$_spec_body" | grep -c '|ours$' || true)
_mesh=$(printf '%s\n' "$_spec_body" | grep -c '|mesh$' || true)
_kind=$(printf '%s\n' "$_spec_body" | grep -c '|kind-only$' || true)

# RECONCILIATION. The ownership column is operator-typed, so a typo (`ourss`) or a dropped third
# field would silently shrink the `ours` count — un-gating a namespace by accident, and handing
# anyone a one-word escape hatch from this gate. Every row must be accounted for by exactly one
# ownership value; if the parts do not sum to the whole, refuse rather than compute a smaller `want`.
if [ $((_ours + _mesh + _kind)) -ne "$spec_rows" ]; then
  die "check-namespace-labelled: NS_SPEC ownership does not reconcile — ${spec_rows} row(s) but ours=${_ours} + mesh=${_mesh} + kind-only=${_kind} = $((_ours + _mesh + _kind)). A row with a missing or misspelled ownership field would silently un-gate that namespace."
fi
want=$_ours
# Compare LIKE WITH LIKE: how many rows call themselves ours, against how many this gate covers.
# (It used to compare spec_rows against owned_rows+2, which only worked because every non-ours row
# was one of the two mesh ones. Adding kind-only rows breaks that identity — and did, loudly.)
if [ "$owned_rows" -ne "$want" ]; then
  die "check-namespace-labelled: NS_SPEC drift — 49-psa-check.sh declares ${spec_rows} row(s) of which ${_ours} are 'ours' (${_mesh} mesh, ${_kind} kind-only), but this gate covers ${owned_rows}. A namespace added to one inventory and not the other is invisible to whichever lacks it (that is exactly how tekton-pipelines-resolvers went unlabelled). Update BOTH."
fi

if [ "${#HITS[@]}" -gt 0 ]; then
  log_error "check-namespace-labelled: ${#HITS[@]} owned namespace(s) reach no ensure_namespace call (checked ${checked}; NS_SPEC declares ${spec_rows} rows):"
  for h in "${HITS[@]}"; do printf '  - %s\n' "$h"; done
  echo
  echo "  ensure_namespace (scripts/lib/psa.sh) is the ONLY place a namespace we own gets its PSA"
  echo "  level and its istio-injection=disabled label. KinD enforces no PSA, so a namespace missing"
  echo "  both is INVISIBLE locally and has its pods REJECTED on a real VKS guest."
  echo "  Add the call to the installer that creates the namespace — NOT to the ingress step, which"
  echo "  'make install-all' does not run (that was the F2 bug this gate exists to prevent)."
  exit 1
fi

log_info "check-namespace-labelled: OK — ${checked} owned namespace(s) each reach an ensure_namespace call; NS_SPEC declares ${spec_rows} rows."
