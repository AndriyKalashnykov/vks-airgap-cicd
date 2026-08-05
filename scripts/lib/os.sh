#!/usr/bin/env bash
# scripts/lib/os.sh — shared library for all vks-airgap-cicd scripts.
#
# Provides: OS detection + package-manager abstraction (Ubuntu apt / PhotonOS tdnf),
# structured logging, env loading (.env.example then .env), command assertions,
# and internal-CA trust helpers. Source it; do not execute it.
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/lib/os.sh"
#
# shellcheck shell=bash

# Guard against double-sourcing.
[ -n "${__VKS_OS_SH_LOADED:-}" ] && return 0
__VKS_OS_SH_LOADED=1

# Repo root = parent of scripts/. Resolved from THIS file's location so callers
# in scripts/ or scripts/lib/ both work. Fallbacks handle the case where
# BASH_SOURCE is empty (file sourced at the top level of `bash -c`).
if [ -z "${REPO_ROOT:-}" ]; then
  _os_self="${BASH_SOURCE[0]:-}"
  if [ -n "$_os_self" ]; then
    REPO_ROOT="$(cd "$(dirname "$_os_self")/../.." && pwd)"
  fi
  # If that didn't land on a real repo root, fall back to git, then CWD.
  if [ -z "${REPO_ROOT:-}" ] || [ ! -f "${REPO_ROOT}/.env.example" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  unset _os_self
fi
export REPO_ROOT


# ---------------------------------------------------------------------------
# with_registry_lock — serialize every registry-MUTATING operation on this host.
#
# Concurrent container/registry mutation CORRUPTS the target registry's blob store: a partial or
# interleaved push leaves tags/manifests referencing blobs that HEAD-200 but are not actually
# stored. It surfaces LATER as MANIFEST_UNKNOWN / BLOB_UNKNOWN on a pull or a Kaniko build — never
# at push time — and the only reliable recovery is to rebuild the registry from scratch.
#
# The repo has always had a written rule about this ("never run a mirror alongside other registry
# work"). A rule is not a mechanism: it was violated the moment a second `make e2e-kind` was
# started while the first was still finishing, which helm-upgraded Harbor and pushed into it at the
# same time — and corrupted all 34 images. So this makes it MECHANICAL: the second caller fails
# fast with an explanation instead of silently destroying the registry.
#
# Usage:  with_registry_lock <label> <command...>
# ---------------------------------------------------------------------------
with_registry_lock() {
  local label="$1"; shift
  local lock="${REGISTRY_LOCK_FILE:-${REPO_ROOT}/.registry.lock}"

  if ! have flock; then
    log_warn "flock not available — cannot serialize registry work. Do NOT run another mirror/e2e concurrently."
    "$@"; return $?
  fi

  exec 9>"$lock" || die "cannot open the registry lock file: $lock"
  if ! flock -n 9; then
    local holder; holder="$(cat "$lock" 2>/dev/null || true)"
    log_error "another registry-mutating operation is already running${holder:+ (${holder})}."
    log_error "  These share a cluster + registry, so running two at once makes any failure unattributable."
    log_error "  Wait for it to finish, then re-run."
    log_error "  Lock: $lock   (stale after a hard kill? remove it: rm -f '$lock')"
    exit 1
  fi
  printf '%s pid=%s started=%s\n' "$label" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&9
  "$@"
  local rc=$?
  flock -u 9; exec 9>&-
  return "$rc"
}

# ---------------------------------------------------------------------------
# Logging (key=value-ish, timestamped, to stderr so stdout stays pipe-clean)
# ---------------------------------------------------------------------------
_log() {
  # _log LEVEL message...
  local level="$1"; shift
  printf '%s level=%s msg=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}
log_info()  { _log INFO  "$*"; }
log_warn()  { _log WARN  "$*"; }
log_error() { _log ERROR "$*"; }
die()       { _log FATAL "$*"; exit 1; }

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
# Returns the /etc/os-release ID: ubuntu | photon | debian | rhel | ...
os_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}

# Maps the OS to its package manager. Extend here for new distros.
pkg_mgr() {
  case "$(os_id)" in
    ubuntu|debian) printf 'apt-get' ;;
    photon)        printf 'tdnf' ;;
    rhel|centos|fedora|rocky|almalinux) printf 'dnf' ;;
    *)             printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Privilege helper — use sudo only when not already root and sudo exists.
# ---------------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    log_warn "not root and no sudo found; package/CA operations may fail"
  fi
fi
export SUDO

# ---------------------------------------------------------------------------
# Package management
# ---------------------------------------------------------------------------
pkg_refresh() {
  local mgr; mgr="$(pkg_mgr)"
  [ -n "$mgr" ] || die "unsupported OS '$(os_id)': no known package manager"
  log_info "refreshing package metadata via $mgr"
  case "$mgr" in
    apt-get) $SUDO apt-get update -y ;;
    tdnf)    $SUDO tdnf makecache || true ;;
    dnf)     $SUDO dnf makecache -y || true ;;
  esac
}

# is_true <value> — ONE truthiness rule for the whole repo.
#
# There was not one. `VKS_INSECURE_SKIP_TLS_VERIFY` was tested three different ways:
#   30-vks-login.sh:71            [ "${V:-false}" = "true" ]
#   31-fetch-argocd-kubeconfig.sh [ "${V:-0}" = "1" ]
#   .env.example                  documents `VKS_INSECURE_SKIP_TLS_VERIFY=true`  (and its own comment
#                                 shows `=1` in the example invocation)
# So an operator who set the value THE REPO DOCUMENTS got a working vks-login and a fetch-argocd-kubeconfig
# that died demanding the value they had already set — a flag whose accepted spelling depends on which
# script reads it. Accept every spelling a human plausibly types; normalise at the ONE place a CLI needs
# a canonical word (bool_word).
is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}
# bool_word <value> — "true"/"false", for a CLI flag that demands the word (e.g. --insecure-skip-tls-verify=).
bool_word() { if is_true "${1:-}"; then printf 'true'; else printf 'false'; fi; }

# vks_sso_user <username> — normalise a VKS SSO username to 'user@SSO.DOMAIN'. IDEMPOTENT: a value that
# already contains '@' is returned unchanged (so a doc that ships VKS_USERNAME=administrator@vsphere.local
# is not double-domained into administrator@vsphere.local@vsphere.local — the C10 bug); a BARE user gets
# @VKS_SSO_DOMAIN appended. A bare user with no VKS_SSO_DOMAIN is a HARD ERROR, not a silent 'vsphere.local'
# default: real VCF workload domains use a custom SSO domain (e.g. WLD.SSO), so a silent default would send
# the WRONG principal and fail auth as "wrong password" — the same failure class this fixes. One place, so
# 30-vks-login (interactive) and 31-fetch-argocd-kubeconfig (Supervisor context) cannot drift.
vks_sso_user() {
  case "$1" in
    *@*) printf '%s' "$1" ;;
    *)   if [ -n "${VKS_SSO_DOMAIN:-}" ]; then printf '%s@%s' "$1" "$VKS_SSO_DOMAIN"
         else die "VKS_USERNAME must be 'user@SSO.DOMAIN' (e.g. administrator@WLD.SSO), or set VKS_SSO_DOMAIN in .env"; fi ;;
  esac
}

# vks_username_default — the ONE place a concrete SSO principal is written down.
#
# Every other mention in the repo is a placeholder ('administrator@<YOUR-SSO-DOMAIN>'), an EXAMPLE, or
# a regression fixture. That is deliberate: the same value once existed in three spellings
# (vsphere.local / WLD.SSO / wld.sso) across docs and code with nothing asserting they agreed. Not
# duplicating it beats gating that they match — an alignment gate for this was measured at ~89%
# false-RED, because it cannot tell a DEFAULT from an EXAMPLE from the C10 test fixture.
#
# 'wld.sso' not 'vsphere.local': this repo targets VCF WORKLOAD DOMAINS, which carry a custom SSO
# domain — 'vsphere.local' is the stock single-vCenter default and is wrong here more often than not.
# A FUNCTION, not a variable, on purpose. As a plain assignment it was overridable from `.env`:
# load_env sources that file with `set -a` AFTER this lib, so `VKS_USERNAME_DEFAULT=x` in .env WON —
# an undocumented knob silently steering a security principal. `readonly` is not the fix either: the
# later `set -a` source would then ERROR and kill load_env. A function cannot be reassigned by
# sourcing a KEY=value file, so the default has exactly one definition site.
vks_username_default() { printf '%s' 'administrator@wld.sso'; }

