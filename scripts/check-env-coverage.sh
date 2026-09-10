#!/usr/bin/env bash
# check-env-coverage.sh — every operator-settable variable the scripts READ must be documented in
# .env.example. A gate, not a convention.
#
# WHY: `.env.example` is this repo's BLOCKING source of truth for every operator-tunable value —
# and it silently drifted anyway. 5 of the 8 variables `71-argocd-register-guest.sh` reads
# (ARGOCD_KUBECONFIG, GUEST_KUBECONFIG, GUEST_API_SERVER, ARGOCD_DEST_CLUSTER_NAME,
# ARGOCD_REGISTER_INSECURE, ...) were entirely undocumented, so the cross-cluster ArgoCD path was
# IMPOSSIBLE to configure from the docs — you had to read the script. Nothing caught it, because
# "keep .env.example complete" was a rule and not a check.
#
# WHAT COUNTS as operator-settable: a variable read with a default — `${VAR:-...}` or `: "${VAR:=...}"`
# — or asserted as required (`: "${VAR:?}"`). Those are INPUTS. Internal locals and values the repo
# DISCOVERS and publishes itself (state_set -> .env.state) are not, and are listed below explicitly
# so the exemption is auditable rather than accidental.
#   VKS_VIP_STILL — the OUT-PARAMETER of `vks_wait_vip_release` (lib/os.sh): the function sets it,
#     97-vks-cluster-delete.sh and 98-uninstall-all.sh read it to render their timeout message. It is
#     a return value carried in a variable because the function's stdout is the operator's log, not
#     its result. An operator setting it could only corrupt that message, never configure anything.
#   VKS_SUDO_PROBED — set by lib/os.sh so its `sudo -n true` capability probe runs ONCE per process
#     tree instead of once per sourced script. Internal by construction: an operator setting it would
#     only disable a diagnostic, never configure anything.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

ENV_FILE="${REPO_ROOT}/.env.example"
[ -f "$ENV_FILE" ] || die "no .env.example"

