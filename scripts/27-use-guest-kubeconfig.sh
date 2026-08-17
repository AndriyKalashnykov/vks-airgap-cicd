#!/usr/bin/env bash
# 27-use-guest-kubeconfig.sh — point the rest of the walk at the GUEST cluster.
#
# WHY THIS EXISTS. scenario-1 §6 used to hand the reader a table with values to type into .env:
#     | KUBECONFIG  | ./secrets/cicd-gc1.kubeconfig |
#     | VKS_CONTEXT | cicd-gc1-admin@cicd-gc1       |
# Both embed the cluster's NAME, so the example column is a literal for one particular cluster and
# the third column asks the reader to do the substitution in their head.
#
# MEASURED 2026-08-12, and it cost 12 of 17 failed blocks across two walk rows: a walk applies a
# table row's example VERBATIM when it is a safe literal, so `.env` got `cicd-gc1` while the cluster
# was `cicd-gc0812021003`. The file was empty, `make vks-login` died ("… is empty"), kubectl fell
# back to localhost:8080, and `make install-all` died at its `env-check` prerequisite in UNDER A
# SECOND — so the mirror, the builder, the platform and gitops never ran at all. Every later error
# named neither the file nor the cluster.
#
# ⚠️ WHY `./.env` AND NOT THE STATE OVERLAY. This was designed as `state_set` first and REFUTED:
#   * scenario-1 exports `KUBECONFIG=./secrets/supervisor.kubeconfig` at §3 (twice) and NEVER unsets
#     it, and the walk carries the environment forward between blocks;
#   * load_env SNAPSHOTS the selectors (lib/os.sh, the `_sel` loop) BEFORE sourcing and RESTORES
#     them AFTER, deliberately, so an explicit selector outranks every file INCLUDING .env.state.
#   Publishing to the overlay would therefore be silently overwritten on every subsequent `make` —
#   and the six loud failures would become Steps 7-13 quietly interrogating the SUPERVISOR and
#   returning plausible answers. That is strictly worse than the bug: a wrong-but-empty path fails
#   loudly, a wrong-but-valid Supervisor kubeconfig does not.
#   Writing `./.env` works because the document re-sources it (`set -a; . ./.env; set +a`) in the
#   same block, which is what displaces the stale export in the READER'S shell too.
#
# WHY NOT FOLD IT INTO `make vks-cluster-status`. That script mints this same kubeconfig and
# deliberately only PRINTS the line to set (see its own comment): it advertises itself READ-ONLY,
# and someone running it merely to LOOK at another cluster must not have their environment
# retargeted. Publishing is an EXPLICIT act with its own name — you ran this, so you meant it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

load_env

: "${VKS_CLUSTER_NAME:?set VKS_CLUSTER_NAME in .env — it names the cluster whose kubeconfig to use}"

KC="${REPO_ROOT}/secrets/${VKS_CLUSTER_NAME}.kubeconfig"
ENV_FILE="${REPO_ROOT}/.env"

# EXISTS **and NON-EMPTY**. An empty file is the state that produced the incident above, and it is
# reachable: 26-vks-cluster-status.sh creates the file before decoding the Secret into it, so a
# Secret that does not exist yet leaves a zero-byte file rather than no file. `[ -f ]` sails past it.
if [ ! -s "$KC" ]; then
  die "no guest kubeconfig at ${KC} (missing or EMPTY).
  It is written by:  make vks-cluster-status
  which reads the cluster's own ${VKS_CLUSTER_NAME}-kubeconfig Secret. If that Secret does not exist
  yet, the control plane has not been minted — wait for the cluster, then re-run this."
fi

# The context is READ from the file, never constructed. It is '<cluster>-admin@<cluster>' today, but
# that is the platform's convention, not ours to assume — and a kubeconfig with NO current-context is
# exactly what makes kubectl fall back to localhost:8080 with no target, which is how the original
# failure presented ("kubectl had NO TARGET").
CTX="$(timeout "${CREDS_K8S_TIMEOUT:-10}" kubectl --kubeconfig "$KC" config current-context </dev/null 2>/dev/null || true)"
[ -n "$CTX" ] || die "${KC} sets no current-context.
  kubectl would silently fall back to localhost:8080 and every later step would fail with an error
  naming neither this file nor this cluster. Re-fetch it with: make vks-cluster-status"

[ -f "$ENV_FILE" ] || die "no ${ENV_FILE} — run 'make env-init' first (it copies .env.example)."