# vks_username — print the effective SSO principal, applying vks_username_default (ANNOUNCED) when the
# operator set nothing, then normalising through vks_sso_user.
#
# SHARED ON PURPOSE. The default first shipped as a local assignment inside 30-vks-login.sh's `vcf`
# case — so it reached nothing else, while 31-fetch-argocd-kubeconfig.sh kept an unconditional
# `${VKS_USERNAME:?}`. That made .env.example's "OPTIONAL, defaults to …" FALSE for anyone running
# `make fetch-argocd-kubeconfig`, which Scenario 1 does regardless of VKS_AUTH_METHOD. A default that
# is not shared by every consumer is not a default; it is a per-script accident.
#
# configuration.md forbids a SILENT default for a security-relevant principal, hence the warn: a
# plausible-but-wrong identity fails somewhere else, or succeeds as the wrong user.
# VKS_SSO_DOMAIN IS HONOURED ON THE DEFAULT PATH. The first version printed the default and returned
# WITHOUT calling vks_sso_user, so an operator who set VKS_SSO_DOMAIN — the documented way to say "my
# lab's SSO domain is not the default", and set by exactly the operator this default serves — had it
# SILENTLY DISCARDED, then typed a real password at an interactive prompt against a principal from
# someone else's lab. Routing the default through vks_sso_user also keeps its C10 guard live for this
# path instead of only for the operator-supplied one.
vks_username() {
  if [ -z "${VKS_USERNAME:-}" ]; then
    if [ -n "${VKS_SSO_DOMAIN:-}" ]; then
      # Hand vks_sso_user the BARE user so it appends the operator's domain.
      log_warn "VKS_USERNAME is unset — defaulting to '$(vks_username_default)' with YOUR VKS_SSO_DOMAIN"
      log_warn "  applied: '$(vks_username_default | sed 's/@.*//')@${VKS_SSO_DOMAIN}'. Set VKS_USERNAME in .env to override."
      vks_sso_user "$(vks_username_default | sed 's/@.*//')"
    else
      log_warn "VKS_USERNAME is unset — defaulting to '$(vks_username_default)' (a vCenter SSO admin)."
      log_warn "  Your lab's SSO domain is almost certainly different. Set VKS_USERNAME (or"
      log_warn "  VKS_SSO_DOMAIN) in .env — read the real value off vCenter, do not guess."
      vks_sso_user "$(vks_username_default)"
    fi
    return
  fi
  vks_sso_user "$VKS_USERNAME"
}

# vks_discover_namespace <context-name> — print the vSphere namespace to activate when VKS_NAMESPACE is
# not set. The vcf CLI exposes ONE context per namespace, named '<ctx>:<namespace>' — lab-verified
# 2026-07-22 (`vcf context use sup:<namespace>` on a real 9.1 Supervisor).
#
# WHY NOT `… | head -1`: another automation of this same lab greps its context list for a HARDCODED
# namespace and then takes the first match. That silently picks an arbitrary namespace whenever more
# than one exists — the "pick an arbitrary one" bug coding-style.md records. Here, ambiguity is a HARD
# STOP that prints every candidate, mirroring istio_discover (lib/istio.sh:85-89): a discovery helper
# may resolve the unambiguous case, never guess the ambiguous one.
#
# Requires a CREATED context, so callers must invoke it AFTER `vcf context create`.
vks_discover_namespace() {
  # ${1:-} not $1: under `set -u` a bare $1 dies with "unbound variable" BEFORE the friendly guard
  # below could ever run, making that guard dead code.
  local ctx="${1:-}" n ns json names cands="" count=0
  [ -n "$ctx" ] || die "vks_discover_namespace: no context name given"
  command -v jq >/dev/null 2>&1 \
    || die "jq is required to auto-discover VKS_NAMESPACE — install it, or set VKS_NAMESPACE in .env"

  # `|| true`: `vcf context list` exits non-zero when no context exists, and a bare command
  # substitution failure would kill the caller under `set -e` before the friendly die below.
  json="$(vcf context list -o json 2>/dev/null || true)"
  names="$(printf '%s' "$json" | jq -r '.[]?.name // empty' 2>/dev/null || true)"

  # A heredoc fed by an EMPTY expansion still yields one blank line, so skip empties explicitly
  # (testing.md: "an empty $(…) inside a HEREDOC still yields ONE EMPTY LINE").
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
      "${ctx}:"?*) ns="${n#"${ctx}:"}"; cands="${cands}${ns}"$'\n'; count=$((count + 1)) ;;
    esac
  done <<EOF
$names
EOF

  # DISTINGUISH THE CAUSES. One message for four different failures is a message that names the wrong
  # one: this runs two lines after `vcf context create` SUCCEEDED, so "no context exists" sends the
  # operator to `vcf context list` where they will SEE the context and disbelieve the error.
  if [ -z "$names" ]; then
    log_error "could not parse any context name out of \`vcf context list -o json\`."
    log_error "  This is NOT 'no context exists' — the context was just created. Either the CLI"
    log_error "  emitted something jq could not read, or its JSON shape changed."
    log_error "  Raw output was: ${json:-<empty>}"
    die "set VKS_NAMESPACE in .env to skip discovery entirely"
  fi
  if [ "$count" -eq 0 ]; then
    log_error "no context named '${ctx}:<namespace>' among the ones the CLI reported:"
    while IFS= read -r n; do [ -n "$n" ] && log_error "    ${n}"; done <<EOF
$names
EOF
    log_error "  Namespace contexts may hang off a DIFFERENT parent context than '${ctx}'"
    log_error "  (VKS_CONTEXT_NAME). If one above is the namespace you want, set VKS_NAMESPACE to the"
    log_error "  part after the colon — or set VKS_CONTEXT_NAME to that parent."
    die "set VKS_NAMESPACE in .env"
  fi
  if [ "$count" -gt 1 ]; then
    log_error "found ${count} namespace contexts under '${ctx}' — ambiguous, refusing to guess. Pin one in .env:"
    while IFS= read -r ns; do
      [ -n "$ns" ] || continue
      log_error "    VKS_NAMESPACE=${ns}"
    done <<EOF
$cands
EOF
    die "set VKS_NAMESPACE and re-run"
  fi
  printf '%s' "${cands%$'\n'}"
}

# engine_choice — which engine is the BOOTSTRAP going to install? podman unless the operator asked for
# docker BY NAME. Pure: it prints, it installs nothing, it touches no PATH. Kept separate from
# container_engine() (which asks "what is INSTALLED on this box?") because the gate must be able to prove
# the DEFAULT — "CONTAINER_ENGINE unset ⇒ podman, and docker is never even in the package list" — on a
# machine that happens to have docker installed.
engine_choice() {
  local eng="${CONTAINER_ENGINE:-podman}"
  case "$eng" in
    podman|docker) printf '%s' "$eng" ;;
    *) die "CONTAINER_ENGINE='$eng' is not supported (use 'podman' — the default — or 'docker')" ;;
  esac
}

