#!/usr/bin/env bash
# lib/state.sh — the ONE sink for DISCOVERED state, stamped with the cluster that wrote it.
#
# WHY THIS EXISTS
# ---------------
# `.env.kind` was a KinD-named file carrying REAL-LAB state: Harbor/ArgoCD/Gitea LB IPs,
# INGRESS_LB_IP, VKS_AUTH_METHOD, and the three GENERATED passwords. Two consequences:
#
#   * `make kind-down` deletes what the KinD flow created — and BOTH real-lab runbooks tell the
#     operator to run it at Step 0. It has already been caught destroying a real lab's kubeconfig and
#     Gitea CI token once (#167).
#   * A STALE overlay from a previous cluster is indistinguishable from a deliberate override. That is
#     the publish-then-read-back trap this repo has now removed twice (INGRESS_LB_IP_OVERRIDE;
#     GITEA_ARGOCD_URL -> gitea_clone_url()).
#
# WHAT THE ADVERSARY KILLED (do not "fix" these back)
# --------------------------------------------------
#  * "REFUSE to source a mismatched overlay" — the backlog's own words, and WRONG. This file holds the
#    ONLY copy of the generated HARBOR/GITEA/ARGOCD passwords, and the air-gap jumpbox has no cluster
#    to stamp against. Refusing destroys them and breaks the jumpbox. Polarity is INVERTED:
#        UNSTAMPED  -> source it, warn.            (legacy / jumpbox / hand-written)
#        MISMATCHED -> ARCHIVE it (rename!), warn, continue on a fresh one.   NEVER rm.
#  * "Two sinks, split by key lifetime" — LIFETIME IS A PROPERTY OF THE CLUSTER, NOT OF THE KEY.
#    INGRESS_LB_IP is ephemeral when KinD wrote it and persistent when a lab wrote it. Any static
#    per-key bucketing is wrong half the time.
#  * "Derive everything, publish nothing" — deriving the ArgoCD values needs exactly the RBAC a tenant
#    is PROVEN not to have (#163), and a generate-if-absent secret helper would silently MINT a random
#    HARBOR_PASSWORD on a real lab, where Harbor is a Supervisor Service whose credential we CONSUME.
#
# The sink keeps the `.env.` prefix ON PURPOSE: `.gitignore`'s `.env.*` glob is the only rule keeping
# the generated passwords uncommittable, and jumpbox-run.sh excludes `.env*` from the tar it ships.

# state_file — the sink. A VARIABLE, so a second cluster (e2e-cross-cluster) or a container harness
# can have its own and never leak into the repo's.
state_file() { printf '%s' "${VKS_STATE_FILE:-${REPO_ROOT}/.env.state}"; }

# state_kubeconfig_server <kubeconfig> — the API server URL, computed from the FILE alone.
# `kubectl config view` PARSES the file; it never dials the API server and needs no RBAC — so this is
# usable inside load_env, on a torn-down cluster, and by a locked-down tenant.
state_kubeconfig_server() {
  [ -f "${1:-}" ] || return 1
  kubectl --kubeconfig "$1" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
}

# state_set KEY VALUE — write to the stamped sink, 0600 (it holds generated passwords).
state_set() {
  local f; f="$(state_file)"
  ( umask 077; set_env_var "$1" "$2" "$f" )
}