# Values the repo DISCOVERS/GENERATES and writes to .env.state itself — an operator never sets them.
# (They are still described in .env.example prose; they just need no `VAR=` line.)
PUBLISHED='HARBOR_URL|HARBOR_PASSWORD|HARBOR_CA_FILE|HARBOR_INSECURE|GITEA_ADMIN_PASSWORD|GITEA_CI_PASSWORD|GITEA_CI_TOKEN|ARGOCD_LB_IP|ARGOCD_INSECURE|ARGOCD_DEST_SERVER|INGRESS_LB_IP|INGRESS_CONTROLLER|KUBECONFIG|VKS_AUTH_METHOD|VKS_CONTEXT|ISTIO_GATEWAY_REF|ISTIO_DISCOVERED_VERSION|WEBHOOK_TOKEN'
# Shell/library internals and CI-only knobs — never operator-facing.
# APP_* (except the genuinely operator-set APP_BRANCH/APP_REPLICAS/APP_INTERNAL_PORT/APP_DEV_PORT/
# APP_MESSAGE/APP_VERSION/APP_COMMIT/APP_LOCAL_PORT) are DERIVED per app by app_export()
# (scripts/lib/apps.sh) from apps/registry.tsv — they are not operator-settable, and putting
# them in .env.example would be the CLOBBER bug: load_env's `set -a` would export a single
# global value that overwrites the loop's per-app export, deploying every app as the first one.
# BUNDLE_HOST_ARCH / BUNDLE_CRANE_VER / BUNDLE_MIRROR_ARCH — NOT operator-settable. They are STAMPED
# INTO THE BUNDLE by 11-bundle.sh (bundle/tools/ARCH) and sourced back by 20-bundle-load.sh on the
# air-gap box, so it can refuse an arch-mismatched bundle instead of dying with `Exec format error`
# after the carry. They are facts ABOUT a bundle, not knobs — putting them in .env.example would invite
# an operator to "set" them, which is meaningless.
# CREDS_TOKEN — set ONLY by scripts/test-creds-show.sh, so the gate has a stable, machine-checkable
# provenance token to key on instead of grepping English prose. It is NOT an operator knob: a human never
# sets it, and creds-show hides the token unless it is on. A test's needs do not belong in .env.example.
# VC_TOKEN_FILE / VC_CURL_CFG / VC_HDR_FILE / VC_CODE_FILE — mktemp paths for the vCenter session's credential
# and token files (scripts/lib/vcenter.sh). They exist so the password and session id reach curl
# through FILES rather than argv; an operator overriding them could only move a secret somewhere
# less safe. vc_last_code() reads that file. SVC_STATUS is a caller-local.
# GATEWAY_IMAGE_FIXTURE — set ONLY by scripts/test-gateway-image.sh, so 96-verify-gateway-image.sh's
# classifier can be RED/GREEN-proven against fixture JSON instead of a ~30-minute live e2e. It is NOT
# an operator knob: a human never sets it, and setting it would make the gate read files instead of
# the cluster. Same category as CREDS_TOKEN above — a test's needs do not belong in .env.example.
# SHELL and ZDOTDIR belong with PATH/HOME/PWD/IFS below: the OS sets them at login, they are read
# (never written) by shell_rc_file/shell_activate_line in lib/os.sh so `make shell-init` can edit the
# RIGHT rc file, and documenting them would be actively HARMFUL — load_env sources .env.example with
# `set -a`, so an uncommented SHELL= there would be EXPORTED and override the operator's real shell,
# making shell-init edit a file they never read. See rules: the .env.example clobber class.
# SERVICE / PACKAGE — POSITIONAL ARGUMENTS with an env fallback, not configuration, and documenting
# them would ARM A SILENT DESTRUCTIVE DEFAULT. All three uninstall/deregister/unwedge scripts read
# `${1:-${SERVICE:-}}` AFTER load_env. PROVEN both directions 2026-08-12: with SERVICE exported,
#   SERVICE=harbor bash -c 'S="${1:-${SERVICE:-}}"; echo [$S]' _ ""   ->  [harbor]
#   bash          -c 'S="${1:-${SERVICE:-}}"; echo [$S]' _ ""         ->  []        <- today
# `make uninstall-supervisor-service CONFIRM=yes` with the arg omitted passes an EMPTY "$(SERVICE)"
# as $1, and `:-` treats empty as unset — so an uncommented .env value would be picked up and the
# script would uninstall THAT service, "for every tenant on that Supervisor" (its own help text),
# with _list_and_die unreachable and the CONFIRM guard already satisfied. Today the fallthrough
# lands on empty and the script prints the list and refuses. They ARE documented — in `make help`
# (Makefile:413/425/429/433), which is where a positional argument belongs.
# VKS_LAB_STATE_DIR — NOT operator-facing, and deliberately NOT in .env.example. It is the LAST
# entry of supervisor_kubeconfig_candidates(): a maintainer whose Supervisor kubeconfig is managed
# by a separate lab-provisioning repo can point at its state dir instead of copying the file. It is
# existence-guarded, so for an END USER — who has ONLY this repo (CLAUDE.md RULE ZERO-B) — it is a
# silent no-op. Documenting it in .env.example would put a foreign repo's layout into the end user's
# config surface and invite them to 'set' something that does not exist for them.
# VKS_STATE_KIND — DISCOVERED state, not a knob. `state_stamp --kind` (lib/state.sh:124-127) writes it
# into .env.state and ONLY 05-kind-up.sh calls it, so a real lab never stamps it and it correctly
# defaults to 0. lib/harbor.sh reads it to decide whether the KinD-specific 401 diagnosis ("a Harbor
# DB surviving an earlier local install -> make kind-down") applies at all; on a real lab that advice
# sends the operator to destroy a cluster that is not there. Documenting it in .env.example would
# invite an operator to SET it, which is exactly wrong: setting it to 1 on a lab restores the bad
# advice, and setting it to 0 on KinD withholds the good advice. (B209)
# ARGOCD_SERVER_SOURCE — DISCOVERED provenance, not a knob. 09-argocd-address.sh state_sets it when
# it publishes an address it resolved itself, so a LATER run may correct that value while still never
# clobbering an address a TENANT was granted (which carries no marker). Setting it by hand would only
# let you defeat that protection, which is the opposite of configuring anything.
# HARBOR_FIRST_INSTALL / HARBOR_SETTLE_FRESH — COMPUTED, not knobs. 06-install-harbor.sh derives
# HARBOR_FIRST_INSTALL from `helm status` (is this Harbor release already there?) and passes it to
# harbor_credential_settle as HARBOR_SETTLE_FRESH, which decides only whether a 401 is worth
# RETRYING: a FRESH Harbor may answer /health before its admin row is seeded, while a PRE-EXISTING
# one answers 401 authoritatively on the first try and retrying just burns the deadline. Setting
# either by hand can only make the diagnosis wrong in one direction or the other — it cannot
# configure anything. The operator-facing knobs are HARBOR_SETTLE_TRIES/INTERVAL, which ARE in
# .env.example.
INTERNAL='ARGOCD_ENDPOINT_HTTP|ARGOCD_ENDPOINT_RC|HARBOR_FIRST_INSTALL|HARBOR_SETTLE_FRESH|ARGOCD_SERVER_SOURCE|PKG_VER_RESOLVED|PKG_NS_RESOLVED|VKS_SUDO_PROBED|BUILDER_IMAGE_TAG_DEFAULT|VKS_STATE_KIND|VKS_LAB_STATE_DIR|SERVICE|PACKAGE|APP_NAME|APP_LANG|APP_SRC|APP_DEPLOY_DIR|APP_HOST|APP_TEST_TASK|APP_NAMESPACE|APP_GIT_REPO|APP_DEPLOY_REPO|APP_IMAGE|APP_BUILDER_IMAGE|APP_RUNTIME_IMAGE|APP_HOSTS_BLOCK|APP_NS_BLOCK|PROBE_HOST|PROBE_APP|APP_ING_ALLOWLIST|REPO_ROOT|SCRIPT_DIR|BASH_SOURCE|PATH|HOME|PWD|IFS|SHELL|ZDOTDIR|SSL_CERT_FILE|TMPDIR|LC_ALL|HARBOR_PW|HARBOR_SVC|HARBOR_TMP|HARBOR_CURL_CFG|HARBOR_CODE_FILE|HARBOR_TMP_DIR|HARBOR_RELEASE|HARBOR_TLS_SECRET|HARBOR_TLS_VERIFY|HARBOR_INSECURE_BOOL|HARBOR_PROVISIONAL_EXTERNAL_URL|HARBOR_ROBOT_OUT|ARGOCD_SVC|ARGOCD_NS|ARGOCD_API|GUEST_API|GITEA_CLONE_URL|GITEA_ARGOCD_URL|ARGOCD_DEST_KEY|ARGOCD_DEST_VALUE|KIND_KUBECONFIG|KIND_CLUSTER_REMOVED|ARGOCD_MANAGER_NS|ARGOCD_MANIFEST_VERSION|ISTIO_ROUTE_API_EFFECTIVE|PLATFORM_ISTIO_NAMESPACE|PLATFORM_ISTIO_RELEASE|PLATFORM_ISTIOD_NAMESPACE|PROBE_IMAGE|REGISTRY_LOCK_FILE|MANIFEST_DIR|DOCKER_HOST|DOCKER_CONFIG|XDG_RUNTIME_DIR|ENGINE_SUDO_COUNT_FILE|CERTD|JUMPBOX_[A-Z_]*|E2E_[A-Z_]*|CI|GITHUB_[A-Z_]*|READY_TIMEOUT_SECONDS|POLL_INTERVAL_SECONDS|CURL_MAX_TIME_SECONDS|MIRROR_RETRIES|MIRROR_FORCE_PULL|NOTIFY|VCF_[A-Z_]*|PSA_LEVEL_[A-Z_]*|DISPLAY|WAYLAND_DISPLAY|DRY_RUN|GW_IP|TOKEN|RED_TEST_SKIP_PRECHECK|CREDS_TOKEN|GATEWAY_IMAGE_FIXTURE|PODIMAGES_FIXTURE|PODIMAGES_MATCHED_VIA|BUNDLE_HOST_ARCH|BUNDLE_CRANE_VER|BUNDLE_MIRROR_ARCH|VC_TOKEN_FILE|VC_CURL_CFG|VC_HDR_FILE|VC_CODE_FILE|SVC_STATUS|CA_STATUS_CHECKED|CA_STATUS_MATCHED|CA_STATUS_STRICT|PF_PID|PF_GEN|PF_DEATHS|PF_LAST_BODY|PF_RESTARTS_BLOCKED|TREE_STABILITY_ID|VKS_VIP_STILL|MIRROR_REGISTRY_HOSTS|HOSTSCAN_ALLOW'