# engine_packages <engine> <pkg-mgr> — PRINT the OS packages that <engine> needs on <pkg-mgr>.
#
# A PURE FUNCTION: it prints names and installs NOTHING. That is deliberate — it makes the bootstrap's
# engine choice TESTABLE OFFLINE, which is the only way to keep the project's central invariant honest:
#
#     DOCKER IS NEVER *REQUIRED*. It is only ever installed because the operator ASKED for it.
#
# The old gate (test-container-engine.sh #5) scanned for docker INVOCATIONS at a command position. It
# could not see a docker *dependency* — `pkg_install docker` matches none of its alternatives (PROVEN:
# the regex is silent on that exact string) — so an engine-aware bootstrap would have started installing
# a docker daemon on every jump box while the gate kept printing "no docker dependency". A gate that goes
# green on the change it forbids is not a gate. Check 7 now EXECUTES this function and asserts the LIST.
#
# VERIFIED PACKAGE FACTS (ran-it, 2026-07-14 — do not "tidy" these from memory):
#   apt  podman : podman pulls crun (a hard Depends) but uidmap/passt/slirp4netns are *Recommends*, which
#                 our --no-install-recommends DROPS -> rootless podman breaks without them.
#   tdnf podman : pulls uidmap + slirp4netns + fuse-overlayfs WITH podman, but NOT crun.
#   apt  docker : docker.io + rootlesskit + uidmap + dbus-user-session + slirp4netns + fuse-overlayfs.
#                 *** UBUNTU RELEASE SPLIT *** docker.io is 29.1.3 on BOTH 24.04 and 26.04, but only
#                 26.04's deb SHIPS the rootless helper (/usr/share/docker.io/contrib/, OFF PATH);
#                 24.04's deb ships ZERO rootless files. So on 24.04 rootless docker would need
#                 docker-ce-rootless-extras from download.docker.com -- a THIRD-PARTY REPO, which we
#                 REFUSE to add to someone else's jump box. There, docker = ROOTFUL = a sudo per registry.
#   tdnf docker : docker + docker-rootless + rootlesskit all resolve first-class (rc=0, no third-party
#                 repo), and Photon puts dockerd-rootless.sh ON PATH (/usr/bin). Photon is the EASY OS
#                 for rootless docker — the opposite of the usual assumption.
engine_packages() {
  local eng="${1:?engine}" mgr="${2:?pkg-mgr}"
  case "${eng}:${mgr}" in
    podman:apt-get) printf 'podman crun uidmap passt slirp4netns' ;;
    podman:tdnf|podman:dnf) printf 'podman crun' ;;
    docker:apt-get) printf 'docker.io rootlesskit uidmap dbus-user-session slirp4netns fuse-overlayfs' ;;
    # util-linux is NOT optional on Photon: rootlesskit shells out to `unshare` to build the detached
    # netns, and Photon's base image does not ship it. Without it rootless dockerd dies with
    #   failed to execute [unshare -n mount --bind /proc/self/ns/net ...]: exec: "unshare": not found
    # — an error that names a binary, not a package, so it reads like a broken daemon rather than a
    # missing dependency. (Ubuntu has util-linux as an Essential package, which is precisely why only the
    # Photon leg of the matrix failed and why testing on one OS would have shipped this.)
    docker:tdnf|docker:dnf) printf 'docker docker-rootless rootlesskit shadow util-linux fuse-overlayfs slirp4netns' ;;
    *) die "engine_packages: unsupported engine/pkg-mgr combination '${eng}/${mgr}'" ;;
  esac
}

# pkg_install pkg1 [pkg2 ...] — installs packages using the host's manager.
pkg_install() {
  [ "$#" -gt 0 ] || return 0
  local mgr; mgr="$(pkg_mgr)"
  [ -n "$mgr" ] || die "unsupported OS '$(os_id)': cannot install $*"
  log_info "installing via $mgr: $*"
  case "$mgr" in
    apt-get) DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@" ;;
    tdnf)    $SUDO tdnf install -y "$@" ;;
    dnf)     $SUDO dnf install -y "$@" ;;
  esac
}

# ---------------------------------------------------------------------------
# Command assertions
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# container_engine — the OCI engine to use. podman is the DEFAULT; docker is only a fallback.
# Override with CONTAINER_ENGINE. Prints the engine name (podman|docker) or dies.
container_engine() {
  if [ -n "${CONTAINER_ENGINE:-}" ]; then printf '%s' "$CONTAINER_ENGINE"; return 0; fi
  if have podman; then printf 'podman'
  elif have docker; then printf 'docker'
  else die "no container engine found — install podman (the default) or docker"; fi
}

# require_cmd cmd [human hint] — fail fast with an actionable message.
require_cmd() {
  local cmd="$1" hint="${2:-run scripts/00-install-prereqs.sh}"
  have "$cmd" || die "required command '$cmd' not found — $hint"
}

# require_gate_tool <binary> [how-to-get-it]
#
# A GATE THAT SKIPS BECAUSE ITS TOOL IS MISSING IS A GATE THAT PASSES BY NOT LOOKING.
#
# Nine places in this repo used to do `command -v X || { echo "X not installed — skipping"; }` and
# then exit 0 — gitleaks, trivy (x2), shellcheck, yamllint, hadolint (x2), kubeconform, markdownlint.
# Locally that is a kindness (a dev box may genuinely lack a scanner). In CI it is a FALSE GREEN: the
# check reports success having scanned nothing, and nobody reads the line that says so.
#
# So: warn locally, DIE in CI (GitHub sets $CI). CI installs every one of these from .mise.toml, so a
# missing tool there means the toolchain step is broken — which is exactly what we want to hear about.
#
# Returns 1 (not 0) when the tool is absent locally, so the caller can skip its body:
#   require_gate_tool shellcheck "make deps" || return 0
require_gate_tool() {
  local cmd="$1" hint="${2:-run 'make deps' (mise installs it from .mise.toml)}"
  if have "$cmd"; then
    # ⚠️ PRINT WHERE IT RESOLVED, not just that it exists. MEASURED 2026-08-05, twice: a shell
    # carrying a FOREIGN mise activation had this repo's pinned tools absent from PATH entirely,
    # so `have` said yes and a STRAY binary ran — hadolint 2.12.0 instead of the pinned 2.14.0,
    # reporting a false DL3006 on a file nobody had touched. A presence check cannot tell those
    # apart; the PATH is the only thing that can. The Makefile now exports mise's bin-paths, but
    # that `$(shell …)` yields EMPTY on any mise error and PATH is silently left as it was — so
    # without this line you are back to the original bug with a fix sitting in the git log.
    # One line per gate tool, and it turns a 20-minute misdiagnosis into a 5-second read.
    log_info "  using $cmd: $(command -v "$cmd")"
    return 0
  fi
  if [ -n "${CI:-}" ]; then
    die "GATE TOOL MISSING IN CI: '$cmd' — $hint.
  Refusing to skip: a gate that reports success without running is worse than no gate."
  fi
  log_warn "$cmd not installed — this gate is SKIPPED locally ($hint). It will FAIL, not skip, in CI."
  return 1
}

