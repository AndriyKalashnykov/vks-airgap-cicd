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
INTERNAL='HARBOR_FIRST_INSTALL|HARBOR_SETTLE_FRESH|ARGOCD_SERVER_SOURCE|PKG_VER_RESOLVED|PKG_NS_RESOLVED|VKS_SUDO_PROBED|BUILDER_IMAGE_TAG_DEFAULT|VKS_STATE_KIND|VKS_LAB_STATE_DIR|SERVICE|PACKAGE|APP_NAME|APP_LANG|APP_SRC|APP_DEPLOY_DIR|APP_HOST|APP_TEST_TASK|APP_NAMESPACE|APP_GIT_REPO|APP_DEPLOY_REPO|APP_IMAGE|APP_BUILDER_IMAGE|APP_RUNTIME_IMAGE|APP_HOSTS_BLOCK|APP_NS_BLOCK|PROBE_HOST|PROBE_APP|APP_ING_ALLOWLIST|REPO_ROOT|SCRIPT_DIR|BASH_SOURCE|PATH|HOME|PWD|IFS|SHELL|ZDOTDIR|SSL_CERT_FILE|TMPDIR|LC_ALL|HARBOR_PW|HARBOR_SVC|HARBOR_TMP|HARBOR_CURL_CFG|HARBOR_CODE_FILE|HARBOR_TMP_DIR|HARBOR_RELEASE|HARBOR_TLS_SECRET|HARBOR_TLS_VERIFY|HARBOR_INSECURE_BOOL|HARBOR_PROVISIONAL_EXTERNAL_URL|HARBOR_ROBOT_OUT|ARGOCD_SVC|ARGOCD_NS|ARGOCD_API|GUEST_API|GITEA_CLONE_URL|GITEA_ARGOCD_URL|ARGOCD_DEST_KEY|ARGOCD_DEST_VALUE|KIND_KUBECONFIG|KIND_CLUSTER_REMOVED|ARGOCD_MANAGER_NS|ARGOCD_MANIFEST_VERSION|ISTIO_ROUTE_API_EFFECTIVE|PLATFORM_ISTIO_NAMESPACE|PLATFORM_ISTIO_RELEASE|PLATFORM_ISTIOD_NAMESPACE|PROBE_IMAGE|REGISTRY_LOCK_FILE|MANIFEST_DIR|DOCKER_HOST|DOCKER_CONFIG|XDG_RUNTIME_DIR|ENGINE_SUDO_COUNT_FILE|CERTD|JUMPBOX_[A-Z_]*|E2E_[A-Z_]*|CI|GITHUB_[A-Z_]*|READY_TIMEOUT_SECONDS|POLL_INTERVAL_SECONDS|CURL_MAX_TIME_SECONDS|MIRROR_RETRIES|MIRROR_FORCE_PULL|NOTIFY|VCF_[A-Z_]*|PSA_LEVEL_[A-Z_]*|DISPLAY|WAYLAND_DISPLAY|DRY_RUN|GW_IP|TOKEN|RED_TEST_SKIP_PRECHECK|CREDS_TOKEN|GATEWAY_IMAGE_FIXTURE|BUNDLE_HOST_ARCH|BUNDLE_CRANE_VER|BUNDLE_MIRROR_ARCH|VC_TOKEN_FILE|VC_CURL_CFG|VC_HDR_FILE|VC_CODE_FILE|SVC_STATUS|CA_STATUS_CHECKED|CA_STATUS_MATCHED|CA_STATUS_STRICT|PF_PID|PF_GEN|PF_DEATHS|PF_LAST_BODY|PF_RESTARTS_BLOCKED|TREE_STABILITY_ID'

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
# TREE_STABILITY_ID — tree-stability.sh keys its snapshot on the invoking make's PID so two runs in
# one tree cannot overwrite each other; the variable exists ONLY so the gate's own RED-proof can pin
# a stable key instead of racing PPIDs. There is nothing here for an operator to set, and putting it
# in .env.example would invite someone to.
# Documenting three internal counters in .env.example would be noise aimed at the operator.
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

echo >&2
if [ "$rc" -eq 0 ]; then
  log_info "check-env-coverage: OK — every operator-settable variable the scripts read is documented in .env.example."
else
  log_error "check-env-coverage: .env.example is INCOMPLETE —${missing}"
  log_error "  .env.example is the committed source of truth: a variable only the script knows about"
  log_error "  cannot be configured by an operator. Document it (with when-you-need-it + how-to-get-it),"
  log_error "  or — if it is internal/discovered — add it to the explicit exemption list in this script."
fi
exit "$rc"