# SCOPE: every script under scripts/ and scripts/lib/, MINUS the harness/gate classes in the `case`.
#
# It used to ENUMERATE: the glob `[0-9][0-9]-*.sh` plus FOUR hand-typed basenames. Those four names
# were the rot surface — every non-numeric operator script added after they were typed was invisible
# to this gate, silently, forever. Measured 2026-08-12: that hid 16 files, including the WHOLE
# `##@ Supervisor platform` group (12 documented targets), and with them 9 undocumented knobs.
#
# A Makefile-recipe-derived list was designed and REFUTED (idea-round, 2026-08-12): globbing the
# directory is a strict SUPERSET of it (84 files vs 83) and carries none of its four measured blind
# spots — recipe COMMENTS harvested as invocations, `$(MAKE)` recursion, a script in a SUBDIRECTORY,
# and the group exemptions it would not inherit. Reachability also stops being a question a parser
# has to answer: walk-doc.sh is invoked through the WALKBOX_DRIVER env var, which no static Makefile
# analysis can ever see.
#
# PKG_VER_RESOLVED / PKG_NS_RESOLVED — DERIVED in 43-install-istio-package.sh and passed to
# vks-package.sh so the air-gap probe and the install judge the SAME Package (B484 F1/F2).
# The operator's knobs for both already exist and ARE documented: ISTIO_PACKAGE_VERSION and
# VKS_PACKAGE_NAMESPACE. Documenting the resolved values would invite someone to set them,
# which is exactly the two-sources-of-truth this pair exists to remove.
#
# CA_STATUS_* — internal to 29-ca-status.sh. CHECKED/MATCHED are the report's own DENOMINATOR,
# set for its caller (lab-preflight) so "checked nothing" and "checked three, all fine" cannot
# print the same sentence. STRICT is a SEVERITY switch owned by the `preflight` make target
# (`preflight: export CA_STATUS_STRICT = 1`), not something an operator sets: a missing Harbor CA
# is a warning for bare `lab-preflight` and fatal for the preflight that gates install-all.
# ARGOCD_ENDPOINT_HTTP / ARGOCD_ENDPOINT_RC — argocd_endpoint_probe's OUTPUT, set BY the probe for
# its caller to read; the operator-facing knob is the diag FILE (ARGOCD_ENDPOINT_DIAG), which IS
# documented in .env.example. Same class as PKG_VER_RESOLVED: documenting a value the code assigns
# would invite someone to set it, and setting it could only make the diagnosis lie -- a hand-set
# http= would let the poll declare a dead endpoint "answering", which is the exact false-green the
# probe exists to prevent.
# TREE_STABILITY_ID — tree-stability.sh keys its snapshot on the invoking make's PID so two runs in
# one tree cannot overwrite each other; the variable exists ONLY so the gate's own RED-proof can pin
# a stable key instead of racing PPIDs. There is nothing here for an operator to set, and putting it
# in .env.example would invite someone to.
# Documenting three internal counters in .env.example would be noise aimed at the operator.
# PODIMAGES_FIXTURE — the same class as GATEWAY_IMAGE_FIXTURE beside it: a SELF-TEST hook that makes
# lib/podimages.sh read pod JSON from a directory instead of a cluster, so 97-verify-workload-images
# is RED/GREEN-provable OFFLINE. Documenting it would invite an operator to set it, and setting it
# makes a LIVE provenance gate read fixtures instead of the cluster — i.e. it would turn the gate
# into exactly the vacuous pass it exists to prevent.
# MIRROR_REGISTRY_HOSTS / HOSTSCAN_ALLOW — internal CONSTANTS, single-sourced in lib/mirror.sh and
# lib/hostscan.sh. Not operator-settable, and documenting them would be actively harmful: the first
# is the host alternation that BOTH the mirror and the install-time rewrite key on, so an operator
# who narrowed it in .env would silently un-mirror a host while the rewrite still pointed at Harbor
# (the cgr.dev incident's exact shape). The second is an allowlist of hosts we have DECIDED not to
# mirror; every entry is a claim with a measurement behind it, so it must cost a code edit rather
# than an env var that silences the gate with no recorded reason.
# Still excluded (genuinely not operator flow — their knobs are harness-internal, and folding them
# in would bury the real gaps in noise): the e2e/test harnesses, the jump-box/bootstrap harnesses,
# the lab-walk harness (walk-*/walkbox*), and the CI gates themselves.
FLOW_SCRIPTS=()
for f in "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    90-e2e-*|e2e-*|test-*|jumpbox-*|bootstrap-*|check-*|walk-*|walkbox*|lint.sh|validate.sh) continue ;;
  esac
  FLOW_SCRIPTS+=("$f")