# ---------------------------------------------------------------------------
# Environment loading — .env.example (committed defaults) then .env (overrides).
# `set -a` exports everything so child processes (crane, kubectl, curl) see it.
# ---------------------------------------------------------------------------
load_env() {
  local example="${REPO_ROOT}/.env.example" override="${REPO_ROOT}/.env"
  local legacy="${REPO_ROOT}/.env.kind"          # read-only back-compat; nothing writes it any more
  local state; state="$(state_file)"
  [ -f "$example" ] || die ".env.example missing at $example (it is the committed source of truth)"

  # SNAPSHOT the SELECTORS the operator set EXPLICITLY in the environment, before any sourcing.
  #
  # Sourcing with `set -a` OVERWRITES the environment, so every file below outranks a per-run
  # override — including .env.kind, which is DISCOVERED state we wrote ourselves. That made
  #     make gitops KUBECONFIG=/path/to/other.kubeconfig
  # a SILENT NO-OP: you ran against the remembered cluster while believing you had switched. It also
  # made a two-cluster test undrivable (you cannot hand a script a different kubeconfig), which is
  # precisely why the cross-cluster e2e could never have caught the bugs it existed to catch.
  #
  # A variable that selects WHICH CLUSTER you are talking to must be owned by the caller. Config may
  # supply a DEFAULT; it may not overrule an explicit choice.
  local _sel _snap_names="" _snap_vals=""
  # HARBOR_CA_FILE IS A SELECTOR TOO — it names WHICH trust anchor to use, and both .env.example
  # (`./secrets/harbor-ca.crt`) and the state overlay (an ABSOLUTE HOST path) carry a value for it. So
  # `HARBOR_CA_FILE=/elsewhere make <target>` was a SILENT NO-OP: the files won, and you verified TLS
  # against a CA you did not choose. It bit for real in the jump-box matrix — the container is handed the
  # CA at /run/jumpbox/harbor-ca.crt, load_env overwrote that with the HOST path from .env.state, and the
  # leg died claiming the CA "not found" while pointing at a path that only exists on the host.
  # HARBOR_URL IS THE REGISTRY SELECTOR — it decides WHICH REGISTRY every image is pushed to and pulled
  # from, which makes it the most consequential selector in the repo. It was NOT protected, so
  # `make mirror HARBOR_URL=<other>` was a SILENT NO-OP: .env.example's `HARBOR_URL=harbor.vks.local`
  # (then shipped UNCOMMENTED — now COMMENTED per B13, but this snapshot-protection still guards a
  # per-run / `.env` / `-e` override) was sourced back over it and you mirrored to the default while
  # believing you had switched — the same shape as the KUBECONFIG bug against the wrong cluster.
  # It surfaced in the jump-box matrix: the container is handed `-e HARBOR_URL=<the LB IP>`, load_env
  # replaced it with `harbor.vks.local`, and all four legs died resolving a hostname that exists nowhere.
  # INGRESS_CONTROLLER is a SELECTOR (it names WHICH ingress implementation) and was missing here.
  # MEASURED 2026-08-04: `make install-ingress INGRESS_CONTROLLER=istio-existing` (scenario-1 §11,
  # a documented, supported action) state_sets it into .env.state — which load_env sources LAST, so
  # from then on `INGRESS_CONTROLLER=istio make …` is silently CLOBBERED and cannot be set back.
  # It also reddened `make static-check` permanently: test-gateway-image pins
  # `INGRESS_CONTROLLER=istio` as a command-scoped prefix, the overlay overwrote it, and the
  # classifier's self-tests then ran in the foreign-mesh mode where provenance CANNOT be asserted
  # (6 cases wanted rc=1 and got 0). Proven: with an empty overlay the same gate is rc=0, 7/7.
  # THE CA PINS ARE SELECTORS TOO, and the consequence of clobbering one is the worst in this list.
  # HARBOR_CA_FILE (above) names WHICH anchor; *_CA_SHA256 names which anchor is CORRECT. If a stale pin
  # in .env / .env.state wins over `make vks-login VKS_CA_SHA256=<new>`, the check silently compares
  # against the OLD digest — so it either refuses a legitimate rotation, or (worse) an operator who has
  # been given the right digest is told it does not match, and reaches for the skip-verify escape.
  # Latent today because all three ship COMMENTED, so check-env-clobber passes; protected here so that
  # uncommenting one — the natural thing to do with a value you want to persist — cannot arm it.
  for _sel in KUBECONFIG ARGOCD_KUBECONFIG GUEST_KUBECONFIG VKS_SUPERVISOR_KUBECONFIG ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_DEST_SERVER ARGOCD_DEST_CLUSTER_NAME ARGOCD_NAMESPACE VKS_CONTEXT INGRESS_CONTROLLER HARBOR_CA_FILE HARBOR_URL VKS_CA_SHA256 HARBOR_CA_SHA256 ARGOCD_CA_SHA256; do
    if [ -n "${!_sel:-}" ]; then
      _snap_names="${_snap_names} ${_sel}"
      _snap_vals="${_snap_vals}${_sel}=${!_sel}"$'\n'
    fi
  done

  # THE SNAPSHOT IS ALSO THE SIGNAL. state_check needs to know whether the CALLER explicitly chose a
  # KUBECONFIG — that is the only thing that can contradict the sink's stamp. It read
  # _VKS_EXPLICIT_KUBECONFIG, which NOTHING IN THE PRODUCT SET: only the unit test did. So the whole
  # mismatch-refusal branch was DEAD CODE, and a foreign cluster's sink was ALWAYS sourced. The test
  # passed because the fixture hand-supplied the input the product never supplied — a test of a mock.
  export _VKS_EXPLICIT_KUBECONFIG="${KUBECONFIG:-}"

  set -a
  # shellcheck disable=SC1090
  . "$example"
  # SKIP_DOTENV=1 makes this box behave like a FRESH one: `.env` is ignored, so every
  # you-choose secret must be GENERATED by the flow rather than silently read from the
  # operator's own file. The KinD e2e sets it (see the Makefile) because it is a stand-in
  # for a brand-new operator / a CI runner — neither of which has a `.env`. Without this,
  # a local run passes on values only THIS box has, and the fresh-box code path is never
  # executed (exactly how a KinD smoke job once FATAL'd on an empty HARBOR_PASSWORD in CI
  # while every local run was green).
  if [ "${SKIP_DOTENV:-0}" = "1" ]; then
    if [ -f "$override" ]; then
      log_warn "SKIP_DOTENV=1 — IGNORING .env (reproducing a fresh box: secrets must be generated, not inherited)"
    fi
  else
    # shellcheck disable=SC1090
    [ -f "$override" ] && . "$override"
  fi
  # The STATE OVERLAY holds DISCOVERED state (LB IPs, kubeconfig, generated passwords) and overrides
  # the above so the normal scripts run unchanged against whatever cluster is up.
  #
  # It used to be `.env.kind` — a KinD-named file that carried REAL-LAB state, which is how
  # `make kind-down` (run at Step 0 of BOTH real-lab runbooks) came to destroy an operator's lab
  # kubeconfig and Gitea token. It is now a VARIABLE sink, STAMPED with the cluster that wrote it.
  #
  # state_check decides whether it belongs to the cluster we are talking to. Note the polarity the
  # ADVERSARY forced: an UNSTAMPED sink is still SOURCED (refusing would destroy the only copy of the
  # generated passwords, and the air-gap jumpbox has no cluster to stamp against); only a MISMATCH is
  # refused — and it is now left ALONE rather than archived, because state_check runs on EVERY script
  # including read-only ones, and archiving from a read path renames the operator's sink out from
  # under them (see lib/state.sh).
  #
  # A KUBECONFIG set in `.env` IS AN EXPLICIT OPERATOR CHOICE — it is simply not in the environment.
  # The snapshot above only sees the environment, so for the operator who did the DOCUMENTED thing
  # (uncomment KUBECONFIG in .env, per .env.example) `_VKS_EXPLICIT_KUBECONFIG` was EMPTY — and
  # state_check's mismatch branch short-circuits on exactly that (`[ -n ... ] || return 0`). So the
  # whole cross-cluster refusal was DEAD CODE for the one operator it was written to protect: a lab's
  # sink was sourced unconditionally into a KinD run. Fold the sourced value in before the check.
  # (.env.example deliberately leaves KUBECONFIG COMMENTED, so anything set by now came from the
  # environment or from `.env` — both are the operator choosing, neither is a default.)
  export _VKS_EXPLICIT_KUBECONFIG="${_VKS_EXPLICIT_KUBECONFIG:-${KUBECONFIG:-}}"

  if state_check; then
    # shellcheck disable=SC1090
    [ -f "$state" ] && . "$state"
  fi
  # One release of back-compat: a legacy .env.kind is still read (last, so the new sink wins).
  if [ -f "$legacy" ]; then
    log_warn "reading legacy .env.kind — run 'make state-migrate' to move it to $(basename "$state")"
    # shellcheck disable=SC1090
    . "$legacy"
  fi
  set +a

  # RESTORE the operator's explicit selectors — they outrank every file, including our own overlay.
  if [ -n "$_snap_names" ]; then
    while IFS='=' read -r _k _v; do
      [ -n "${_k:-}" ] || continue
      export "$_k=$_v"
    done <<EOF
$_snap_vals
EOF
  fi

  # KUBECONFIG's default is applied HERE, after the sourcing — never as an uncommented value in
  # .env.example. `set -a` + sourcing OVERWRITES the environment, so an uncommented default there
  # silently defeats a per-run override:
  #     make gitops KUBECONFIG=/tmp/other.kubeconfig     -> was ignored; you targeted ./secrets/vks.kubeconfig
  # That is the repo's own clobber rule (check-env-clobber), and it was unenforced for the ONE
  # variable that decides WHICH CLUSTER you are talking to. It also made a two-cluster test
  # impossible to drive: you cannot hand a script a different KUBECONFIG.
  #
  # NB (C13): this default is a PATH THAT MAY NOT EXIST. A `${KUBECONFIG:?}` guard proves only that the
  # var is SET — which this line always makes true — NOT that the file is present, so it can never be
  # the "you have no kubeconfig" gate (kubectl then silently falls back to http://localhost:8080). The
  # PRESENCE gate is env-check's `[ -f ]` (scripts/02-env.sh). Do NOT add a bare `:?` on a path-valued
  # load_env default expecting it to catch a missing file — existence-check the file instead.
  export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/secrets/vks.kubeconfig}"

  # Same story, same fix: ARGOCD_NAMESPACE selects WHICH ArgoCD instance you talk to. It was pinned
  # UNCOMMENTED in .env.example, so e2e-cross-cluster.sh's env-prefix override
  #     ARGOCD_NAMESPACE="$ARGOCD_NS" ... 70-configure-argocd.sh
  # was SILENTLY INERT — it only looked fine because the value happened to equal the default.
  # It cannot simply be commented out: 70/71/45/99 all read it with `:?` (required), so an unset
  # value would kill `make gitops`. The default belongs HERE, after the sourcing, where a caller's
  # explicit choice still wins.
  export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

  # VKS_CONTEXT selects WHICH KUBE CONTEXT you talk to (30-vks-login.sh: `kubectl config use-context`).
  # It was pinned UNCOMMENTED in .env.example, so `VKS_CONTEXT=my-lab-ctx make ...` was SILENTLY
  # IGNORED — byte-for-byte the ARGOCD_SERVER bug (#174) on a different variable, with check-env-clobber
  # GREEN beside it, because that gate's SELECTORS list was CURATED FROM MEMORY: it named KUBECONTEXT
  # (which exists NOWHERE in this repo) and missed the one that does the work. Only bites on a real lab,
  # where a kubeconfig carries more than one context.
  export VKS_CONTEXT="${VKS_CONTEXT:-vks-workload}"
}