# WRITE ALL THREE, THEN ASSERT ALL THREE (B138). These keys are a SELECTOR TRIPLE: they are only
# meaningful together, so they must move together.
#
# The old `_upsert` wrote only `.env`. All three are ALSO `state_set` by `05-kind-up.sh`
# (:104/:109/:110), and `load_env` sources the state overlay — and legacy `.env.kind` — AFTER `.env`.
# So on a box carrying either, the write was a NO-OP with a log line: the script announced the guest
# kubeconfig while every later command still targeted the OLD cluster. That is a silently-wrong
# selector, the worst failure mode this repo has.
#
# ⚠️ WHY NOT ONE `env_publish` PER KEY — an implementation round MEASURED the regression. `env_publish`
# is write+clear+assert for ONE key, and it returns non-zero when the value does not take effect. Under
# `set -euo pipefail`, three of them in a row means key #1 can ABORT the script, leaving keys #2 and #3
# unwritten: `VKS_AUTH_METHOD` stays `vcf`, i.e. the "stop talking to the Supervisor" switch that the
# OLD code did flip — while `.env` now shows `KUBECONFIG=<guest>`, so the operator reading the file
# believes the switch happened. That is strictly worse than the no-op it replaced. Two phases keep
# `_upsert`'s all-or-nothing write AND add the gate.
#
# The comment this replaces claimed every value must stay "bare KEY=VALUE — no quotes". That is no
# longer true: `set_env_var` single-quotes a value containing a space or `$`. Verified safe here —
# `grep -n '\$(KUBECONFIG)\|\$(VKS_CONTEXT)\|\$(VKS_AUTH_METHOD)' Makefile` returns ZERO, so none of
# the three is make-expanded, and a quoted value still round-trips through `source`.
_KEYS=(KUBECONFIG VKS_CONTEXT VKS_AUTH_METHOD)
# §3 set VKS_AUTH_METHOD to 'vcf' to reach the SUPERVISOR; from here every command targets the GUEST.
# Left on 'vcf', Step 7 silently checks the Supervisor and reports problems that are true of it and
# irrelevant to your cluster.
_VALS=("$KC" "$CTX" kubeconfig)

# Phase 1 — write every key and clear every overlay pin BEFORE asserting anything, so a failure
# cannot strand a half-superseded triple.
# ⚠️ RESIDUAL, named not hidden: `state_unset` has no ownership guard, so on a sink stamped for a
# DIFFERENT cluster it strips these keys without archiving — even though `state_check` would decline
# to source that sink. Bounded (per-key; passwords survive; `05-kind-up.sh` rewrites them next run)
# and filed rather than fixed here: the guard belongs in `state_unset`, which has other callers.
for _i in 0 1 2; do
  set_env_var "${_KEYS[$_i]}" "${_VALS[$_i]}" "$ENV_FILE"
  state_unset "${_KEYS[$_i]}" || true
done

# Phase 2 — assert all three, collect every failure, die ONCE with the whole picture.
_bad=""
for _i in 0 1 2; do
  assert_env_effective "${_KEYS[$_i]}" "${_VALS[$_i]}" "the GUEST cluster selector" \
    || _bad="${_bad} ${_KEYS[$_i]}"
done
[ -z "$_bad" ] || die "the guest selector did NOT take effect for:${_bad}
  All three were written to ${ENV_FILE} and their state-overlay pins cleared, so a HIGHER-precedence
  file is still winning — each line above names the file that wins. Fix those, then re-run; every
  later step targets a cluster until this is coherent."

log_info "wrote to ${ENV_FILE} (and cleared any state-overlay pin on these keys):"
log_info "  KUBECONFIG=${KC}"
log_info "  VKS_CONTEXT=${CTX}"
log_info "  VKS_AUTH_METHOD=kubeconfig"
log_info "NOW RE-SOURCE IT, or this shell keeps the SUPERVISOR kubeconfig that Step 3 exported:"
log_info "  set -a; . ./.env; set +a"
# ⚠️ The assert above proves no FILE shadows these values. It CANNOT see the KUBECONFIG you exported
# at §3: `assert_env_effective` unsets the key before re-reading, which is exactly what makes it a
# valid FILE test and exactly what blinds it to the ENVIRONMENT. Measured: with KUBECONFIG exported to
# the Supervisor, the assert returns 0 while a child process still resolves the Supervisor. Only
# re-sourcing displaces that — the line above is not redundant.