done
# Print the DENOMINATOR: a gate that cannot say how much it looked at cannot be trusted.
log_info "check-env-coverage: scanning ${#FLOW_SCRIPTS[@]} operator-flow scripts"
# FLOOR. The denominator alone does not protect against a SILENT SHRINK: a glob that stops matching
# or a `case` someone widens leaves a smaller, quieter green that reads exactly like the old
# enumerated list did. MEASURED 2026-08-12: 82. Raise this when the tree legitimately grows.
if [ "${#FLOW_SCRIPTS[@]}" -lt 80 ]; then
  log_error "check-env-coverage: only ${#FLOW_SCRIPTS[@]} scripts matched (floor 80) — the SCOPE broke."
  log_error "    A shrunk scan is a quieter green, not a pass. Fix the glob or the case above."
  exit 1
fi

vars="$(grep -rhoE '\$\{[A-Z][A-Z0-9_]{2,}:[-?=]|: *"\$\{[A-Z][A-Z0-9_]{2,}:[?=]' \
          "${FLOW_SCRIPTS[@]}" 2>/dev/null \
        | grep -oE '[A-Z][A-Z0-9_]{2,}' | sort -u)"

rc=0; missing=""
for v in $vars; do
  printf '%s' "$v" | grep -qE "^(${PUBLISHED})$" && continue
  printf '%s' "$v" | grep -qE "^(${INTERNAL})$" && continue
  # Documented = a `VAR=` line, commented or not.
  grep -qE "^#?[[:space:]]*${v}=" "$ENV_FILE" && continue
  log_error "operator-settable '${v}' is READ by the scripts but is NOT in .env.example"
  log_error "    read in: $(grep -rlE "\\\$\{${v}[:}]" "${REPO_ROOT}"/scripts/*.sh "${REPO_ROOT}"/scripts/lib/*.sh 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
  missing="${missing} ${v}"; rc=1
done


# ---------------------------------------------------------------------------
# PASS 2 — every operator-supplied value must state HOW IT IS ACQUIRED.
#
# The product of this repo is the three SCENARIOS (KinD / real-lab-install / real-lab-tenant), and a
# scenario is only "done" if an operator can actually RUN it. A value with no acquisition path is a
# hole in a scenario's critical path — the operator gets to that step and stops. Documenting the hole
# is not completing the scenario.
#
# So each documented value must carry one of:
#   how:/acquire:  an explicit acquisition command or `make` target
#   auto/discover  the repo discovers it (and writes .env.state) — the operator supplies nothing
#   choose/you set you invent it (a password for something WE install)
#   request        you must ask the platform admin (a legitimate, explicit end-state)
#   a real default the value ships with (nothing to obtain)
#
# The one that bit us: ARGOCD_KUBECONFIG shipped with "nothing creates this and the command is
# unknown" — which silently meant BOTH real-lab scenarios could not complete `make gitops`.
# ---------------------------------------------------------------------------
acq_rc=0
p2_examined=0    # THE ENFORCING PASS'S OWN counter — see the PASS 2b note below for why 2b's is not it
# Markers that answer "how does the operator get this?" — a command/target, or an explicit class:
#   how:/acquire:  a command or make target        auto/discover/generated  the repo supplies it
#   choose/you set/toggle/password  you invent it   request/ask  you must ask the platform admin
#   reserved/n/a   not used today
ACQ_MARKERS='how|acquire|auto|discover|generated|choose|you set|you choose|toggle|runtime|password|request|ask (your|the)|reserved|n/a|default'
while IFS= read -r line; do
  ln="${line%%:*}"; rest="${line#*:}"
  var="$(printf '%s' "$rest" | sed -E 's/^#?[[:space:]]*([A-Z][A-Z0-9_]+)=.*/\1/')"
  printf '%s' "$var" | grep -qE '^[A-Z][A-Z0-9_]{2,}$' || continue
  # an UNCOMMENTED line ships a real default -> nothing for the operator to obtain
  printf '%s' "$rest" | grep -qE '^[A-Z]' && continue
  p2_examined=$((p2_examined + 1))
  # Walk UPWARD from the var, taking ONLY its own CONTIGUOUS comment block (stop at the first
  # non-comment line). A wider window would pick up a NEIGHBOURING block's marker and the gate would
  # never fire — which is exactly what it did on its first version.
  blk="$(awk -v n="$ln" 'NR<n { if ($0 ~ /^#/) { b = b "\n" $0 } else { b = "" } } END { print b }' "$ENV_FILE" | tr '[:upper:]' '[:lower:]')"
  # HERESTRING, not `printf … | grep -q`. This file runs under `set -o pipefail`, and bash forks the
  # LHS of a pipe into a SUBSHELL — so `grep -q` exiting at its first match SIGPIPEs that subshell
  # (141), pipefail promotes it, the `&& continue` does not fire, and a variable whose marker IS
  # present gets reported as having NO acquisition path. A FALSE POSITIVE, in a gate, blaming
  # whichever PR happens to be in flight.
  # MEASURED 2026-08-12 on an UNCHANGED tree: idle 24-core 0/20, but `taskset -c 0` (the 2-vCPU CI
  # runner analogue) 5/25 = 20%. `blk` is why it is reachable here where other sites are not — it
  # accumulates the whole contiguous comment block above a variable, which in this 1400-line file
  # runs to hundreds of lines. A herestring is spooled to a temp file, so there is nothing to
  # SIGPIPE. (check-grep-q-pipe.sh does not catch this: it is scoped to FILE-READING producers.)
  grep -qE "$ACQ_MARKERS" <<< "$blk" && continue
  log_error ".env.example:${ln}: '${var}' is operator-supplied but states NO acquisition path."
  log_error "    Add 'how:'/'acquire:' (a command or make target), or mark it auto/discover/choose/request."
  log_error "    A value an operator cannot obtain is a HOLE in a scenario's critical path."
  acq_rc=1
done < <(grep -nE '^#[[:space:]]*[A-Z][A-Z0-9_]{2,}=' "$ENV_FILE")
[ "$acq_rc" -eq 0 ] || rc=1
# ⚠️ THE ENFORCING PASS NEEDS ITS OWN DENOMINATOR AND ITS OWN FLOOR. An implementation round proved
# why: PASS 2b below has a DIFFERENT slot-finder (awk) from this loop's (grep), so mutating THIS
# grep to match nothing left 2b happily printing "241 examined" while the pass that can actually
# flag examined ZERO — and the suite stayed 10/10 green. A denominator that belongs to a different
# loop does not merely fail to close the hole; it CAMOUFLAGES it behind a number that reads as this
# pass's proof of work. Measured, and it is strictly worse than having no denominator at all.
log_info "check-env-coverage PASS 2: ${p2_examined} commented slot(s) examined (enforcing)"
if [ "$p2_examined" -lt 150 ]; then
  log_error "check-env-coverage PASS 2: only ${p2_examined} slots examined (floor 150) — the ENFORCING pass went blind."
  log_error "    Its driving grep or the slot regex broke; a shrunk scan is a quieter green, not a pass."
  rc=1
fi

# ---------------------------------------------------------------------------------------------
# INTEGRITY: no SPLICED variable-slot line.
#
# A search-and-replace on this file that matches a SUBSTRING of another variable's name silently
# welds two blocks together. It really happened (PR #168): editing `KUBECONFIG=...` also matched
# the tail of `# GUEST_KUBECONFIG=...`, producing
#
#     # GUEST_# COMMENTED, and that is load-bearing. load_env sources this file with `set -a` ...
#
# — destroying GUEST_KUBECONFIG's declaration AND moving KUBECONFIG's into the GUEST block. Every
# gate stayed GREEN: the coverage check above only asks whether each NAME appears SOMEWHERE, and
# both still did — in each other's homes. Only a human reading the file could see it, and nobody
# reads .env.example top to bottom.
#
# The signature is unmistakable: an identifier immediately followed by '#' (no space, no '='),
# which prose never produces. Cheap, exact, and it would have caught the real defect.
splice_rc=0
while IFS=: read -r ln line; do
  log_error ".env.example:${ln}: SPLICED variable slot — '${line}'"
  log_error "    An identifier is welded to a comment ('NAME#...'), so a variable's declaration was"
  log_error "    destroyed by a substring-matching edit. Restore each variable's own '# NAME=value' slot."
  splice_rc=1
done < <(grep -nE '^#[[:space:]]*[A-Za-z][A-Za-z0-9_]*#' "$ENV_FILE" || true)
[ "$splice_rc" -eq 0 ] || rc=1

# ---------------------------------------------------------------------------------------------
# PASS 2b — SECTION-SCOPED WINDOW, REPORT-ONLY (B716 stage 1 of 3).
#
# WHAT IS WRONG WITH PASS 2 ABOVE, measured: its awk resets the block only on a NON-COMMENT line,
# and `.env.example` is an unbroken run of `#` lines — so a variable's "own block" absorbs its
# NEIGHBOURS'. Numbers, reproduced independently twice: 241 slots examined, 155 (64%) with a window
# >20 lines, 102 (42%) >50, **max 247**, and it flags **0**. Its own comment above says a wider
# window "would pick up a NEIGHBOURING block's marker and the gate would never fire". That is the
# state it is in.
#
# ⚠️ THE OBVIOUS FIX IS A MASS FALSE-RED AND IS NOT SHIPPED HERE. Also resetting on a slot line
# gives **57** flags — but MEASURED, **34 of them (60%) are documented by a GROUP HEADER that names
# them**, because this file's dominant idiom is one header above a RUN of slots. Severing every slot
# after the first from its header invents 34 false REDs, and the cheapest response to a false RED is
# to weaken the gate.
#
# THE WINDOW BELOW is: (a variable's own contiguous non-slot comments) PLUS (the block above the
# FIRST slot of the maximal run it belongs to). Measured: **23** flagged, and max window 247 -> 42.
# Including the slot LINE itself and honouring this file's own `<SET-IN-.env>` idiom (declared at
# `.env.example`'s head, used 20 times, and matched by NO existing marker) takes it to **21**.
#
# ⚠️ REPORT-ONLY, DELIBERATELY, AND IT MUST STAY THAT WAY UNTIL THE SURVIVORS ARE TRIAGED.
# `check-env-coverage` is a prerequisite of `static-check-fast`, which is a per-PR job and a
# `needs:` of `ci-pass` — so flipping this to enforcing would RED every PR, including the PRs that
# would document the survivors. Stage 2 triages them; stage 3 enforces at zero.
#
# ⚠️ AND "IT REGRESSED TO v1" IS WRONG — `.env.example` documents this as a KNOWN CONVENTION, in the
# scanned file, ending "if you want that to be more than a convention, earn it with a RED first"
# (grep -n 'earn it with a RED first'). This is that RED, earned in report-only form.
ACQ_MARKERS_REPORT="${ACQ_MARKERS}|set[- ]in|set[- ]it[- ]in"
pass2_examined=0; pass2_flagged=0; pass2_names=""
# ⚠️ IFS=$'\t', NOT IFS='\t' — the latter is a LITERAL backslash and a literal t, so `read` never
# splits, `flag` is empty, and the flagged count reads 0 no matter what the awk emitted. Measured:
# it printed "0 flagged" against a real 21, and the DENOMINATOR was still right (241), which is
# exactly what makes it dangerous — the number that would expose it looked healthy.
while IFS=$'\t' read -r ln var flag; do
  [ -n "${ln:-}" ] || continue
  pass2_examined=$((pass2_examined + 1))
  if [ "$flag" = FLAG ]; then
    pass2_flagged=$((pass2_flagged + 1)); pass2_names="${pass2_names} ${var}"
  fi
done < <(awk -v mk="$(printf '%s' "$ACQ_MARKERS_REPORT" | tr '[:upper:]' '[:lower:]')" '
  { line[NR] = $0 }
  function is_slot(s) { return s ~ /^#[[:space:]]*[A-Z][A-Z0-9_][A-Z0-9_]+=/ }
  function is_cmt(s)  { return s ~ /^#/ }
  END {
    # D2: THE CANONICAL SLOT IS THE **LAST** SLOT-SHAPED LINE FOR THAT NAME IN ITS COMMENT REGION.
    # An idea round measured that NINE lines here are PROSE that happens to be slot-shaped, e.g.
    #     # CAPACITY_PREFLIGHT=0 disables that check entirely. Set it only to ...
    # Each is (a) enumerated as a variable, inflating the denominator, and (b) a WALL truncating the
    # real slot window below the `# how:` above it. BUNDLE_TARBALL was flagged at its PROSE line
    # while its real slot was fine -- a phantom finding.
    #
    # THE OBVIOUS FIX IS REFUTED. "A real slot has nothing after the = ; prose has trailing words"
    # was MEASURED against ground truth: of 32 slot-shaped lines with trailing content, 23 are REAL
    # SLOTS and only 9 are prose -- trailing comments, values with spaces (PROBE_SLEEPS=0 1 2 4 8),
    # quoted values, and <SET-IN-.env -- minted by ...> placeholders. It would have silently dropped
    # 23 REAL variables from the denominator, including VKS_PASSWORD, VCENTER_PASSWORD, VKS_USERNAME,
    # SUPERVISOR_HOST and VKS_NAMESPACE -- the tenant-critical set RULE ZERO-B says arrives via .env
    # -- while the suite stayed 13/13 GREEN and the floor still cleared. Quieter, greener, blind.
    #
    # D2 needs NO guess about prose syntax: within one contiguous comment region, the LAST line
    # naming a variable is its slot; earlier ones are prose about it. Measured 9/9 prose caught,
    # 0 false positives, and the two LEGITIMATE HARBOR_PROBE_TIMEOUT_SECONDS slots both survive
    # because they sit in different regions.
    # PASS A -- mark the canonical line for every (region, name). Done ONCE, up front, because the
    # answer is needed in TWO places and computing it in only one is what made the first attempt a
    # half-fix: it removed the phantom ENUMERATION and left the WALL, so CAPACITY_PREFLIGHT was no
    # longer reported at its prose line and its real slot was STILL flagged, its `# how:` still
    # unreachable. MEASURED: 5 of the 7 expected removals did not happen.
    for (i = 1; i <= NR; i++) {
      if (!is_slot(line[i])) continue
      v = line[i]; sub(/^#[[:space:]]*/, "", v); sub(/=.*/, "", v)
      if (v !~ /^[A-Z][A-Z0-9_][A-Z0-9_]+$/) continue
      r0 = i; while (r0 - 1 >= 1 && is_cmt(line[r0 - 1])) r0--
      last[r0 SUBSEP v] = i
    }
    for (key in last) canonical[last[key]] = 1

    for (i = 1; i <= NR; i++) {
      if (!is_slot(line[i])) continue
      if (!(i in canonical)) continue           # this line is PROSE about a variable, not its slot
      v = line[i]; sub(/^#[[:space:]]*/, "", v); sub(/=.*/, "", v)
      if (v !~ /^[A-Z][A-Z0-9_][A-Z0-9_]+$/) continue
      w = tolower(line[i])                      # the SLOT LINE ITSELF: `<SET-IN-.env>` lives here
      for (k = i - 1; k >= 1; k--) {            # (a) own contiguous comments, PROSE INCLUDED
        if (!is_cmt(line[k]) || (k in canonical)) break
        w = w "\n" tolower(line[k])
      }
      rs = i                                    # (b) first slot of this maximal run
      while (rs - 1 >= 1 && (rs - 1) in canonical) rs--
      if (rs != i)
        for (k = rs - 1; k >= 1; k--) {
          if (!is_cmt(line[k]) || (k in canonical)) break
          w = w "\n" tolower(line[k])
        }
      printf "%d\t%s\t%s\n", i, v, (w ~ mk ? "ok" : "FLAG")
    }
  }' "$ENV_FILE")

# THE DENOMINATOR PASS 2 NEVER HAD. Until now the only count printed was PASS 1's, and the success
# sentence below made PASS 1's claim — so a PASS-2 loop that stopped iterating (a changed slot
# regex, a grep that matches nothing) was INDISTINGUISHABLE from a clean run.
log_info "check-env-coverage PASS 2b: ${pass2_examined} commented slot(s) examined, ${pass2_flagged} flagged (REPORT-ONLY, B716 stage 1)"
# FLOOR RAISED 200 -> 225 WITH THE D2 CHANGE. The old floor was set against 241; D2 correctly stops
# counting 9 PROSE lines as variables, so the honest expectation is ~232 and a 200 floor now leaves a
# 32-slot hole. An idea round measured that the REFUTED syntax discriminator dropped the denominator
# to 209 — which CLEARED the 200 floor while silently losing 23 REAL variables including
# VKS_PASSWORD and VCENTER_PASSWORD. A floor that a broken predicate can clear is not a floor.
if [ "$pass2_examined" -lt 225 ]; then
  log_error "check-env-coverage PASS 2b: only ${pass2_examined} slots examined — expected ~232 (D2: prose lines are not slots)."
  log_error "  Either the slot regex broke OR the awk itself failed — check stderr above; do not just"
  log_error "  lower this floor. If you deliberately TRIMMED .env.example, lower it and say so in the commit."
  rc=1
fi
# ── PASS 2c (B716 STAGE 3) — THE UN-GAMEABLE HALF, AND IT IS ENFORCING ───────────────────────────
# 2b asks "does this block contain a marker WORD". An idea round measured that its remedy is
# satisfiable by typing `default`, so enforcing it would buy a word, not documentation. 2c asks the
# question a word cannot answer: does the slot have ANY prose of its own (or a run-header above the
# run it belongs to)? MEASURED at the time it shipped: 2 offenders, both tunables of
# `make vks-cluster-delete` -- DESTRUCTIVE and Supervisor-only -- documented in the same change, so
# this ships at ZERO and stays there.
pass2c_offenders="$(awk '
  { line[NR] = $0 }
  function is_slot(s) { return s ~ /^#[[:space:]]*[A-Z][A-Z0-9_][A-Z0-9_]+=/ }
  function is_cmt(s)  { return s ~ /^#/ }
  # ⚠️ A BARE `#` IS NOT PROSE. The first version counted any comment line, so a single separator
  # `#` above a slot satisfied the gate -- and its RED-proof DID NOT FIRE (rc=0) because that is
  # exactly the shape the two real offenders had. Require at least one non-hash, non-space char.
  function has_text(s) { return s ~ /^#[[:space:]]*[^#[:space:]]/ }
  function nm(s,  v)  { v = s; sub(/^#[[:space:]]*/, "", v); sub(/=.*/, "", v); return v }
  END {
    for (i = 1; i <= NR; i++) {                       # D2 canonical, same rule as 2b
      if (!is_slot(line[i])) continue
      r0 = i; while (r0 - 1 >= 1 && is_cmt(line[r0 - 1])) r0--
      last[r0 SUBSEP nm(line[i])] = i
    }
    for (key in last) canonical[last[key]] = 1
    for (i = 1; i <= NR; i++) {
      if (!(i in canonical)) continue
      v = nm(line[i]); if (v !~ /^[A-Z][A-Z0-9_][A-Z0-9_]+$/) continue
      # ⚠️ DOCUMENTATION IS NOT ONLY ABOVE. This file also documents ON THE SLOT LINE (a trailing
      # comment after the value) and in CONTINUATION lines BELOW it -- e.g. VKS_SSO_DOMAIN and
      # VKS_CONTEXT_NAME. Counting only the lines ABOVE flagged both as undocumented: a FALSE RED
      # I measured and did not ship. Count all three positions.
      c = 0
      t = line[i]; sub(/^#[[:space:]]*[A-Z][A-Z0-9_]*=/, "", t)
      if (t ~ /#[[:space:]]*[^#[:space:]]/) c++                       # trailing comment on the slot
      for (k = i + 1; k <= NR && is_cmt(line[k]) && !(k in canonical); k++) if (has_text(line[k])) c++
      for (k = i - 1; k >= 1 && is_cmt(line[k]) && !(k in canonical); k--) if (has_text(line[k])) c++
      if (c == 0) {                                   # a RUN-HEADER above the run also documents it
        rs = i; while (rs - 1 >= 1 && (rs - 1) in canonical) rs--
        if (rs != i) for (k = rs - 1; k >= 1 && is_cmt(line[k]) && !(k in canonical); k--) if (has_text(line[k])) c++
      }
      if (c == 0) printf " %s", v
    }
  }' "$ENV_FILE")"
if [ -n "${pass2c_offenders// /}" ]; then
  log_error "check-env-coverage PASS 2c: slot(s) with NO prose of their own:${pass2c_offenders}"
  log_error "  A slot with an empty block tells the operator nothing at all — unlike a 2b flag, this"
  log_error "  cannot be answered by adding a marker word. Write what it is for, what to run, and"
  log_error "  what to expect. Do NOT silence it by moving an unrelated block above the slot."
  rc=1
fi

if [ "$pass2_flagged" -gt 0 ]; then
  log_warn "  no acquisition path stated (report-only — NOT failing the build):${pass2_names}"
  log_warn "  These are a VOCABULARY miss, not a coverage hole: an idea round measured that the"
  log_warn "  remedy is satisfiable by typing the word 'default', so this must NOT become enforcing."
  log_warn "  The un-gameable signal is an EMPTY own block -- see B716 stage 3."
fi

echo >&2
if [ "$rc" -eq 0 ]; then
  # ⚠️ "operator-settable" IS LOAD-BEARING and was dropped in an earlier reword, which made this
  # sentence FALSE: the scripts read ~475 distinct variables and ~192 of them (40%) have NO slot
  # here, deliberately — that is what the PUBLISHED/INTERNAL exemption lists are for.
  log_info "check-env-coverage: OK — every operator-settable variable the scripts read has a SLOT in .env.example (PASS 1),"
  log_info "  PASS 2 checked ${p2_examined} slots for an acquisition path (enforcing), and PASS 2b flagged ${pass2_flagged} of ${pass2_examined} (report-only)."
else
  if [ -z "${missing// /}" ]; then
    # rc=1 without a missing-variable list means a FLOOR or an integrity check fired, not PASS 1.
    # Saying ".env.example is INCOMPLETE — " with an empty list sends the reader to document a
    # variable that was never named. Pre-existing shape; the new floor added a fourth path into it.
    log_error "check-env-coverage: FAILED — see the specific error(s) above (no missing variables were reported)."
  else
  log_error "check-env-coverage: .env.example is INCOMPLETE —${missing}"
  log_error "  .env.example is the committed source of truth: a variable only the script knows about"
  log_error "  cannot be configured by an operator. Document it (with when-you-need-it + how-to-get-it),"
  log_error "  or — if it is internal/discovered — add it to the explicit exemption list in this script."
  fi
fi
exit "$rc"