# kubeconfig_ready — the PRESENCE gate for a script about to run kubectl. load_env DEFAULTS KUBECONFIG
# to a PATH THAT MAY NOT EXIST (secrets/vks.kubeconfig), so a bare `: "${KUBECONFIG:?}"` proves the var
# is SET (always true), NOT that the file is present (C13) — and kubectl then silently dials
# http://localhost:8080, giving an error that points nowhere near "produce a kubeconfig first". This
# adds the `[ -f ]` the `:?` cannot. `env-check` already covers the sanctioned path; this makes an
# install-time CONSUMER self-sufficient when run standalone against no cluster.
#
# CALL AS A BARE TOP-LEVEL STATEMENT ONLY (not in $(...) or an `if` — die's exit semantics change).
# Do NOT call it from a read-only preflight ACCUMULATOR (23-argocd-preflight, 49-psa-check): those run
# BEFORE the kubeconfig producer and must stay tolerant (they collect all findings, not die early).
# It is for the workload KUBECONFIG only — a CREATOR path (30-vks-login writes it) must not use it, and
# a different-file check (71's GUEST_KUBECONFIG) does its own `[ -f ]`.
kubeconfig_ready() {
  : "${KUBECONFIG:?KUBECONFIG must be set (path to the workload-cluster kubeconfig)}"
  # A colon-merged KUBECONFIG (kubectl merges multiple files, e.g. ~/.kube/config:~/.kube/lab) is not a
  # single path — `[ -f ]` on the whole string is meaningless. That is a deliberate operator choice, so
  # defer to kubectl and only presence-check the SINGLE-path case (the one load_env's default produces).
  case "$KUBECONFIG" in
    *:*) : ;;
    *)   [ -f "$KUBECONFIG" ] || die "KUBECONFIG='$KUBECONFIG' does not exist — produce it first: 'make vks-login' (real lab) or 'make kind-up' (KinD), or point KUBECONFIG at your kubeconfig." ;;
  esac
  export KUBECONFIG
}

# --- Quoting a SECRET for a sink that PARSES it -------------------------------------------------
#
# Two sinks in this repo take a credential and parse it. Both were interpolating it RAW. Neither
# failure is exotic: an ordinary strong password containing a `"` is enough.
#
# esc_curlk <value> — make a value safe inside a curl -K config's double-quoted directive.
#
#   Measured against a real HTTP server decoding the Authorization header (NOT `--libcurl`, which
#   C-escapes its OWN output and misled three separate attempts at this):
#       user = "admin:ab"cd"   ->  curl sends  admin:ab     <- TRUNCATED at the bare quote
#       user = "admin:ab\cd"   ->  curl sends  admin:abcd   <- backslash EATEN
#   -> Harbor 401, and lib/harbor.sh's diagnostic then blames the PASSWORD and the install order,
#      sending the operator to fix a thing that is not broken. `pw_weak` (02-env.sh) mirrors
#      Harbor's own IsValidSec — length + case + digit, NO charset limit — so `ab"cd` passes every
#      local gate we have.
#   A newline is worse than mangling: it opens a NEW config line, so the value becomes a curl
#   DIRECTIVE (`upload-file = ...` was demonstrably settable). Reachable via Harbor's robot-secret
#   ROTATE endpoint, whose validator permits any charset.
#
#   curl's config parser understands \\ \" \t \n \r \v inside a quoted value. Escape the backslash
#   FIRST or you double-escape what you just inserted.
#
#   \r WAS MISSING, for the life of this function, while the line above already NAMED it. Its
#   failure mode is NOT the newline's: measured against a real listener, a bare \r does not INJECT
#   a directive (the header arrived intact and the injected upload-file never ran) -- it TRUNCATES.
#   So the damage is the QUIET one this whole comment block is about: a silently mangled credential
#   producing a 401 that reads as "wrong password", sending the operator to fix a correct password.
#   MEASURED here 2026-08-05, `pw\rupload-file = /etc/passwd` through od -c:
#       before -> p w \r u p l o a d ...   (a raw 0x0D reaches the config file)
#       after  -> p w  \  r u p l o a d ...(the two-character escape curl expects)
esc_curlk() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; printf '%s' "$s"; }

