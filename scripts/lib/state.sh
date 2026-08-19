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

# state_unset KEY — remove ONE key from the stamped sink.
#
# THIS IS NOT A BREACH OF THE never-`rm` PROMISE. That promise (see state_archive below) is about the
# FILE: the passwords in it may be the only copy for a cluster that is still running, so the sink is
# RENAMED, never deleted. This removes a single value that a step is SUPERSEDING right now, in the
# same breath as writing its replacement — the old value is dead by construction.
#
# WHY IT HAS TO EXIST (measured 2026-08-17, matrix row 1, scenario-1 §9). `04-install-harbor-service.sh`
# publishes HARBOR_USERNAME/HARBOR_PASSWORD to the overlay at :144-145. Step 9's `make harbor-robot`
# then writes the ROBOT identity to `.env`. `load_env` sources the overlay LAST, so the robot identity
# could never take effect: the run died on `assert_env_effective` with rc=1, having created the robot.
# Writing a replacement into a LOWER-precedence file is not a publish — it is a no-op with a log line.
state_unset() {
  local key="$1" f; f="$(state_file)"
  [ -f "$f" ] || return 0
  # B142 — DO NOT EDIT A SINK THIS PROCESS NEVER SOURCED. `load_env` publishes `_VKS_STATE_SOURCED`
  # from inside its own `if state_check` branch, so it answers exactly the question a WRITE path has:
  # "could this sink's pin possibly be shadowing me?" If it was not sourced, the pin is inert and
  # clearing it accomplishes nothing — while the file may belong to ANOTHER cluster. Measured in the
  # idea round: with no explicit KUBECONFIG, three keys were stripped from a sink stamped for a
  # different cluster and `state_check` never refused, because its early return is a READ-path
  # concession (`[ -n "$_VKS_EXPLICIT_KUBECONFIG" ] || return 0`) with no meaning here.
  # ⚠️ RETURN 0, NOT 1. This is not a failure: the caller's INTENT — "make sure this key is not
  # pinned" — is already satisfied, because an unsourced pin cannot shadow. Returning 1 would abort
  # `env_publish`'s pair under `set -e`, which is the half-written-credential defect this file's own
  # header records.
  # ⚠️ UNSET means load_env never ran; PROCEED. Many callers legitimately never call it, and a
  # fail-closed default would break every one of them.
  if [ "${_VKS_STATE_SOURCED-1}" = "0" ]; then
    log_warn "state_unset ${key}: the sink was NOT sourced in this process, so its pin cannot be"
    log_warn "  shadowing anything — leaving $(basename "$f") untouched (it may belong to another cluster)."
    return 0
  fi
  grep -qE "^${key}=" "$f" 2>/dev/null || return 0
  # 0600 is preserved deliberately: a fresh file created by the redirect would take the umask, and
  # this sink holds generated credentials. Write beside it, then move over it.
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  # `grep -v` EXITS 1 WHEN IT EMITS NOTHING, and that is the CORRECT outcome here: the sink held only
  # this key, so removing it legitimately empties the file. The original `|| { rm; return 1; }` read
  # that as failure -- so the key was NOT removed, NOTHING was logged, and rc=1 propagated. Measured
  # 2026-08-17: 2-key overlay -> rc 0, removed; 1-key overlay -> rc 1, key STILL PRESENT, silent.
  # It is the SECOND key of a pair that lands there (04-install-harbor-service.sh:144-145 publishes
  # exactly HARBOR_USERNAME + HARBOR_PASSWORD), so `make harbor-robot` produced the robot USERNAME
  # with the ADMIN PASSWORD -- verbatim the mismatched pair env_publish exists to prevent, and a 401
  # that reads like a wrong password. This is `set_env_var`'s documented bug 2 (os.sh:819-822),
  # re-introduced by a function written after it.
  #
  # NOT `|| true` (which the review prescribed). rc 1 and rc 2 BOTH leave an EMPTY tmp -- measured --
  # so `|| true` would `mv` an empty file over a sink whose own header calls it "the only copy" of a
  # running cluster's credentials. Which failure does the >=2 arm actually cover? MEASURED, both:
  #   unreadable SINK   -> the early `grep -qE ... || return 0` above already returns 0, untouched.
  #                        The >=2 arm is NOT what protects that case.
  #   failed REWRITE    -> reachable (ENOSPC; reproduced with `ulimit -f 0`). grep cannot write $tmp,
  #                        and this arm is what stops a TRUNCATED tmp being moved over the sink.
  # So the arm is load-bearing for a write failure, not a read failure -- and only <=1 is benign.
  local g=0
  ( umask 077; grep -vE "^${key}=" "$f" > "$tmp" ) || g=$?
  if [ "$g" -ge 2 ]; then rm -f "$tmp"; return 1; fi
  # NOT `chmod --reference="$f"`: this is the ONE place that creates a fresh inode (`mv` below), i.e.
  # the one chance to repair a loose mode — and copying the sink's CURRENT mode threw that away.
  # MEASURED: a 0644 sink went through state_unset and came out 0644, on a brand-new file. This
  # function's own header already declares the sink "0600 (it holds generated passwords)", so the
  # reference added nothing and could only carry a defect forward.
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
  log_info "state: removed ${key} from $(basename "$f") — superseded by a value just written to .env"
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
  # No `tr`: this library is sourced by 00-install-prereqs.sh itself, i.e. BEFORE coreutils is
  # installed, and photon:5.0 has no `tr`. ${x//\"/} is a bash builtin and needs nothing.
  stamped_server="$(grep -m1 '^VKS_STATE_SERVER=' "$f" 2>/dev/null | cut -d= -f2- || true)"
  stamped_server="${stamped_server//\"/}"

  if [ -z "$stamped_server" ]; then
    # B120. This used to be THREE lines naming three causes and prescribing `make state-stamp`.
    # Every part of it was measured FALSE, and the prescription was ACTIVELY HARMFUL:
    #   - the causes ("legacy .env.kind, a jumpbox file, or hand-written") are all wrong on the
    #     real-lab path, where 30-vks-login.sh:447 writes the sink at Step 3;
    #   - TAKING the advice BREAKS the walk. scenario-1 legitimately runs under TWO API servers
    #     (Supervisor at §3, then the guest via 27-use-guest-kubeconfig.sh), so stamping for one
    #     arms state_check to REFUSE the other -- from Step 6 on, HARBOR_USERNAME/HARBOR_PASSWORD/
    #     ARGOCD_KUBECONFIG/GITEA_LB_IP/INGRESS_LB_IP all vanish. A WARN becomes a hard red.
    #   - it LAUNDERS the one hazard the warning exists for: stamping silences the alarm while
    #     KEEPING a stale value from a lab that no longer exists (and flips creds.sh's banner
    #     from STORED to DISCOVERED over it);
    #   - "once a cluster is up" is false anyway -- state_stamp only PARSES a kubeconfig, never
    #     dials, so on an unresolvable path it writes an empty server, exits 0, and still warns.
    # See BACKLOG B86, which refuted making the real-lab path call state_stamp, with the A/B table.
    # Warning ONCE PER PROCESS was also measured and is a NO-OP (35 -> 35): every one of the 35
    # warnings in a scenario-1 walk already comes from a distinct script process.
    # This keeps the ONE true statement, in the reader's own vocabulary, and prescribes nothing.
    log_warn "state: $(basename "$f") does not record which cluster it belongs to — using it as-is."
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
  # `|| true` IS LOAD-BEARING. Under `set -o pipefail` (every script here), a grep that finds NOTHING
  # returns 1, so the whole pipeline returns 1, so the ASSIGNMENT fails, so `set -e` kills the caller.
  # An UNSTAMPED sink has neither key — which is precisely the case this function exists to handle —
  # so `make kind-up` died at exactly this line, right after "writing kubeconfig", with no message of
  # its own. state_check has the same shape and survives ONLY because it is called inside `if ...`,
  # where set -e is suspended; state_claim_kind is called as a bare statement, so it dies.
  kind="$(grep -m1 '^VKS_STATE_KIND='   "$f" 2>/dev/null | cut -d= -f2- || true)"   # no `tr` — see state_check
  srv="$( grep -m1 '^VKS_STATE_SERVER=' "$f" 2>/dev/null | cut -d= -f2- || true)"
  kind="${kind//\"/}"; srv="${srv//\"/}"
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
  # ⚠️ REDACTION IS BY NAME PATTERN, so the pattern IS the control — a key whose name is not in
  # this list is printed IN FULL. MEASURED 2026-08-17 (B76 round, finding F7) against the old
  # three-word list: HARBOR_PASSWORD and ARGOCD_TOKEN redacted correctly, while GPG_PASSPHRASE,
  # GITHUB_PAT and TLS_KEY were printed VERBATIM. It was adequate only by accident — every
  # credential key in .env.example today happens to end in _PASSWORD or _TOKEN — and the rot is
  # PRESCRIBED BY OUR OWN CONVENTIONS, which mandate GPG_PASSPHRASE (not _PASSWORD) and keep
  # GITHUB_PAT deliberately. The overlay really does hold generated secrets (05-kind-up.sh:130-142
  # state_set HARBOR_PASSWORD/GITEA_ADMIN_PASSWORD/ARGOCD_ADMIN_PASSWORD "$(gen_password)"), so the
  # day either name lands here this printed them.
  #
  # The anchor is `<WORD>=`, which is what keeps it from OVER-redacting: ARGOCD_PASSWORD_WAIT_SECONDS
  # ends in `_WAIT_SECONDS=`, and SSH_KEY_FILE ends in `_FILE=`, so neither matches. Both directions
  # are pinned by test-state-overlay.sh — widen this list only together with those cases.
  grep -vE '^(VKS_STATE_|#|$)' "$f" \
    | sed 's/\(PASSWORD\|PASSPHRASE\|TOKEN\|SECRET\|PAT\|KEY\|CRED\)=.*/\1=<redacted>/' \
    | sed 's/^/    /'
}
