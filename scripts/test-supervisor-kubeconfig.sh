#!/usr/bin/env bash
# test-supervisor-kubeconfig.sh — pins the Supervisor-kubeconfig resolver trio.
#
# WHY THIS EXISTS. Every proof below was made BY HAND on 2026-08-24 and a by-hand RED-proof EXPIRES
# at the next commit touching the code (gates.md). The load-bearing one is a RULE ZERO-B leak an
# adversary round found: supervisor_kubeconfig_hint printed
#   "${VKS_LAB_STATE_DIR:-$HOME/.local/state/nested-lab}/kubeconfig"
# to EVERY end user, in 8 scripts, on a box that has never heard of that repo -- while os.sh claimed
# the entry "is existence-guarded, so for an end user who has no such directory it is a silent
# no-op". That was TRUE of the RESOLVER ([ -s "$c" ]) and FALSE of the PRINTER. CLAUDE.md RULE
# ZERO-B: "Never point the end user at nested-vsphere-lab -- not at its targets, its files, or its
# output." A later "simplification" of ${_lab:+$_lab/kubeconfig} back to a plain expansion would
# silently restore the leak in 8 scripts with NOTHING red. Case 1 is that guard.
#
# Offline by construction: no cluster, no network, no kubectl -- these are pure shell functions over
# temp files, so this cannot be flaky.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { printf 'FATAL: cannot cd to the repo root\n' >&2; exit 1; }

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); return 0; }
bad() { printf '  FAIL  %s  (%s)\n' "$1" "${2:-}"; fail=$((fail+1)); return 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Run one of the trio in a clean child. Every candidate var is unset unless the caller sets it, so
# a var leaking in from the developer's shell cannot make a case pass.
run() { # run <fn> [VAR=val ...]
  local fn="$1"; shift
  env -u KUBECONFIG -u VKS_SUPERVISOR_KUBECONFIG -u SUPERVISOR_KUBECONFIG -u ARGOCD_KUBECONFIG \
      -u VKS_LAB_STATE_DIR REPO_ROOT=/nonexistent SKIP_DOTENV=1 "$@" \
      bash -c ". scripts/lib/os.sh 2>/dev/null; $fn" 2>&1
}

# --- 1. RULE ZERO-B: an end user must never see the lab path ------------------------------------
mkdir -p "$T/enduser"
n=$(run supervisor_kubeconfig_hint HOME="$T/enduser" | grep -c 'nested-lab')
if [ "$n" -eq 0 ]; then ok "end user with no lab dir sees NO nested-vsphere-lab path"
else bad "end user with no lab dir sees NO nested-vsphere-lab path" "$n mention(s) leaked"; fi

# --- 2. the maintainer path still WORKS (the fix must not amputate it) --------------------------
mkdir -p "$T/lab"; printf 'apiVersion: v1\n' > "$T/lab/kubeconfig"
if run supervisor_kubeconfig_hint VKS_LAB_STATE_DIR="$T/lab" | grep -q "$T/lab/kubeconfig"
then ok "maintainer WITH a lab dir: the hint still lists it"
else bad "maintainer WITH a lab dir: the hint still lists it" "not listed"; fi

got=$(run supervisor_kubeconfig VKS_LAB_STATE_DIR="$T/lab")
if [ "$got" = "$T/lab/kubeconfig" ]; then ok "maintainer WITH a lab dir: the resolver still RETURNS it"
else bad "maintainer WITH a lab dir: the resolver still RETURNS it" "got [$got]"; fi

# --- 3. a lab-state path that is a FILE, not a dir, must not resolve or crash -------------------
printf 'not a directory\n' > "$T/labfile"
if run supervisor_kubeconfig VKS_LAB_STATE_DIR="$T/labfile" >/dev/null 2>&1
then bad "VKS_LAB_STATE_DIR pointing at a FILE does not resolve" "it resolved"
else ok "VKS_LAB_STATE_DIR pointing at a FILE does not resolve"; fi

# --- 4. the THREE-WAY label. A two-way label lies in one direction or the other. ----------------
# `[ -s ]` alone called an existing 0-byte file `absent`; `[ -e ]` alone called a good 6-byte file
# FOUND-BUT-EMPTY. The tempting rationale for a two-way label -- "the hint only runs when the
# resolver returned 1" -- is MEASURED FALSE: jumpbox-launch.sh calls the hint from its own
# `[ -s "$_sup" ]` guard and never calls the resolver, so a non-empty candidate genuinely arrives.
printf '12345\n' > "$T/present"; : > "$T/empty"
lbl=$(run supervisor_kubeconfig_hint VKS_SUPERVISOR_KUBECONFIG="$T/present" \
                                     SUPERVISOR_KUBECONFIG="$T/empty" ARGOCD_KUBECONFIG=/does/not/exist)
if printf '%s' "$lbl" | grep -q "present .*$T/present"; then ok "label: a NON-empty file reads 'present'"
else bad "label: a NON-empty file reads 'present'" "$(printf '%s' "$lbl" | grep -F "$T/present")"; fi

if printf '%s' "$lbl" | grep -qF "EMPTY (0 bytes) $T/empty"; then ok "label: a 0-byte file reads 'EMPTY (0 bytes)'"
else bad "label: a 0-byte file reads 'EMPTY (0 bytes)'" "$(printf '%s' "$lbl" | grep -F "$T/empty")"; fi

if printf '%s' "$lbl" | grep -q "absent .*does/not/exist"; then ok "label: a missing file reads 'absent'"
else bad "label: a missing file reads 'absent'" "not labelled absent"; fi

# --- 5. or_die must PRINT the derived list, never a hand-typed one ------------------------------
# The hand-typed version named FIVE entries where candidates emits SIX, omitting the lab entry,
# while saying "Tried, in order:". Assert the omitted one is present and the hand-typed line is not.
mkdir -p "$T/lab2"
out=$(run 'supervisor_kubeconfig_or_die probe' VKS_LAB_STATE_DIR="$T/lab2" 2>&1)
if printf '%s' "$out" | grep -qF "$T/lab2/kubeconfig"
then ok "or_die prints the DERIVED search order (the lab candidate appears)"
else bad "or_die prints the DERIVED search order (the lab candidate appears)" "candidate missing -- hand-typed list back?"; fi

if printf '%s' "$out" | grep -q 'Tried, in order:'
then bad "or_die no longer carries the hand-typed 'Tried, in order:' list" "the hand-typed list is back"
else ok "or_die no longer carries the hand-typed 'Tried, in order:' list"; fi

# --- 6. the hint must reach STDERR, because or_die's STDOUT IS ITS RETURN VALUE -----------------
# 24-vks-k8s-version.sh captures or_die in $( ). Without `>&2` the guidance is swallowed INTO the
# resolved path and the operator sees nothing. This pins the `>&2`.
mkdir -p "$T/lab3"; printf 'apiVersion: v1\n' > "$T/lab3/kubeconfig"
val=$(env -u KUBECONFIG -u VKS_SUPERVISOR_KUBECONFIG -u SUPERVISOR_KUBECONFIG -u ARGOCD_KUBECONFIG \
        VKS_LAB_STATE_DIR="$T/lab3" REPO_ROOT=/nonexistent SKIP_DOTENV=1 \
        bash -c '. scripts/lib/os.sh 2>/dev/null; supervisor_kubeconfig_or_die probe' 2>/dev/null)
if [ "$val" = "$T/lab3/kubeconfig" ]
then ok "or_die's return value is UNPOLLUTED by the hint (the >&2 is intact)"
else bad "or_die's return value is UNPOLLUTED by the hint (the >&2 is intact)" "got [$val]"; fi

printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