# esc_sq <value> — make a value safe INSIDE single quotes: it's -> it'\''s
#
#   For a `.env` line that load_env sources with `set -a`. Single-quoting alone is not inert: a `'`
#   in the value TERMINATES the quote, so the rest is parsed as CODE. Graded LOW, and fixed anyway:
#   Harbor cannot currently emit a `'` (its secrets are [a-zA-Z0-9] and robot names are validated
#   `^[a-z0-9]+(?:[._-][a-z0-9]+)*$`, both verified in goharbor v2.15.0 source), so the injection is
#   NOT reachable today. It is one upstream charset change from being reachable, and a stray `'`
#   already yields `unmatched '` -> the var ends up UNSET -> a 401 that blames the password.
esc_sq() { local s=$1; s=${s//\'/\'\\\'\'}; printf '%s' "$s"; }

# doc_robot_line_is_bad LINE — return 0 (BAD) iff LINE is a shell assignment whose value EXPOSES a
# Harbor robot-name expansion `robot$<letter>` OUTSIDE a single-quoted span, so a `set -a` source
# would expand it away (`HARBOR_USERNAME=robot$vks-cicd` -> `robot-cicd` -> Harbor 401). A robot
# USERNAME is always `robot$<name>` (goharbor v2.15.0), and its SECRET is [a-zA-Z0-9] with NO `$` —
# so `robot$` is the COMPLETE key for the class, not a heuristic (a HARBOR_PASSWORD cannot carry a
# `$`). Single-quoted (`'robot$vks-cicd'`) is safe; double-quoted (`"robot$…"`) or bare is not. This
# powers check-doc-robot-quoting.sh and lives here (like esc_sq/esc_curlk) so the gate's TEST can
# EXECUTE it rather than grep for it. The span test COUNTS single quotes before the match (a prefix
# test is not a span test — see rules/common/hooks.md); the narrow `robot$` scope keeps it tractable.
# Accepted, documented residuals (NOT chased): an adjacency-break (`'robot'$vks`) has no literal
# `robot$` -> missed; `robot$<digit>` / `robot$<non-letter>` / `robot${braced}` are not flagged (the
# letter-requirement is LOAD-BEARING — it is what skips the `robot$<name>` placeholder and comment
# forms); a blockquote/list-prefixed assignment (`> KEY=`) is not matched. A deliberate bad-form
# example is exempted with a `# env-quote-ok:` marker on the line.
doc_robot_line_is_bad() {
  local line="$1" val before qs re
  case "$line" in *'# env-quote-ok:'*) return 1 ;; esac                    # marker on the RAW line (it IS a comment)
  [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*= ]] || return 1  # a shell assignment
  val="${line#*=}"; val="${val%%#*}"                                       # value, trailing `# comment` stripped
  re='robot\$[A-Za-z_]'; [[ "$val" =~ $re ]] || return 1                   # a REAL robot-name expansion
  before="${val%%robot\$[A-Za-z_]*}"                                       # the value substring before the match
  qs="${before//[^\']/}"                                                   # keep only single-quote characters
  if (( ${#qs} % 2 == 1 )); then return 1; fi                             # ODD -> inside a '…' span -> SAFE
  return 0                                                                 # EVEN -> exposed -> BAD
}

# set_env_var KEY VALUE FILE — idempotently upsert KEY=VALUE into an EXPLICIT file.
#
# The file argument used to DEFAULT to .env.kind. That default is exactly how real-lab state ended up
# in a KinD-named file that `make kind-down` deletes. There is no default any more: callers use
# `state_set` (the stamped overlay) or name their own file. A missing sink is now a loud error, not a
# silent write to the wrong place.
# Used by the KinD flow to publish discovered values to the normal scripts.
set_env_var() {
  local key="$1" val="$2" file="${3:?set_env_var: a SINK is required — use state_set (the stamped overlay) or pass an explicit file}"
  mkdir -p "$(dirname "$file")"; touch "$file"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    grep -vE "^${key}=" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$file"
}

# ---------------------------------------------------------------------------
# Internal-CA trust — install a self-signed CA (Harbor/Gitea) into system trust.
# ---------------------------------------------------------------------------
# trust_ca /path/to/ca.crt [friendly-name]
trust_ca() {
  local ca="$1" name="${2:-vks-internal}"
  [ -f "$ca" ] || { log_warn "CA file '$ca' not found — skipping system trust"; return 0; }
  case "$(os_id)" in
    ubuntu|debian)
      $SUDO cp "$ca" "/usr/local/share/ca-certificates/${name}.crt"
      $SUDO update-ca-certificates
      ;;
    photon|rhel|centos|fedora|rocky|almalinux)
      $SUDO cp "$ca" "/etc/pki/ca-trust/source/anchors/${name}.crt"
      $SUDO update-ca-trust extract
      ;;
    *) log_warn "unknown OS '$(os_id)': add $ca to the system trust store manually" ;;
  esac
  log_info "trusted CA $ca as $name"
}

# ---------------------------------------------------------------------------
# Shared-secret token: read from a gitignored file, generating it once if absent
# (umask 077). Used so the Gitea webhook (50) and the EventListener secret (60)
# agree on the same HMAC token. Prints the token to stdout.
# ---------------------------------------------------------------------------
ensure_secret_token() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  if [ ! -s "$file" ]; then
    local tok
    if have openssl; then tok="$(openssl rand -hex 24)";
    else tok="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
    ( umask 077; printf '%s' "$tok" > "$file" )
    log_info "generated shared secret token -> $file" >&2
  fi
  cat "$file"
}

