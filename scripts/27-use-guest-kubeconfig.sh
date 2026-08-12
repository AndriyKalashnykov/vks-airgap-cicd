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

# Idempotent upsert. `.env` is read by BOTH `make -include` and a shell `source`, so every value must
# stay bare KEY=VALUE — no quotes, no spaces around `=`. These three values contain none.
# Mode is preserved by writing THROUGH the existing file rather than replacing it: a fresh file
# would be created at the caller's umask, and .env carries credentials.
_upsert() {                                  # _upsert <key> <value>
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  grep -v "^[[:space:]]*${k}=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"                   # NOT mv: preserves .env's own mode and ownership
  rm -f "$tmp"
}

_upsert KUBECONFIG      "$KC"
_upsert VKS_CONTEXT     "$CTX"
# §3 set this to 'vcf' to reach the SUPERVISOR; from here every command targets the GUEST. Left on
# 'vcf', Step 7 silently checks the Supervisor and reports problems that are true of it and
# irrelevant to your cluster.
_upsert VKS_AUTH_METHOD kubeconfig

log_info "wrote to ${ENV_FILE}:"
log_info "  KUBECONFIG=${KC}"
log_info "  VKS_CONTEXT=${CTX}"
log_info "  VKS_AUTH_METHOD=kubeconfig"
log_info "NOW RE-SOURCE IT, or this shell keeps the SUPERVISOR kubeconfig that Step 3 exported:"
log_info "  set -a; . ./.env; set +a"