# state_stamp [--kind] — record WHICH CLUSTER this sink belongs to. Written once, by whoever creates
# the sink. `--kind` marks it as KinD-flow state, which is what makes `make kind-down`'s delete
# contract safe: it may only remove a sink it is sure it created.
state_stamp() {
  local is_kind=0; [ "${1:-}" = "--kind" ] && is_kind=1
  local kc="${KUBECONFIG:-}" srv=""
  [ -n "$kc" ] && srv="$(state_kubeconfig_server "$kc" || true)"
  state_set VKS_STATE_KIND       "$is_kind"
  state_set VKS_STATE_KUBECONFIG "$kc"
  state_set VKS_STATE_SERVER     "${srv:-}"
  state_set VKS_STATE_CONTEXT    "$(kubectl --kubeconfig "$kc" config current-context 2>/dev/null || true)"
  state_set VKS_STATE_WRITTEN    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# state_archive <why> — RENAME the sink out of the way. Never `rm`: the passwords in it may still be
# the only copy for a cluster that is still running.
state_archive() {
  local f; f="$(state_file)"
  [ -f "$f" ] || return 0
  local dst
  dst="${f}.stale-$(date -u +%Y%m%d-%H%M%S)"
  mv "$f" "$dst"
  log_warn "state: ${1:-mismatch} — archived $(basename "$f") -> $(basename "$dst") (NOT deleted: it may hold the only copy of a live cluster's generated passwords)"
}

# state_check — decide, BEFORE sourcing, whether this sink belongs to the cluster we are talking to.
# Returns 0 = source it, 1 = do not source it.
#
# Only fires when the CALLER explicitly selected a KUBECONFIG. Without an explicit selection there is
# nothing to contradict: the overlay IS how we learn which cluster to talk to.
state_check() {
  local f; f="$(state_file)"
  [ -f "$f" ] || return 1

  local stamped_server
  stamped_server="$(grep -m1 '^VKS_STATE_SERVER=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')"

  if [ -z "$stamped_server" ]; then
    log_warn "state: $(basename "$f") is UNSTAMPED (legacy .env.kind, a jumpbox file, or hand-written)."
    log_warn "  Sourcing it anyway — refusing would destroy the only copy of the generated passwords."
    log_warn "  Run 'make state-stamp' once a cluster is up to make it self-identifying."
    return 0
  fi

  # An explicit caller selection is the ONLY thing that can contradict the stamp.
  [ -n "${_VKS_EXPLICIT_KUBECONFIG:-}" ] || return 0

  local want; want="$(state_kubeconfig_server "$_VKS_EXPLICIT_KUBECONFIG" || true)"
  [ -n "$want" ] || return 0                 # cannot tell -> do not guess
  [ "$want" = "$stamped_server" ] && return 0

  log_error "state: $(basename "$f") was written for a DIFFERENT cluster."
  log_error "    stamped for : ${stamped_server}"
  log_error "    you selected: ${want}  (KUBECONFIG=${_VKS_EXPLICIT_KUBECONFIG})"
  log_error "  NOT sourcing it — its LB IPs, CA paths and passwords belong to the other cluster, and a"
  log_error "  stale value here is indistinguishable from a deliberate override."
  log_error "  Leaving the file ALONE. Inspect it with 'make state-show'."
  # DELIBERATELY NOT state_archive HERE. state_check runs inside load_env, i.e. on EVERY script,
  # including read-only ones. Archiving from a READ path means a single
  #     KUBECONFIG=/tmp/other make creds-show
  # RENAMES the operator's sink — and the next command against the ORIGINAL cluster then finds no
  # overlay and silently falls back to .env.example defaults (LB IPs, CA paths, passwords all gone),
  # while `.env.state.stale-*` files pile up. Declining to source is already sufficient; the rename
  # bought nothing and cost the operator their state. Archiving belongs on a WRITE path only
  # (state_claim_kind, below), where we are about to overwrite the file anyway.
  return 1
}

# state_claim_kind — called by the KinD flow BEFORE its first state_set.
#
# THE BUG THIS EXISTS TO KILL: 05-kind-up.sh used to upsert its values into WHATEVER sink was there
# and then state_stamp --kind it. On a box where a real lab had written the sink, that re-stamped the
# LAB's state as KinD state — and `make kind-down` (which BOTH lab runbooks tell the operator to run
# at Step 0) then deleted it, taking the lab's discovered state and its generated passwords with it.
# The archive-never-delete promise never got a chance to fire, because nothing checked ownership on
# the WRITE path; state_check only guards the READ path, and only when the caller set KUBECONFIG.
#
# So: the KinD flow writes into a sink IT created, or into a fresh one. Never into someone else's.
state_claim_kind() {
  local f; f="$(state_file)"
  [ -f "$f" ] || return 0

  local kind srv
  kind="$(grep -m1 '^VKS_STATE_KIND='   "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  srv="$( grep -m1 '^VKS_STATE_SERVER=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  [ "${kind:-0}" = "1" ] && return 0        # ours: a re-run of the KinD flow. Reuse it.

  # UNSET everything the foreign sink exported into THIS process first. load_env has already sourced
  # it, so without this the "generate the password only if unset" logic in 05-kind-up.sh would
  # silently REUSE a real lab's HARBOR_PASSWORD for the throwaway KinD Harbor. The key list is DERIVED
  # from the file — not a hardcoded list that rots the moment someone publishes a new value.
  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case "$k" in VKS_STATE_*) ;; *) unset "$k" ;; esac
  done < <(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$f")

  state_archive "the KinD flow will NOT write into a sink it did not create (this one is stamped for ${srv:-<unstamped>})"
}

# state_show — what is in the sink, and WHOSE it is. The cue the rename would have destroyed
# ("this file is foreign state") now lives INSIDE the file, as provenance.
state_show() {
  local f; f="$(state_file)"
  if [ ! -f "$f" ]; then
    log_info "state: no overlay ($(basename "$f") does not exist)"
    return 0
  fi
  local srv ctx ts kind
  srv="$(grep -m1 '^VKS_STATE_SERVER='     "$f" | cut -d= -f2-)"
  ctx="$(grep -m1 '^VKS_STATE_CONTEXT='    "$f" | cut -d= -f2-)"
  ts="$( grep -m1 '^VKS_STATE_WRITTEN='    "$f" | cut -d= -f2-)"
  kind="$(grep -m1 '^VKS_STATE_KIND='      "$f" | cut -d= -f2-)"
  if [ -z "${srv:-}" ]; then
    log_warn "state: $(basename "$f") is UNSTAMPED — it does not say which cluster it belongs to."
  else
    log_info "state: $(basename "$f") was written for ${ctx:-<no context>} (${srv}) at ${ts:-<no ts>}"
    if [ "${kind:-0}" = "1" ]; then
      log_info "  written by the KinD flow — 'make kind-down' may remove it"
    else
      log_warn "  NOT KinD state — 'make kind-down' will NOT touch it"
    fi
  fi
  grep -vE '^(VKS_STATE_|#|$)' "$f" | sed 's/\(PASSWORD\|TOKEN\|SECRET\)=.*/\1=<redacted>/' | sed 's/^/    /'
}