# gen_password — a random 16-char password that satisfies typical complexity policies
# (Harbor/Gitea: >=1 uppercase, lowercase, digit) with NO hardcoded literal. One char of
# each class is drawn FROM the random stream, then padded with more random alphanumerics,
# so the result is fully random yet always complexity-valid. openssl preferred; urandom
# fallback. Alphanumeric only, so the value is shell-clean for .env / KEY=value files.
gen_password() {
  local raw u l d
  if have openssl; then raw="$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9')"
  else raw="$(head -c 128 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"; fi
  u="$(printf '%s' "$raw" | LC_ALL=C tr -dc '[:upper:]' | head -c1)"
  l="$(printf '%s' "$raw" | LC_ALL=C tr -dc '[:lower:]' | head -c1)"
  d="$(printf '%s' "$raw" | LC_ALL=C tr -dc '[:digit:]' | head -c1)"
  printf '%s%s%s%s' "$u" "$l" "$d" "$(printf '%s' "$raw" | head -c13)"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
# require_internet <what-needs-it> — FAIL FAST, and name the real problem, on a box with no internet.
#
# WITHOUT THIS, A NO-INTERNET BOX GETS THE WORST POSSIBLE FAILURE. Nothing in `preflight` probes the
# internet (it checks tool PRESENCE and CLUSTER reachability), so `make install-all` on an air-gapped box
# sails through preflight and then enters mirror-pull's http_get_retry, which is built to survive
# githubusercontent 429s: curl --retry 3 (with backoff) inside 5 outer attempts with 5s delays and a 10s
# connect timeout. MEASURED: >2 minutes of retrying on a SINGLE manifest URL, and there are several of
# them before the first image is even touched. The operator then gets a curl error naming
# storage.googleapis.com — never "this box has no internet, you want the sneakernet flow".
#
# The resilience is correct for a FLAKY network and exactly wrong for an ABSENT one. So: probe once,
# cheaply, up front, and say the thing that is actually true.
require_internet() {
  local what="${1:-this step}" host rc=1
  # Two hosts, so one provider being down is not read as "no internet". HEAD only, short timeouts.
  for host in https://storage.googleapis.com https://github.com; do
    if curl -sSf -o /dev/null --head \
         --connect-timeout "${INTERNET_PROBE_TIMEOUT_SECONDS:-5}" \
         --max-time "${INTERNET_PROBE_MAX_TIME_SECONDS:-10}" \
         --retry 0 "$host" 2>/dev/null; then
      rc=0; break
    fi
  done
  [ "$rc" -eq 0 ] && return 0
  die "NO INTERNET on this box — and ${what} needs it.

  You are on the wrong flow for this box. Nothing here can download anything.

  If NO SINGLE BOX reaches both the internet and Harbor, use the SNEAKERNET flow (docs/sneakernet.md):
      on a box WITH the internet :  make mirror-pull && make builder-build && make bundle
      carry the .tar + .sha256 + this repo across
      on THIS box               :  make bundle-load BUNDLE_TARBALL=... && make mirror-push && make mirror-verify
                                   then: make platform gitops && make install-ingress && make verify

  Do NOT run 'make install-all' here: it starts with 'mirror', which downloads from the internet.
  (If you believe this box IS online, check your proxy: this probe HEADs storage.googleapis.com and github.com.)"
}

# http_get_retry <url> <dest> — download <url> to <dest>, resilient to transient
# failures (notably raw.githubusercontent.com HTTP 429 rate-limiting). Combines
# curl's own transient-error retry with an outer exponential-backoff loop, so a
# rate-limited GitHub-raw fetch does not fail the install on the first blip.
# Tunables come from .env.example (HTTP_GET_* / CURL_MAX_TIME_SECONDS). Writes
# to <dest> only on success (curl -o truncates, but the outer loop re-fetches);
# dies after the retry budget is exhausted.
http_get_retry() {
  local url="$1" dest="$2"
  local attempts="${HTTP_GET_RETRIES:-5}"
  local delay="${HTTP_GET_RETRY_DELAY_SECONDS:-5}"
  require_cmd curl
  local i
  for (( i = 1; i <= attempts; i++ )); do
    if curl -fsSL \
         --retry 3 --retry-delay "$delay" --retry-all-errors \
         --connect-timeout "${HTTP_CONNECT_TIMEOUT_SECONDS:-10}" \
         --max-time "${HTTP_GET_MAX_TIME_SECONDS:-60}" \
         -o "$dest" "$url"; then
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      log_warn "download failed (attempt ${i}/${attempts}): ${url} — retrying in ${delay}s"
      sleep "$delay"
      delay=$(( delay * 2 ))
    fi
  done
  die "failed to download ${url} after ${attempts} attempts"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# dry_run flag: set DRY_RUN=1 to print privileged/mutating commands instead of
# running them. run() honors it.
run() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf 'DRY_RUN %s\n' "$*" >&2
  else
    "$@"
  fi
}

# pick_port — print a free TCP port from the kernel's ephemeral range (bind :0).
# Race-free: the kernel assigns the port atomically at bind time (no TOCTOU window
# like a RANDOM + `ss -tln` poll). Used for LOCAL `kubectl port-forward` aliases so
# two e2e runs (parallel CI matrix, dev + CI on one host, sibling project) don't
# collide on a fixed local port. The REMOTE port (the Service's port) stays literal.
#
# B3 — python3 IS NOT ON THE AIR-GAP BOX, so this MUST degrade rather than die. A bare `photon:5.0`
# has no python3, and neither `00-install-prereqs.sh` (internet-side only) nor the bundle supplies
# one. Before this fallback existed, the first thing the air-gap box did after installing Gitea was
# `seed-gitea` -> `pick_port` -> `python3: command not found` -> `make: *** [seed-gitea] Error 127`,
# with `check-tools` having reported the box FULLY CLEAN moments earlier — it does not know this
# dependency exists. Adding python3 to the documented OS floor was rejected: it is a large dependency
# to carry across an air gap for one helper, and the floor is the thing an operator must provision by
# hand on a box with no internet.
pick_port() {
  if have python3; then
    # PREFERRED: race-free. The kernel assigns the port atomically at bind time.
    python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
    return
  fi
  # FALLBACK, and its weakness is stated rather than hidden: this probes a candidate instead of
  # binding it, so there IS a TOCTOU window between "nothing answered" and the caller's bind. That is
  # strictly better than not running at all, and the callers are local `kubectl port-forward` aliases
  # where a collision is a loud, immediate bind error rather than silent corruption. A connect that is
  # REFUSED means nothing is listening; the subshell keeps the fd from leaking into the caller.
  local p n=0
  while [ "$n" -lt 50 ]; do
    p=$(( 40000 + (RANDOM % 20000) ))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
    n=$((n + 1))
  done
  die "pick_port: no free local port found in 50 attempts in 40000-59999 (and python3, the race-free path, is absent)."
}

# ---------------------------------------------------------------------------
# The stamped state sink (state_file / state_set / state_check / state_stamp / state_archive).
# ---------------------------------------------------------------------------
# assert_run_sentinel <log> <expected> — a positive control for "the run reached its END".
#
# WHAT IT CATCHES, AND WHAT IT DOES NOT. An exit code says "no command failed". It CANNOT say "the
# script did the work": a run that takes an early `exit 0` -- a shortcut added while debugging a
# 40-minute leg, a truncated flow -- exits 0 having skipped everything after it. The end-of-work
# sentinel is the only signal that separates those, and it is worthless unless something READS it.
#
# It does NOT catch a `|| true` swallowing a mid-script failure: execution continues, the sentinel
# still prints, and this returns 0. B47's original justification claimed otherwise and was wrong.
# The catchable class is early-exit-with-status-0, nothing wider. Do not over-trust it.
#
# `grep -qx` (whole-line anchored) is load-bearing, not hygiene: the harness bind-mounts the repo at
# /src, so the sentinel's own SOURCE line is reachable, and an xtrace run would echo `+ echo <token>`.
# Anchoring rejects both (measured: 0 of 5 realistic contaminants match, 1 of 1 genuine line does).
assert_run_sentinel() {
  local log="$1" expect="$2"
  [ -f "$log" ] || { log_error "assert_run_sentinel: no log at ${log} — cannot tell a completed run from a truncated one."; return 1; }
  grep -qx "$expect" "$log" && return 0
  log_error "the run exited 0 but never printed its end-of-work sentinel '${expect}'."
  log_error "  It did not reach its documented end: an early 'exit 0', a truncated run, or a shortcut."
  return 1
}

# Sourced LAST: state.sh uses log_* from this file. os.sh is the only thing that sources it, so every
# script that already sources os.sh gets the sink for free.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/state.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh"

# ---------------------------------------------------------------------------
# classify_kube_failure <stderr-file> -> prints one token
#   STALE_CA | UNAUTHORIZED | FORBIDDEN | UNREACHABLE | UNKNOWN
#
# WHY. `kubectl … >/dev/null 2>&1 || die "check network + auth"` throws away the answer and then
# guesses. MEASURED 2026-08-05, walking scenario-1 against a REBUILT lab: the guest kubeconfig's
# address still matched (the LB IPs repeated) but its embedded `kubernetes` CA belonged to the
# DESTROYED cluster, and the operator was told to check network and auth — neither of which was
# wrong. A rebuild invalidates stored trust material; nothing in the message said so.
#
# ⚠️ NEVER MERGE THE STREAMS to capture this. `2>&1` makes the capture non-empty, which inverts any
# `[ -z … ]` emptiness test downstream — measured elsewhere in this repo to turn a WARN into a BLOCK
# asserting the opposite of what it saw. Capture stderr to its OWN file and branch on rc first.
#
# ⚠️ MATCH THE SPECIFIC SUBSTRING, NOT THE PREFIX. "Unable to connect to the server: tls: failed to
# verify certificate: x509…" and "Unable to connect to the server: dial tcp …: no route to host"
# SHARE their prefix, so an "Unable to connect" matcher conflates a stale CA with a dead lab —
# reintroducing exactly the confusion this exists to remove.
# ── three-state capability probes ───────────────────────────────────────────────────────────────
#
# ⚠️ TWO STATES IS THE BUG. `$(cmd 2>/dev/null || echo no)` collapses "you are refused" and
# "the question never reached the server" onto the same token, so a TLS/CA/network fault is
# reported to a customer as an RBAC denial and they go request a grant they already have.
# These return a THIRD state, `unknown`, and leave the reason in K_CAN_I_CLASS.
#
# Callers must decide what `unknown` MEANS for them — it is not one behaviour:
#   a capability LADDER   -> warn loudly, do NOT select that mechanism
#   an EXPLICIT choice    -> die; an operator's explicit request must never be silently downgraded
#   a NEGATIVE CONTROL    -> die; "could not ask" is a hard failure, never a passing assertion
#   a report/table        -> print it; a report may legitimately say "could not determine"
#
# ⚠️ THEY PRINT "state|class", NOT a state plus a GLOBAL. The first draft set K_CAN_I_CLASS and
# every caller reads these through `$( )` — a SUBSHELL — so the global could never escape and the
# reason was silently lost at every single site. A global cannot cross a subshell; the return
# value can. Callers split: `ans="${r%%|*}"; why="${r#*|}"`.

# argocd_tls_opts — make EVERY argocd invocation verify TLS, in one place.
#
# ⚠️ ARGOCD_CA_FILE had ONE producer (`make fetch-argocd-ca`) and ZERO consumers. The fetch was
# even pinnable via ARGOCD_CA_SHA256 — so the repo verified the anchor it then never used.
# `argocd` exposes a global `--server-crt`, and it reads extra global flags from ARGOCD_OPTS, so
# setting it here covers can-i, `app create`, `app wait` and anything added later — rather than
# threading a flag through every call site and missing the next one.
#
# ⚠️ WHY NOBODY NOTICED: the only e2e exercising the argocd (`api`) mechanism exported
# ARGOCD_OPTS="--insecure". The test was green precisely because it disabled the verification the
# real operator path leaves ON. A gate that turns off the thing that breaks in production is not
# a gate. That override is now gone; this function is what replaces it.
#
# APPENDS — never clobbers. An operator who set ARGOCD_OPTS keeps it.
argocd_tls_opts() {
  [ -n "${ARGOCD_CA_FILE:-}" ] || return 0
  if [ ! -s "$ARGOCD_CA_FILE" ]; then
    log_warn "ARGOCD_CA_FILE is set to '${ARGOCD_CA_FILE}' but that file is empty or missing — argocd
  will fall back to the system trust store and will NOT verify a self-signed ArgoCD. Re-fetch it:
  make fetch-argocd-ca"
    return 0
  fi
  case " ${ARGOCD_OPTS:-} " in
    *" --server-crt "*) : ;;                                  # already set by the caller — respect it
    *) export ARGOCD_OPTS="${ARGOCD_OPTS:+${ARGOCD_OPTS} }--server-crt ${ARGOCD_CA_FILE}" ;;
  esac
}

# k_can_i <kubectl-args...> -> prints yes|no|unknown
k_can_i() {
  local _out _err _rc=0
  _err="$(mktemp)"
  # ⚠️ stderr to its OWN FILE, never `2>&1`. classify_kube_failure's header states the reason:
  # merging makes the capture non-empty, which inverts any `[ -z ]` emptiness test downstream.
  # It also keeps kubectl's yes/no (stdout) out of the text being classified.
  _out="$(kubectl "$@" 2>"$_err")" || _rc=$?
  if [ "$_rc" -ne 0 ] && [ -s "$_err" ] && ! printf '%s' "$_out" | command grep -qx 'no'; then
    # rc!=0 with no usable answer on stdout: the probe did not get to ask.
    local _cls; _cls="$(classify_kube_failure "$_err")"; rm -f "$_err"
    printf 'unknown|%s' "$_cls"; return 0
  fi
  rm -f "$_err"
  # ⚠️ kubectl prints its answer to STDOUT and exits 1 on a denial, so rc alone cannot be trusted
  # in EITHER direction. Read the answer.
  case "$_out" in *yes*) printf 'yes|' ;; *no*) printf 'no|' ;; *) printf 'unknown|UNPARSEABLE' ;; esac
}

# argocd_can_i <can-i args...> -> prints yes|no|unknown
argocd_can_i() {
  local _out _err _rc=0
  _err="$(mktemp)"
  _out="$(argocd account can-i "$@" 2>"$_err")" || _rc=$?
  # ⚠️ THE EXIT CODE FILES A DENIAL AS PERMITTED. Verified in upstream argo-cd at the INSTALLED
  # version v3.4.5: server/account/account.go returns `&CanIResponse{Value:"no"}, nil` — a NIL
  # error — and cmd/argocd/commands/account.go does `CheckError(err); fmt.Println(response.Value)`,
  # so a refusal PRINTS "no" and EXITS 0. The old `if argocd account can-i … >/dev/null; then
  # can_api=yes; fi` therefore recorded a REFUSED tenant as permitted, and the `>/dev/null` threw
  # away the one thing carrying the answer. Compare the OUTPUT; never branch on rc alone.
  if [ "$_rc" -ne 0 ]; then
    # ⚠️ argocd is a THIRD vendor vocabulary — JSON, not kubectl's plain text — so the shared
    # classifier misses its shapes. An EXPIRED ARGOCD_AUTH_TOKEN is the most common argocd fault
    # and has a trivial remedy, yet it classified UNKNOWN; its text is
    #   rpc error: code = Unauthenticated desc = invalid session token: token is expired
    # Auth is tested BEFORE transport so a token message is not swallowed by the connection arm.
    local _cls; _cls="$(classify_kube_failure "$_err")"
    if [ "$_cls" = UNKNOWN ]; then
      if command grep -qiE 'Unauthenticated|invalid session token|token is expired|Unauthorized' "$_err"; then
        _cls=UNAUTHORIZED
      elif command grep -qiE 'failed to establish connection|connection refused|x509|tls' "$_err"; then
        _cls=UNREACHABLE
      fi
    fi
    rm -f "$_err"; printf 'unknown|%s' "$_cls"; return 0
  fi
  rm -f "$_err"
  case "$_out" in yes) printf 'yes|' ;; no) printf 'no|' ;; *) printf 'unknown|UNPARSEABLE' ;; esac
}

classify_kube_failure() {
  local errfile="${1:-/dev/null}" e=""
  [ -r "$errfile" ] && e="$(cat "$errfile" 2>/dev/null || true)"
  # ⚠️ ARM ORDER IS PART OF THE CONTRACT. First match wins, so an arm that can match text belonging
  # to another class SHADOWS every arm below it. UNAUTHORIZED used to sit second and did exactly
  # that — see the 401 note below; a genuine FORBIDDEN was classified UNAUTHORIZED.
  case "$e" in
    *"x509"*|*"certificate signed by unknown authority"*|*"certificate is valid for"*) printf 'STALE_CA' ;;

    # PLAINTEXT: the endpoint is not speaking TLS at all. Its own class because every CA remedy is
    # wrong here — there is nothing for an anchor to verify, so re-fetching or re-pinning cannot
    # help. Almost always a wrong scheme or port. (The numeric sibling of this verdict is
    # ca_verifies_endpoint's rc=4; keep the two remedy texts saying the same thing.)
    *"first record does not look like a TLS handshake"*|*"server gave HTTP response to HTTPS client"*) \
                                                                                       printf 'PLAINTEXT' ;;

    # ⚠️ NETWORK BEFORE AUTH, and `401` ANCHORED. BOTH are required; neither alone is enough.
    #
    # `*"401"*` was unanchored and sat ABOVE this arm. It does not collide with ports (that was the
    # theory) — it collides with kubectl's KLOG MICROSECOND TIMESTAMP. MEASURED: 60 invocations
    # against a refused endpoint on port 9999, with no `401` anywhere in the address — 4 of 60
    # (6.7%) contained `401` from fields like `.380401`, and those 4 classified UNAUTHORIZED while
    # the other 56 classified UNREACHABLE. Same command, same endpoint, different verdict: a
    # heisenbug a rerun "fixes". Treat the rate as "single-digit percent", not as 6.7 — it scales
    # with how many klog retry lines a given failure emits.
    #
    # Anchoring alone leaves the ordering fragile; reordering alone still lets a 401-bearing
    # UNKNOWN misfire. `401` is the ONLY purely-numeric token in this function, so it is the only
    # one that can collide with machine-generated digits (timestamps, PIDs, `file.go:NNN` lines) —
    # every other token is alphabetic and needs no anchor.
    *"no route to host"*|*"connection refused"*|*"i/o timeout"*|*"dial tcp"*|*"no such host"*) \
                                                                                       printf 'UNREACHABLE' ;;

    # ⚠️ kubectl TRANSLATES a 401 — its stderr contains neither "Unauthorized" NOR "401".
    # MEASURED against a server returning HTTP 401 with body {"reason":"Unauthorized","code":401}:
    #   error: You must be logged in to the server (the server has asked for the client to provide credentials)
    # Both phrasings are matched: the second survives if the final summary line is ever truncated,
    # since it also appears in the klog lines. Without these, the arm NEVER fired on the real
    # credential-expiry case — a perfect inversion with the 401 collision above, which fired only
    # when it was wrong.
    *"You must be logged in to the server"*|*"asked for the client to provide credentials"*) \
                                                                                       printf 'UNAUTHORIZED' ;;
    *"Unauthorized"*|*" 401 "*|*"(401)"*|*'"code":401'*|*"code: 401"*)                  printf 'UNAUTHORIZED' ;;

    *"forbidden"*|*"Forbidden"*|*"cannot list resource"*)                              printf 'FORBIDDEN' ;;
    *)                                                                                 printf 'UNKNOWN' ;;
  esac
}
