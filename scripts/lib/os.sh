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
  # BOTH FORMS, because BOTH are in real use — measured across scripts/: 64 single-arg call sites,
  # 21 that pass `<cmd> "<hint>"`, and ~8 that pass several BARE command names.
  #
  # It was originally `local cmd="$1" hint="${2:-…}"`, so `require_cmd jq curl kubectl` checked ONLY
  # jq, silently turned "curl" into the hint and discarded "kubectl" — measured: with a PATH holding
  # only jq it returned SUCCESS while curl and kubectl were absent.
  #
  # ⚠️ The fix for that was a plain `for cmd in "$@"`, and its comment claimed "SEVEN callers … every
  # one of them was checking a single command". THAT PREMISE WAS FALSE and it broke 21 sites: the
  # HINT was then checked as if it were a command, so `require_cmd vcf "install the VCF CLI (make
  # install-vcf-clis) on this jump box"` FATAL'd with
  #     required command 'install the VCF CLI (make install-vcf-clis) on this jump box' not found
  # on a box where vcf was installed and working. MEASURED on a live lab: it killed `make vks-login`
  # at scenario-1 Step 3 and cascaded to every downstream block of the walk.
  #
  # THE DISCRIMINATOR IS WHITESPACE: no command name contains a space, and all 21 hints do. So an
  # argument containing whitespace is the HINT for the command that precedes it — never a command.
  # A single-WORD hint would be misread as a command; there are none today, and this comment is the
  # contract that keeps it that way.
  local cmd hint
  while [ $# -gt 0 ]; do
    cmd="$1"; shift
    hint=""
    case "${1:-}" in *[[:space:]]*) hint="$1"; shift ;; esac
    have "$cmd" || die "required command '${cmd}' not found — ${hint:-install it (see 'make deps') and re-run.}"
  done
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
  # VKS_CLUSTER_NAME / VKS_NAMESPACE ARE THE MOST LITERAL SELECTORS IN THIS FILE — they name WHICH
  # CLUSTER, in WHICH vSphere Namespace — and they were missing, so this list contradicted its own
  # doctrine four lines above ("a variable that selects WHICH CLUSTER you are talking to must be owned
  # by the caller"). MEASURED 2026-08-08 with VKS_CLUSTER_NAME=cicd-gc1 uncommented in .env (the
  # NORMAL state — the operator is told to set it there):
  #     VKS_CLUSTER_NAME=cicd-gc2 …load_env… -> effective VKS_CLUSTER_NAME=cicd-gc1
  # So `make vks-cluster-create VKS_CLUSTER_NAME=cicd-gc2` silently targets cicd-gc1 and, if it
  # exists, prints "ALREADY EXISTS — not re-applying" — the operator believes they created gc2 while
  # every later step (status, login, gitops, uninstall-all) addresses gc1. Nothing says otherwise.
  # check-env-clobber cannot see this: it reads .env.example (where these ship COMMENTED and it is
  # correctly green); the clobber is armed by the operator doing the DOCUMENTED thing in their .env.
  # SUPERVISOR_HOST and VCENTER_HOST were missing until 2026-08-11, and they are the two most
  # selector-shaped values in the repo: they name WHICH SUPERVISOR and WHICH VCENTER, i.e. which LAB
  # you are on at all. MEASURED by contrast, which is the only way to be sure:
  #     SUPERVISOR_HOST=192.0.2.1          -> load_env -> 192.168.101.128   (.env won)
  #     KUBECONFIG=/tmp/probe.kubeconfig   -> load_env -> /tmp/probe.kubeconfig  (protected, survived)
  # So `make <anything> SUPERVISOR_HOST=<other lab>` silently addressed the .env lab. That is the
  # KUBECONFIG incident this list exists for, aimed at the variable that picks the lab itself.
  # VCF_CLI_SRC_DIR is a SELECTOR ("which directory do I install the licensed CLIs from") and was
  # missing until 2026-08-10. 01-install-vcf-clis.sh's own usage line documents
  # `VCF_CLI_SRC_DIR=<dir> scripts/01-install-vcf-clis.sh`, and that override was SILENTLY DEFEATED
  # whenever .env also set it. Measured via its test, which drives the installer with exactly that
  # env prefix: after scenario-1 Step 1 wrote VCF_CLI_SRC_DIR into .env, the installer resolved the
  # operator's REAL archives instead of the fixtures and 8 of 9 cases failed.
  # HARBOR_USERNAME/HARBOR_PASSWORD are here because the overlay was measured to outrank the
  # COMMAND LINE too: `HARBOR_PASSWORD=x make env-validate` was a silent no-op while .env.state
  # held a value. This is a COMPLEMENT, not the fix — the snapshot is taken from the process
  # environment before any sourcing, so it cannot help a value that lives in `.env`. The root
  # cause is 04-install-harbor-service.sh publishing a credential it did not produce; that is
  # fixed at the writer. WHICH identity the pipeline runs as is a selector in every sense that
  # matters — an overlay `admin` silently shadowing a least-privilege robot is the reason.
  # HARBOR_INSECURE / ARGOCD_INSECURE / MIRROR_VERIFY_FAST are NOT "which thing am I talking to" —
  # they are SECURITY-POSTURE toggles, and they are here because the harm is identical and because
  # `.env.state` is a THIRD clobber channel that no gate can see. `check-env-clobber` reads
  # `.env.example` (correct, and green); the overlay is written by OUR OWN tooling (`state_set` in
  # 05-kind-up.sh / 06-install-harbor.sh / 07-install-argocd.sh) and `load_env` sources it LAST, so
  # it outranks even the command line. MEASURED 2026-08-18, with a discriminating control:
  #     HARBOR_INSECURE=0    + overlay 1 -> 1   (caller DEFEATED)
  #     ARGOCD_INSECURE=0    + overlay 1 -> 1   (caller DEFEATED)
  #     MIRROR_VERIFY_FAST=0 + .env    1 -> 1   (caller DEFEATED)
  #     HARBOR_URL=X         + overlay Y -> X   (already snapshotted -> SURVIVED; the control that
  #                                              proves the probe is not simply clobbering all)
  # CLAUDE.md already records this exact incident through the OTHER channel — `make e2e-kind
  # HARBOR_INSECURE=1` silently ran the full SECURE stack — so this is a recurrence via a new sink.
  # The first two pin TLS VERIFICATION off with no way back from the command line; the third turns
  # `crane validate` into `--fast` (manifest/config only, per 23-mirror-verify.sh:14-15), i.e. it
  # skips exactly the layer-blob download that caught the 2026-07-13 Harbor wipe (153 manifest
  # links, ZERO blobs — a state `--fast` passes).
  # ⚠️ The `[ -n … ]` guard below is what keeps this SAFE: it restores only a value the CALLER set,
  # so an overlay that legitimately records "this Harbor was installed insecure" still applies when
  # the caller is silent. A fix that forced these to a fixed value would break the KinD flow; that
  # arm is asserted in test-insecure-toggle-snapshot.sh, not assumed.
  # ARGOCD_ADMIN_PASSWORD / GITEA_ADMIN_PASSWORD added 2026-08-18 — the SAME class as
  # HARBOR_PASSWORD three lines up, found by an adversary round on the commit that added the three
  # toggles above and MISSED these two. Both are `state_set` into the overlay (05-kind-up.sh:131,
  # :142) and both ship in .env.example as `# VAR=<SET-IN-.env>` — i.e. documented as
  # operator-settable — exactly like HARBOR_PASSWORD, whose own note above records that "the overlay
  # was measured to outrank the COMMAND LINE too". MEASURED with a discriminating control AND an
  # inverse control, so the probe cannot be lying in either direction:
  #     HARBOR_PASSWORD        caller=fromCaller overlay=fromOverlay -> fromCaller   PROTECTED
  #     ARGOCD_ADMIN_PASSWORD  caller=fromCaller overlay=fromOverlay -> fromOverlay  DEFEATED
  #     GITEA_ADMIN_PASSWORD   caller=fromCaller overlay=fromOverlay -> fromOverlay  DEFEATED
  #     ARGOCD_LB_IP           caller=fromCaller overlay=fromOverlay -> fromOverlay  CORRECT — a
  #                            DISCOVERED value SHOULD come from the overlay; it is the inverse
  #                            control that proves this list is still a list and not "everything".
  # Of the 5 operator-settable credentials `state_set` writes, 3 were protected and 2 were not.
  for _sel in SUPERVISOR_HOST VCENTER_HOST KUBECONFIG VKS_AUTH_METHOD ARGOCD_KUBECONFIG GUEST_KUBECONFIG VKS_SUPERVISOR_KUBECONFIG ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_DEST_SERVER ARGOCD_DEST_CLUSTER_NAME ARGOCD_NAMESPACE VKS_CONTEXT VKS_CLUSTER_NAME VKS_NAMESPACE INGRESS_CONTROLLER HARBOR_CA_FILE VKS_CA_CERT_FILE ARGOCD_CA_FILE HARBOR_URL HARBOR_USERNAME HARBOR_PASSWORD VCF_CLI_SRC_DIR VKS_CA_SHA256 HARBOR_CA_SHA256 ARGOCD_CA_SHA256 HARBOR_INSECURE ARGOCD_INSECURE MIRROR_VERIFY_FAST ARGOCD_ADMIN_PASSWORD GITEA_ADMIN_PASSWORD VCENTER_CA_FILE VCENTER_INSECURE; do
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

  # B142 — RECORD WHETHER THE SINK WAS ACTUALLY SOURCED, because that is the only honest predicate
  # for a WRITE path. `state_unset` needs to know "could this sink's pin possibly be shadowing me?",
  # and the answer is exactly "was it sourced in this process". `state_check` is NOT that predicate:
  # its idea round measured that it PERMITS on an unstamped sink AND returns 0 early when
  # `_VKS_EXPLICIT_KUBECONFIG` is empty — a READ-path concession with no meaning on a write path.
  # Measured there: with no explicit KUBECONFIG, three keys were stripped from a sink stamped for
  # ANOTHER cluster and `state_check` never refused.
  # ⚠️ UNSET means "load_env never ran in this process", and that must PROCEED — many callers
  # legitimately never call it, and a fail-closed default would break every one of them. Only an
  # explicit 0 is a refusal signal.
  if state_check; then
    # shellcheck disable=SC1090
    [ -f "$state" ] && . "$state"
    export _VKS_STATE_SOURCED=1
  else
    export _VKS_STATE_SOURCED=0
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
  # ...and the DEFAULT itself must know about the real lab. MEASURED 2026-08-12: with this line
  # reading `:-argocd`, every script's own `${ARGOCD_NAMESPACE:-${VKS_NAMESPACE:-}}` fallback was
  # DEAD CODE -- load_env runs first, so the value was always already set and the second branch
  # could never be taken. `make argocd-address` and `make argocd-password`, two lines apart in the
  # document, then disagreed: one found `cicd` (it resolves NS before... no: it did NOT -- it was
  # equally pre-empted, and only worked because its caller had VKS_NAMESPACE exported), the other
  # queried `argocd`, a namespace that does not exist on a Supervisor lab, and blamed the lab:
  #     "No ArgoCD 'admin' password is available locally for this context."
  # while argocd-initial-admin-secret sat in `cicd` the whole time.
  #
  # On a real lab ArgoCD is a SUPERVISOR SERVICE and lives in the vSphere Namespace; on KinD it is
  # installed as `argocd` and VKS_NAMESPACE is unset. One expression serves both, and it is the SAME
  # one argocd_namespace() uses -- deliberately, so a script that calls load_env and one that does
  # not can never disagree.
  export ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-${VKS_NAMESPACE:-argocd}}"

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
# argocd_namespace — where ArgoCD LIVES, resolved the SAME way by whoever installs it and whoever
# reads it. That agreement is the whole point: nine sites resolved this independently and split into
# two camps, so a READER could look somewhere the INSTALLER never wrote.
#
# MEASURED 2026-08-12, row 1 of the walk, first real-lab run of the new Step 5:
#   `make argocd-address`  -> ${ARGOCD_NAMESPACE:-${VKS_NAMESPACE:-}} -> cicd -> found it, wrote the address
#   `make argocd-password` -> ${ARGOCD_NAMESPACE:-argocd}             -> argocd -> "No ArgoCD 'admin'
#                              password is available locally for this context"
# while `argocd-initial-admin-secret` sat in `cicd` the whole time. Two lines apart in the document,
# two different answers to "which namespace", and the error blamed the LAB.
#
# PRECEDENCE, and each step earns its place:
#   ARGOCD_NAMESPACE  — explicit, always wins.
#   VKS_NAMESPACE     — the real lab: ArgoCD is a SUPERVISOR SERVICE and lands in the vSphere
#                       Namespace, so there IS no `argocd` namespace to find.
#   argocd            — KinD / self-hosted, where 07-install-argocd.sh installs it by that name and
#                       VKS_NAMESPACE is unset.
argocd_namespace() { printf '%s' "${ARGOCD_NAMESPACE:-${VKS_NAMESPACE:-argocd}}"; }

# supervisor_kubeconfig — the ONE resolver for "where is the Supervisor kubeconfig".
#
# Harbor and ArgoCD are SUPERVISOR Services, so every script that talks to them needs this, and SEVEN
# of them had hand-rolled the same chain. Two shapes were in the tree at once:
#   ${VKS_SUPERVISOR_KUBECONFIG:-${SUPERVISOR_KUBECONFIG:-<default>}}   first that is SET
#   a loop over candidates                                             first that EXISTS
# They are NOT the same, and show-dns-records.sh:26-29 records what the difference cost: .env carries
# ARGOCD_KUBECONFIG for a file Step 10 creates LATER, so the `:-` chain picked that unset-but-
# configured path, the real file lost, and the die named a file it had never looked at.
#
# FIRST THAT EXISTS, therefore. VKS_SUPERVISOR_KUBECONFIG leads because that is the name the WRITER
# (30-vks-login.sh) honours; $KUBECONFIG is LAST because from scenario-1 Step 6 onward it is the
# GUEST cluster, which has no harbor or argocd namespace at all -- so preferring it turns "wrong
# cluster" into "the service does not exist", an error naming the wrong cause.
supervisor_kubeconfig() {
  local c
  for c in "${VKS_SUPERVISOR_KUBECONFIG:-}" "${SUPERVISOR_KUBECONFIG:-}" \
           "${REPO_ROOT}/secrets/supervisor.kubeconfig" "${ARGOCD_KUBECONFIG:-}" "${KUBECONFIG:-}"; do
    [ -n "$c" ] && [ -s "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# supervisor_kubeconfig_or_die [what-needs-it]
supervisor_kubeconfig_or_die() {
  local k
  k="$(supervisor_kubeconfig)" || die "no readable Supervisor kubeconfig${1:+ (needed by $1)} — run 'make vks-login' (scenario-1 Step 3).
  Tried, in order: VKS_SUPERVISOR_KUBECONFIG, SUPERVISOR_KUBECONFIG, ${REPO_ROOT}/secrets/supervisor.kubeconfig, ARGOCD_KUBECONFIG, KUBECONFIG.
  Harbor and ArgoCD are SUPERVISOR Services; the guest cluster has neither namespace."
  printf '%s' "$k"
}

esc_curlk() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; printf '%s' "$s"; }

# is_placeholder <value> — "the operator has not supplied this yet": empty, or a `<SET-…>` token.
#
# IT LIVES HERE, NOT IN 02-env.sh, because a second consumer appeared. lib/harbor.sh's auth probe
# needs it, and 24-lab-preflight.sh sources lib/os.sh + lib/harbor.sh but NOT 02-env.sh -- so the
# call resolved to `command not found` (127). Inside an `if`, `set -e` is suspended, so it silently
# read as FALSE and the probe ran with an EMPTY password, reporting "Harbor REJECTED admin (401)"
# for a credential nobody had set. Caught 2026-08-12 by test-harbor-auth-report.sh on its first run.
#
# A FUNCTION, not a variable: load_env sources `.env` with `set -a` AFTER this library, so a
# top-level `PLACEHOLDER_TOKEN=` would be clobberable from a `.env`. A function definition is not.
is_placeholder() { case "${1:-}" in ''|'<SET-IN-.env>'|*'<SET-'*) return 0 ;; *) return 1 ;; esac; }

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
# gitea_hook_ids <hooks-json-body> <url> — print the id of every webhook whose config.url is
# EXACTLY <url>, one per line. rc 0 = parsed (zero or more ids); rc 2 = COULD NOT PARSE.
#
# ⚠️ THE TWO OUTCOMES MUST BE DISTINGUISHABLE, and that is the whole reason this is a function.
# Inline, the caller wrote `ids="$(... | jq ... 2>/dev/null || true)"` and branched on `[ -n "$ids" ]`
# — which makes "jq failed" look exactly like "there are no hooks". MEASURED 2026-08-12 on jq 1.8.2:
#   [{"id":3,"config":{"url":"U"}}]                  -> rc 0, prints 3
#   {"message":"token does not have permission"}     -> rc 5, prints NOTHING
#   <html>502 Bad Gateway</html>                     -> rc 5, prints NOTHING
#   ""            (curl failed, `|| true` swallowed) -> rc 0, prints NOTHING
# The middle two are an ERROR BODY from a failed GET. Treated as "no hooks", the caller skips the
# DELETE and POSTs anyway — leaving the STALE-SECRET hook in force AND adding a DUPLICATE, i.e. both
# of the bugs the delete+recreate exists to fix, on a transient blip. Reachable precisely in the
# EVERYTHING-exists cell, which is where that class already cost a walk row.
# A pure function so its test can EXECUTE it (the doc_robot_line_is_bad / engine_packages pattern).
gitea_hook_ids() {
  local body="$1" url="$2" out
  # An EMPTY body is not a parse failure — it is what `curl … || true` leaves after a connection
  # error, and the caller must treat it as "unknown", not "none". Reported as rc 2 for that reason.
  [ -n "$body" ] || return 2
  out="$(printf '%s' "$body" | jq -r --arg u "$url" '.[]? | select(.config.url == $u) | .id')" || return 2
  printf '%s' "$out" | grep -v '^$' || true
  return 0
}

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
# TWO BUGS LIVED IN THE PREVIOUS THREE LINES, both measured 2026-08-12, both silent:
#
#   grep -vE "^${key}=" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
#
# 1. `mv` REPLACES THE INODE, so the destination takes the TMP's mode -- which `>` created under the
#    caller's umask. Measured with a 0600 .env and umask 022: 600 -> 644. `.env` holds
#    VCF_CLI_VSPHERE_PASSWORD and HARBOR_PASSWORD, so every rewrite silently un-hardened an operator
#    who had chmod 600'd it. `cat > "$file"` truncates IN PLACE and keeps mode and ownership.
# 2. `&&` MEANT THE REWRITE WAS SKIPPED when the file contained ONLY that key: grep -v then emits
#    nothing and exits 1, so `mv` never ran, the OLD line survived, and the append left BOTH.
#    Measured: `A=1` and `A=9` in one file, plus an orphaned `.env.tmp`. It happened to work because
#    both load_env's `set -a` and make's `-include` take the LAST assignment -- luck, not design.
#
# The first test I wrote for this used a single-key file, hit bug 2, and reported the mode PRESERVED
# -- i.e. it could not see bug 1 at all. Hence a fixture with a second key below.
# assert_env_effective <KEY> <EXPECTED> [<what-we-wrote-it-for>]
#
# "I wrote it" is not "it took effect". `.env` is the LOWEST-precedence sink `load_env` sources:
# `.env.example` -> `.env` -> `.env.state` -> legacy `.env.kind` (LAST wins). So a writer that
# publishes a credential to `.env` while a HIGHER sink already holds that key reports success and
# changes nothing the next process will see.
#
# MEASURED 2026-08-16, on the DEFAULT scenario-1 admin path, with the real file shapes:
#     .env       -> HARBOR_USERNAME=robot$vks-cicd / HARBOR_PASSWORD=robotsecret
#     .env.state -> HARBOR_USERNAME=admin          / HARBOR_PASSWORD=adminpw
#     load_env   -> effective identity = [admin] / [adminpw]
# `make harbor-robot` prints "the pipeline now runs as the ROBOT, not as admin" and the pipeline
# runs as Harbor ADMIN. It does not 401 -- admin works -- so nothing surfaces it. It also defeats
# 22-harbor-robot.sh's `robot$*` re-run guard, so a second robot is minted unnoticed.
#
# ⚠️ THE `unset` BELOW IS THE WHOLE TEST, not tidiness. HARBOR_USERNAME and HARBOR_PASSWORD are in
# load_env's SELECTOR SNAPSHOT, which RESTORES the caller's exported value after sourcing. Without
# the unset, a re-resolve returns what the PARENT already had -- so the assert would pass
# unconditionally on exactly the box where the bug is live: a gate that cannot fail.
#
# It ASSERTS rather than prints: the failure is deterministic and machine-checkable, and a printed
# "effective value" is a line an operator does not read.
# env_publish KEY VALUE [why] — write KEY to .env AND clear it from the state overlay, then assert
# it actually took effect. Use this, NOT a bare `set_env_var …/.env`, whenever a step SUPERSEDES a
# value an earlier step published.
#
# THE INVARIANT, which is about SUCCESSION and not about categories:
#   a step that SUPERSEDES a value must write to the sink that currently HOLDS it — or clear that
#   sink. Writing a replacement into a lower-precedence file is not a publish; it is a no-op.
#
# It is deliberately NOT "the overlay may only hold discovered values". That per-key bucketing was
# considered and refuted: the overlay legitimately already holds a mode toggle (HARBOR_INSECURE), an
# explicit choice (INGRESS_CONTROLLER) and three GENERATED credentials — and lib/state.sh says why in
# its own words: "LIFETIME IS A PROPERTY OF THE CLUSTER, NOT OF THE KEY."
#
# WHY BOTH KEYS OF A CREDENTIAL PAIR MUST GO TOGETHER (measured): clearing only the username leaves
#   .env  = robot$vks-cicd / robotsecret     .env.state = (no username) / adminpw
#   -> effective  USER=robot$vks-cicd  PASS=adminpw     <- a robot name with the admin secret => 401
# A partial fix here manufactures an auth failure that looks like a wrong password.
env_publish() {
  local key="$1" val="$2" why="${3:-}"
  set_env_var "$key" "$val" "${REPO_ROOT}/.env"
  # Clear the overlay BEFORE asserting: the assert re-runs load_env, so it must see the final state.
  # `command -v` because os.sh is sourced by scripts that do not pull in state.sh.
  #
  # ⚠️ `|| log_warn`, NOT a bare `&&`. `state_unset` is the LAST command of an `&&` list, so under
  # `set -e` a non-zero return aborts THIS FUNCTION right here — silently skipping
  # `assert_env_effective`, which is the entire control B132/B138 exist to provide. MEASURED:
  # `f(){ echo wrote; command -v true >/dev/null && myfail; echo ASSERT-RAN; }` prints `wrote` and
  # NEVER `ASSERT-RAN`. Two live routes reach it: `state_unset`'s own `>=2` arm (a failed rewrite,
  # e.g. ENOSPC) and any future ownership gate that declines. Both are exactly the runs where the
  # state is most likely wrong, i.e. where skipping the assert costs the most.
  if command -v state_unset >/dev/null 2>&1; then
    state_unset "$key" || log_warn "could not clear the state-overlay pin on ${key} — the assert below still decides"
  fi
  assert_env_effective "$key" "$val" "$why"
}

# env_publish_all <why> <KEY> <VAL> [<KEY> <VAL> ...]
#
# PUBLISH A SET OF KEYS ALL-OR-NOTHING. Write every key and clear every overlay pin FIRST, then assert
# every key, collect every failure, and die ONCE.
#
# WHY THIS EXISTS (B138 + its round). `env_publish` is write+clear+assert for ONE key, and it returns
# non-zero when the value does not take effect. N of them in a row under `set -euo pipefail` means key
# #1 can ABORT the script with keys #2..N unwritten — and for a set that is only meaningful TOGETHER,
# a half-written set is worse than no write at all:
#
#   HARBOR_USERNAME/HARBOR_PASSWORD -> effective USER=robot$x PASS=adminpw, verbatim the "401 that
#     reads like a wrong password" that 22-harbor-robot.sh's own comment calls worse than none.
#   KUBECONFIG/VKS_CONTEXT/VKS_AUTH_METHOD -> VKS_AUTH_METHOD stranded on 'vcf', i.e. the "stop
#     talking to the Supervisor" switch NOT flipped, while .env already shows the guest kubeconfig.
#
# MEASURED, both. 27-use-guest-kubeconfig.sh got this shape inline first; a round then found the same
# unfixed shape at 22:203-204 and 28:192-193. One implementation, so a fourth site cannot diverge.
env_publish_all() {
  local why="$1"; shift
  local -a _k=() _v=()
  while [ "$#" -ge 2 ]; do _k+=("$1"); _v+=("$2"); shift 2; done
  [ "$#" -eq 0 ] || { log_error "env_publish_all: odd number of KEY VAL arguments"; return 2; }
  [ "${#_k[@]}" -gt 0 ] || { log_error "env_publish_all: no keys given"; return 2; }

  local i
  # Phase 1 — write everything and clear every pin BEFORE asserting anything.
  for i in "${!_k[@]}"; do
    set_env_var "${_k[$i]}" "${_v[$i]}" "${REPO_ROOT}/.env"
    if command -v state_unset >/dev/null 2>&1; then
      state_unset "${_k[$i]}" || log_warn "could not clear the state-overlay pin on ${_k[$i]}"
    fi
  done
  # Phase 2 — assert everything, collect, report once.
  local bad=""
  for i in "${!_k[@]}"; do
    assert_env_effective "${_k[$i]}" "${_v[$i]}" "$why" || bad="${bad} ${_k[$i]}"
  done
  [ -z "$bad" ] && return 0
  log_error "these values did NOT take effect:${bad}"
  log_error "  All were written to .env and their overlay pins cleared, so a HIGHER-precedence file"
  log_error "  is still winning — the lines above name it. Fix those and re-run; the set is only"
  log_error "  meaningful together, so a partial result is worse than none."
  return 1
}

assert_env_effective() {
  local key="$1" want="$2" why="${3:-}" got=""
  got="$( unset "$key"; load_env >/dev/null 2>&1; printf '%s' "${!key:-}" )"
  [ "$got" = "$want" ] && return 0

  # ⚠️ DISCRIMINATE BEFORE ACCUSING. Under SKIP_DOTENV=1 this re-read deliberately IGNORES `.env`
  # (:582), so the value we just wrote there cannot be seen IN THIS PROCESS — and the failure path
  # below then told the operator "a higher-precedence file already sets ${key} … remove that line"
  # while naming NO LINE, because none exists. MEASURED (B139): the identical call is rc=1 under
  # SKIP_DOTENV=1 and rc=0 with it unset; with a genuine `.env.kind` shadow the same path DOES name
  # the file. So the PRESENCE OF A NAMED FILE is the discriminator, and this re-read recovers it.
  #
  # This is NOT "special-case the message", which was the row's first prescription and is wrong: a
  # write to `.env` under SKIP_DOTENV=1 is not useless, it is UNVERIFIABLE IN-PROCESS and WILL take
  # effect on a normal run. Warning blindly throws that distinction away; so does dying.
  #
  # The callers are the scenario-1 operator steps 22-harbor-robot.sh, 27-use-guest-kubeconfig.sh and
  # 28-harbor-admin-password.sh — and the KinD e2e sets E2E_SKIP_DOTENV=1 by design, so this path is
  # reached on every such run.
  if [ "${SKIP_DOTENV:-0}" = "1" ]; then
    local got0
    # A PREFIX ASSIGNMENT on the function call, not `export` — it reaches load_env just the same
    # (bash places it in the call's environment) and, being contained in this command substitution,
    # cannot escape. `export SKIP_DOTENV=0` here made shellcheck raise SC2031 at creds.sh:378, which
    # legitimately reads the AMBIENT value: my deliberately-contained write was being reported as a
    # defect in someone else's file. Silencing it THERE would have been the wrong end.
    got0="$( unset "$key"; SKIP_DOTENV=0 load_env >/dev/null 2>&1; printf '%s' "${!key:-}" )"
    if [ "$got0" = "$want" ]; then
      log_warn "wrote ${key} to .env${why:+ (${why})}; SKIP_DOTENV=1 makes THIS process ignore .env,"
      log_warn "  so the write cannot be verified here — nothing shadows it, and a normal run WILL"
      log_warn "  see it. Re-read with .env enabled returned the value just written."
      return 0
    fi
    # else: a REAL shadow, and it outranks `.env` even with `.env` enabled. Fall through and name it.
  fi

  log_error "WROTE ${key} to .env, and it did NOT take effect${why:+ (${why})}."
  log_error "  a higher-precedence file already sets ${key}, so the next command still reads that one."
  local f
  for f in "$(state_file 2>/dev/null || printf '%s' "${REPO_ROOT}/.env.state")" "${REPO_ROOT}/.env.kind"; do
    [ -f "$f" ] || continue
    # `|| true`: grep exits 1 when the key is absent, which is the normal case for one of the two.
    local hit; hit="$(grep -nE "^${key}=" "$f" 2>/dev/null | head -1 || true)"
    [ -n "$hit" ] && log_error "    ${f}:${hit%%:*}  <- this one wins"
  done
  log_error "  remove that line (or fix the writer that put it there) and re-run."
  return 1
}

# ensure_secret_dir <path> — create it, and harden it to 0700 ONLY if it is a secrets/ dir of OURS.
#
# ⚠️ CONTAINMENT-SCOPED, NOT BLANKET, AND THAT IS THE WHOLE DESIGN. `secrets/` is born 0775 at
# umask 002, and `Makefile:132` `-include`s `secrets/.env.make` — a group-writable DIRECTORY lets
# any group member unlink-and-recreate that file regardless of its own 0600, which is make-variable
# injection. The obvious fix is to chmod 700 wherever we mkdir. That fix is REFUTED, twice over:
#
#   * `shell_rc_file()` returns `$HOME/.bashrc` (bash), `${ZDOTDIR:-$HOME}/.zshrc` (zsh),
#     `$HOME/.kshrc` (ksh) — so `dirname` at shell-init.sh is `$HOME` EXACTLY for three of the four
#     supported shells. A blanket chmod takes the operator's HOME from 755 to 700, unrequested, on
#     a machine we do not own, and irreversibly (nothing records the original mode).
#   * `set_env_var`'s own mkdir below takes `${REPO_ROOT}/.env` at three call sites, so `dirname`
#     is the REPOSITORY WORKING TREE. The normal install flow would chmod the repo root, breaking
#     any group-shared checkout or non-owner bind-mount.
#   Plus 8 of 13 sites take an OPERATOR-SETTABLE path — `KUBECONFIG` commonly resolves to
#   `~/.kube/config`, and it legally holds a COLON-SEPARATED LIST, whose `dirname` is the literal
#   string, so a blanket helper would chmod a garbage path.
#
# So: create unconditionally, harden only what resolves inside our own tree. Then every call site
# can use it without an allowlist, which is the point — an allowlist is what rotted twice already.
#
# ⚠️ `cd … && pwd -P`, NOT `realpath -m`. POSIX, and toybox's realpath is not guaranteed on Photon
# — 31-fetch-argocd-kubeconfig.sh:59 records the same choice for the same reason. This matters
# here more than anywhere: B174's two previous fixes BOTH died on a GNU-only flag that toybox
# accepts and ignores (`mkdir -p -m`, then `install -d -m`), each passing on every dev box and
# doing nothing on the PRIMARY air-gap OS. The mkdir above is what makes `cd` viable where
# `realpath -m` would otherwise be needed for a not-yet-existing path.
#
# ⚠️ chmod failure WARNS, it does not abort. `mkdir -p "$d" && chmod 700 "$d"` as a function TAIL
# returns chmod's status, so an EPERM on a directory owned by someone else (a sudo-created
# secrets/, a shared CI checkout, a rootless-podman uid mapping) would kill the caller under
# `set -e` — a hard-fail the bare `mkdir -p` never had. Hardening is best-effort by construction.
ensure_secret_dir() {
  local d="${1:?ensure_secret_dir: a path is required}" rp
  if ! mkdir -p "$d"; then return 1; fi
  rp="$(cd "$d" 2>/dev/null && pwd -P)" || rp=""
  if [ -z "$rp" ]; then
    log_warn "ensure_secret_dir: created '${d}' but could not resolve it — left unhardened"
    return 0
  fi
  # An unset REPO_ROOT would make the patterns below `/secrets/`, which could match a real
  # system path. Refuse to guess: create only.
  [ -n "${REPO_ROOT:-}" ] || return 0
  case "${rp}/" in
    "${REPO_ROOT}"/secrets/|"${REPO_ROOT}"/*/secrets/)
      chmod 700 "$rp" || log_warn "ensure_secret_dir: could not harden ${rp} (not the owner?) — leaving its mode as-is" ;;
    *) : ;;
  esac
}

set_env_var() {
  local key="$1" val="$2" file="${3:?set_env_var: a SINK is required — use state_set (the stamped overlay) or pass an explicit file}"
  mkdir -p "$(dirname "$file")"; touch "$file"
  # 0600 BEFORE ANY CONTENT IS WRITTEN. `touch` inherits the ambient umask, and the comment above is
  # about the OPPOSITE half of this problem: it explains why `cat > "$file"` (truncate in place) is
  # used instead of `mv`, so a rewrite cannot UN-harden an operator who had chmod 600'd the file.
  # Preserving the mode fixed un-hardening; it also faithfully preserves a LOOSE one, and no umask
  # can repair that — MEASURED: umask 077 over a pre-existing 0644 file still yields 0644.
  # Forcing 600 only ever TIGHTENS, so it agrees with that comment's intent rather than contradicting
  # it. Chmod must be HERE and not at the end: a late chmod leaves a window in which the file already
  # holds the credential at 0664.
  #
  # This repo already documents this exact trap TWICE and did not sweep it —
  # `22-harbor-robot.sh` and `lib/vcenter.sh` both `rm -f` FIRST because "umask 077 only applies when
  # the file is CREATED … the secret would land world-readable WHILE THIS CODE STILL READ AS SAFE".
  # Both protect a TRANSIENT copy; this is the DURABLE store they read the credential out of.
  chmod 600 "$file" 2>/dev/null || true
  local tmp; tmp="$(mktemp)"
  # `|| true`: grep -v exits 1 when it emits NOTHING, which is the normal single-key case.
  grep -vE "^${key}=" "$file" > "$tmp" 2>/dev/null || true
  # QUOTE ONLY WHAT NEEDS IT, and quote it for the SHELL.
  #
  # MEASURED 2026-08-12, row 1 of the walk: `make harbor-robot` published
  #     HARBOR_USERNAME=robot$vks-cicd
  # unquoted, and the document's own `set -a; . ./.env; set +a` -- which it runs at Steps 3, 6, 8
  # and 10 -- then died with `.env: line 1450: vks: unbound variable`. SEVEN of the run's eight
  # failed blocks were that one line: Steps 10, 11, 12 and 13 in their entirety. 22-harbor-robot.sh
  # already single-quotes the same credential into its SECRETS file, with a seven-line comment
  # explaining why; it published to .env through here, twenty lines later, and here did not.
  #
  # ONLY WHEN NEEDED, because `.env` has TWO parsers and they disagree. `-include .env` makes these
  # make variables too, and make takes the quotes LITERALLY (measured: unquoted -> `robotks-cicd`,
  # single-quoted -> `'robotks-cicd'` — it eats `$vks` either way, so NO shape is make-correct).
  # Blanket-quoting would therefore break the values make DOES expand, e.g. `$(HARBOR_URL)` at
  # Makefile:471. Quoting only the values that would otherwise break `source` keeps every plain
  # value byte-identical, so make is unaffected.
  #
  # A value that needs quoting is SHELL-CORRECT and MAKE-MANGLED. That is a deliberate trade:
  # verified 2026-08-12 that no recipe expands HARBOR_USERNAME/HARBOR_PASSWORD. The ONE make-expanded
  # key that could ever need quoting is HARBOR_CA_FILE (06-install-harbor.sh derives it from
  # REPO_ROOT, so a space in the checkout path would quote it and make would keep the quotes
  # literally, Makefile:472). Every other make-expanded writer key — HARBOR_URL, ARGOCD_LB_IP,
  # ARGOCD_SERVER — is alphanumeric+`.:` and classifies BARE.
  #
  # AN ALLOW-LIST, NOT A DENY-LIST. The first version of this listed the characters it knew were
  # dangerous ($ ` " ' \ and whitespace) and MISSED EIGHT — measured, on this exact function:
  #     set_env_var K 'a;id;b'   -> K=a;id;b       -> `set -a; . .env` EXECUTED `id`
  #     set_env_var K 'a>vic'    -> K=a>vic        -> sourcing TRUNCATED ./vic to 0 bytes
  #     set_env_var K '~/foo'    -> K=~/foo        -> silently became /home/<user>/foo
  #     a|b, a&b, a(b)c          ->                -> the variable ended up UNSET
  # A deny-list of shell metacharacters can only ever rot open; the set of SAFE characters cannot.
  # `""` must stay BARE: Makefile:480's `$(if $(HARBOR_CA_FILE),…)` sees `''` as non-empty and flips.
  case "$val" in
    "")                        printf '%s=%s\n'  "$key" "$val"              >> "$tmp" ;;
    *[!A-Za-z0-9_.:/@+=-]*|~*) printf "%s='%s'\n" "$key" "$(esc_sq "$val")" >> "$tmp" ;;
    *)                         printf '%s=%s\n'  "$key" "$val"              >> "$tmp" ;;
  esac
  cat "$tmp" > "$file"          # NOT mv — preserves the destination's mode and ownership
  rm -f "$tmp"
  # Sweep the LEGACY orphan. The old `> "${file}.tmp" && mv` left one behind on every single-key
  # rewrite (the && blocked the mv), so an operator's box can be carrying a stale `.env.tmp` —
  # world-readable, and holding a COPY of the file minus one line, i.e. their other secrets.
  rm -f "${file}.tmp"
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
# githubusercontent 429s: an outer exponential-backoff loop (capped) — curl's own --retry was REMOVED
# 2026-08-17 because it compounded with the outer backoff into 540s of sleep; see http_get_retry below
# connect timeout. MEASURED: >2 minutes of retrying on a SINGLE manifest URL, and there are several of
# them before the first image is even touched. The operator then gets a curl error naming
# storage.googleapis.com — never "this box has no internet, you want the sneakernet flow".
#
# The resilience is correct for a FLAKY network and exactly wrong for an ABSENT one. So: probe once,
# cheaply, up front, and say the thing that is actually true.
# _curl_rc_label <exit-code> — name the FAILURE MODE, so a no-internet report is diagnosable.
# MEASURED (curl 8.5.0): 6 = DNS unresolvable (6 ms) · 7 = connect refused (5 ms) · 28 = timed out
# (5009 ms, i.e. the --connect-timeout expiry) · 22 = an HTTP error status · 35/60 = TLS. These
# already separate DNS from routing from firewall from proxy-MITM, which is every question an
# operator asks after "NO INTERNET" — and the old die answered none of them.
_curl_rc_label() {
  case "${1:-}" in
    0)     printf 'answered' ;;
    6)     printf 'DNS — could not resolve the host' ;;
    7)     printf 'connect refused / no route' ;;
    28)    printf 'TIMED OUT — nothing answered in time (blackhole or firewall drop)' ;;
    35|60) printf 'TLS failed — a proxy presenting its own certificate?' ;;
    22)    printf 'an HTTP error status, which still PROVES internet' ;;
    *)     printf 'curl exit %s' "${1:-?}" ;;
  esac
}

require_internet() {
  local what="${1:-this step}" host code rc err diag="" ok=1 errf
  # ⚠️ `-f` IS DELIBERATELY ABSENT — DO NOT ADD IT BACK. It used to read `curl -sSf`, and that made
  # this a SINGLE-HOST check on github.com while claiming to be a two-host one:
  # `storage.googleapis.com` answers `HEAD /` with **HTTP 400**, and `-f` turns any 4xx into exit 22.
  # MEASURED 2026-08-18, 5/5, on a box with working internet (github 200 in the same second). So the
  # advertised redundancy did not exist, and any 403/429/5xx from github — the abuse-detection class
  # `http_get_retry` below already fights — read as "this box has no internet".
  #
  # THE PREDICATE IS "DID ANYTHING ANSWER", NOT "DID IT ANSWER 2xx". An HTTP status line of any kind
  # requires DNS + TCP + TLS + a full round trip to SUCCEED, so a 400 is POSITIVE PROOF of internet.
  # `%{http_code}` is `000` exactly when curl never got a status line. Measured 4/4:
  #   storage 400 -> internet · github 200 -> internet · NXDOMAIN -> 000/rc6 · blackhole -> 000/rc28.
  #
  # No retry, deliberately (B181): a bounded retry re-runs the predicate, and the predicate was the
  # bug. Revisit only when an occurrence arrives carrying a mode from _curl_rc_label — 28 might argue
  # for one, 6 argues for fixing the resolver, and 22 is the class this comment just closed.
  # ⚠️ `|| true` IS LOAD-BEARING, and /dev/null IS THE FALLBACK. MEASURED: under `set -euo pipefail`
  # a FAILED mktemp (read-only or full /tmp -- exactly the kind of box this function exists to
  # diagnose) makes the ASSIGNMENT non-zero and kills the script, so the operator would get mktemp's
  # message INSTEAD of the air-gap guidance below. Degrading to /dev/null keeps the probe working and
  # only loses curl's stderr text; the verdict and the per-host rc are unaffected.
  errf="$(mktemp "${TMPDIR:-/tmp}/internet-probe.XXXXXX" 2>/dev/null || true)"
  [ -n "$errf" ] || errf=/dev/null
  for host in https://storage.googleapis.com https://github.com; do
    code="$(curl -sS -o /dev/null --head \
              --connect-timeout "${INTERNET_PROBE_TIMEOUT_SECONDS:-5}" \
              --max-time "${INTERNET_PROBE_MAX_TIME_SECONDS:-10}" \
              --retry 0 -w '%{http_code}' "$host" 2>"$errf")" && rc=0 || rc=$?
    # KEEP curl's own message (F3): the old form passed `-S` to enable it and then `2>/dev/null`'d
    # it away, so the code asked for the diagnosis and deleted it.
    err=""
    if [ -s "$errf" ]; then err="$(tr -d '\r' <"$errf" | tr '\n' ' ')"; fi
    diag="${diag}
      ${host#https://} -> HTTP ${code:-000}, curl rc=${rc} ($(_curl_rc_label "$rc")${err:+ — ${err}})"
    if [ "${code:-000}" != 000 ]; then ok=0; break; fi
  done
  # NEVER `rm` the fallback: as root, `rm -f /dev/null` DELETES the device node (measured: it is a
  # character special file, and rm would remove it). `rm -f ""` is harmless (rc=0) but the guard
  # covers both.
  [ "$errf" = /dev/null ] || rm -f "$errf"
  if [ "$ok" -eq 0 ]; then return 0; fi
  die "NO INTERNET on this box — and ${what} needs it.

  What each probe actually saw:${diag}

  You are on the wrong flow for this box. Nothing here can download anything.

  If NO SINGLE BOX reaches both the internet and Harbor, use the SNEAKERNET flow (docs/sneakernet.md):
      on a box WITH the internet :  make mirror-pull && make builder-build && make bundle
      carry the .tar + .sha256 + this repo across
      on THIS box               :  make bundle-load BUNDLE_TARBALL=... && make mirror-push && make mirror-verify
                                   then: make platform gitops && make install-ingress && make verify

  Do NOT run 'make install-all' here: it starts with 'mirror', which downloads from the internet.
  (If you believe this box IS online, read the per-probe lines above: a DNS line means the resolver,
   a TIMED OUT line means a firewall or a blackhole route, a TLS line means an intercepting proxy.)"
}

# http_get_retry <url> <dest> — download <url> to <dest>, resilient to transient
# failures (notably raw.githubusercontent.com HTTP 429 rate-limiting). An outer
# exponential-backoff loop owns ALL retry and ALL backoff. Tunables come from
# .env.example (HTTP_GET_* / CURL_MAX_TIME_SECONDS). Writes to <dest> only on
# success (curl -o truncates, but the outer loop re-fetches); dies after the
# retry budget is exhausted.
#
# ⚠️ CURL'S OWN `--retry` IS DELIBERATELY ABSENT — DO NOT ADD IT BACK. It used to
# read `--retry 3 --retry-delay "$delay"`, and `$delay` is the OUTER loop's
# DOUBLING value, so the two compounded: the inner curl slept 3x(5+10+20+40+80)
# and the outer loop a further (5+10+20+40) = 540s of PURE SLEEP against a
# connection refused in 0 ms. MEASURED 2026-08-17 (adversary-bash-git-cli):
# http://127.0.0.1:9/x -> 9m00.5s; blackhole https://10.255.255.1/x -> 12m20.5s.
# None of it was transfer. Three of the five call sites are on `make deps`, which
# `scenario-1.md:140` WALKS, and `walk-doc.sh` has no per-block timeout to bound
# it. One loop owns backoff, or they multiply.
#
# ⚠️ WHAT REMOVING THE INNER --retry COSTS — stated because it is NOT free
# (MEASURED 2026-08-17, implementation round). `--retry-all-errors` was what made
# curl retry a REFUSED CONNECTION at all: plain `--retry 3` against a refusal
# retries ZERO times (measured 0s). Two things go with it:
#   1. `Retry-After` COMPLIANCE. curl honours the header, and it OVERRIDES
#      --retry-delay in BOTH directions — measured: server 30 / --retry-delay 5
#      -> curl slept 30; server 3 / --retry-delay 20 -> curl slept 3. The outer
#      loop cannot see the header, so a 429 carrying `Retry-After: 60` is no
#      longer obeyed. The capped backoff below is the replacement.
#   2. ATTEMPT COUNT: 5 outer x 4 requests = 20 became 5, and THE CAP DOES NOT
#      RESTORE THEM. The loop is bounded by HTTP_GET_RETRIES, not by the budget,
#      so capping the delay only makes a failure land SOONER (MEASURED: 541s ->
#      65s = sleeps 5+10+20+30 over exactly 5 attempts). Raising HTTP_GET_RETRIES
#      is the knob if a site needs more; do NOT read the cap as buying attempts.
#      (The first draft of this comment claimed "~11 attempts inside the budget",
#      copied from the review that prescribed the cap. It is false — the loop
#      never consults the budget to decide whether to KEEP GOING, only to STOP.)
#
# ⚠️ THE BUDGET IS NOT A WHOLE-CALL CEILING, and claiming so would be a false fact
# inside a control. It is checked BEFORE each attempt and BEFORE each sleep, never
# DURING a transfer, so an attempt begun at budget-1 still runs its full
# --max-time. TRUE worst case:
#     HTTP_GET_TOTAL_BUDGET_SECONDS + HTTP_GET_MAX_TIME_SECONDS
# MEASURED: budget=10 max-time=30 against a hanging server -> 30s elapsed, 3x the
# bound the old comment stated.
#
# The budget DEFAULT is DERIVED from --max-time (5x) so a call site that widens
# one widens the other. 00-install-prereqs.sh raises HTTP_GET_MAX_TIME_SECONDS to
# 900 for the 238 MiB argocd download; a FIXED 300s budget there made retries
# STRUCTURALLY IMPOSSIBLE — one attempt, then a die naming a knob the operator
# never set while the one they did set went unmentioned.
# assert_k8s_manifest FILE URL — the file we just downloaded must BE a Kubernetes manifest.
#
# WHY THIS EXISTS, measured 2026-08-18 against real curl 8.5.0 (B181 decision round):
# `http_get_retry` uses `curl -fsSL`, so a filtering proxy's 403/404/502 fails the transfer,
# retries 5x, and dies loudly naming the URL — correct, and already handled. But a CAPTIVE
# PORTAL answers **200** with an HTML block page: curl succeeds, rc=0, in 0.0s, and the page
# is written AS THE MANIFEST. `mirror_collect_images` then silently yields only images.txt
# entries (the Tekton controller images vanish), and in the sneakernet flow that bundle is
# CARRIED ACROSS THE AIR GAP before `kubectl apply` finally fails on HTML.
#
# This assertion cannot rot: it is a claim about the contract of the file WE REQUIRE, not
# about a third party's incidental behaviour. If it ever misfires, the file genuinely is not
# a manifest — a real bug either way. A `-L` 302-to-portal lands on the same 200 and is
# caught identically.
#
# RED/GREEN-proven on the REAL artifacts (B181): GREEN 12/12 files in bundle/manifests/ carry
# a column-0 `apiVersion:`; RED 4/4 portal bodies caught (HTML block page, <!DOCTYPE html>
# sign-in, "Access Denied by Policy", {"error":"blocked"}).
assert_k8s_manifest() {
  local file="$1" url="${2:-<unknown url>}"
  [ -s "$file" ] || die "downloaded ${url} but ${file} is empty — nothing was written."
  # Column 0 on purpose: an indented `apiVersion:` is a nested field, not a document header.
  grep -qE '^apiVersion:' "$file" && return 0
  die "${url} answered, but the body is NOT a Kubernetes manifest (no column-0 'apiVersion:' in ${file}).
  A captive portal or filtering proxy is answering for this host instead of the origin —
  it returned a page (a block page, a sign-in redirect, or a JSON error) with HTTP 200, so
  the download SUCCEEDED and wrote that page where a manifest belongs.
  This is NOT an air gap: something answered. Check whether this box is behind a proxy that
  intercepts TLS, then re-run. First 3 lines of what arrived:
$(head -3 "$file" 2>/dev/null | sed 's/^/    /')"
}

# _http_fail_hint CODE CURL_RC — turn a status into the ONE sentence that tells an operator whose
# problem this is. The four buckets are not decoration: they are the actual fork in what to do next,
# and the undifferentiated "failed to download <url>" gave the operator none of it.
_http_fail_hint() {
  case "$1" in
    # ⚠️ UNREACHABLE from http_get_retry today (MEASURED): the budget is checked at the TOP of
    # each iteration, so at i=1 elapsed=0 and one attempt always runs, always setting last_code.
    # Kept as a guard for a future caller that pre-checks a budget; it is not dead by accident.
    none) printf 'no request completed — the time budget expired before an attempt finished' ;;
    000)  printf 'HTTP 000 (curl rc %s) — NO response at all: DNS, no route, refused, or a timeout. This is THIS BOX, not the server' "$2" ;;
    4*)   printf 'HTTP %s (curl rc %s) — the server ANSWERED and refused: a filtering proxy, an expired credential, or a moved artifact. Not a connectivity fault, so retrying will not help' "$1" "$2" ;;
    5*)   printf 'HTTP %s (curl rc %s) — the server answered with an error. Upstream; usually transient' "$1" "$2" ;;
    *)    printf 'HTTP %s (curl rc %s)' "$1" "$2" ;;
  esac
}

http_get_retry() {
  local url="$1" dest="$2"
  local attempts="${HTTP_GET_RETRIES:-5}"
  local delay="${HTTP_GET_RETRY_DELAY_SECONDS:-5}"
  local maxtime="${HTTP_GET_MAX_TIME_SECONDS:-60}"
  local maxdelay="${HTTP_GET_RETRY_MAX_DELAY_SECONDS:-30}"
  local budget="${HTTP_GET_TOTAL_BUDGET_SECONDS:-$(( maxtime * 5 ))}"
  require_cmd curl
  # A non-numeric value makes `[ "$x" -ge "$budget" ]` error, `[` return 2, the
  # `if` take the FALSE branch and the guard silently VANISH. MEASURED with `5m`:
  # 5 lines of "integer expression expected" and no enforcement at all.
  case "$budget"   in ''|*[!0-9]*) die "HTTP_GET_TOTAL_BUDGET_SECONDS must be whole seconds, got '${budget}'" ;; esac
  case "$maxdelay" in ''|*[!0-9]*) die "HTTP_GET_RETRY_MAX_DELAY_SECONDS must be whole seconds, got '${maxdelay}'" ;; esac
  # B181 C2 — CARRY THE STATUS INTO THE DIE. Every die below used to name only the URL, the
  # elapsed time and the budget, so an operator got "failed to download <url>" for four
  # materially different faults: a filtering proxy (403), a moved artifact (404), an upstream
  # outage (502) and a box with no route at all (000). The first three are somebody else's
  # problem and the fourth is theirs, and nothing in the message told them which.
  #
  # This matters most where NOTHING ELSE reports it: 00-install-prereqs.sh and
  # 07-install-argocd.sh call http_get_retry WITHOUT ever calling require_internet, so its die
  # is the operator's only signal.
  #
  # MEASURED 2026-08-18, curl 8.5.0, against a real local server — `-w` DOES emit on the
  # FAILING path under `-f`, which is the whole premise:
  #     /ok       rc=0   w-stdout='200'   dest=9B
  #     /portal   rc=0   w-stdout='200'   dest=28B     <- 200 body, see assert_k8s_manifest
  #     /missing  rc=22  w-stdout='404'   dest=absent  <- --remove-on-error did its job
  #     refused   rc=7   w-stdout='000'
  # `-o "$dest"` sends the BODY to the file and `-s` silences progress, so stdout carries the
  # -w field and nothing else; `-S` keeps curl's own error on stderr, which $( ) does not eat.
  local i started now elapsed
  local last_code="none" last_rc="none"
  started=$(date +%s)
  for (( i = 1; i <= attempts; i++ )); do
    now=$(date +%s); elapsed=$(( now - started ))
    # 0 = UNLIMITED, matching curl's own convention for --max-time.
    if [ "$budget" -gt 0 ] && [ "$elapsed" -ge "$budget" ]; then
      die "failed to download ${url}: gave up after ${elapsed}s (HTTP_GET_TOTAL_BUDGET_SECONDS=${budget}), $(( i - 1 )) attempt(s).
  last: $(_http_fail_hint "$last_code" "$last_rc")"
    fi
    # --remove-on-error: without it a truncated body is LEFT ON DISK, and
    # 07-install-argocd.sh:109 gates on `[ ! -s "$MANIFEST_FILE" ]` — a 10-byte
    # partial is NON-empty, so the next run logs "using cached manifest" and
    # `kubectl apply`s truncated YAML. MEASURED.
    # `&& rc=0 || rc=$?`, never `; rc=$?` after an assignment — the documented capture-then-test
    # form, so this cannot trip a caller's `set -e` from inside the substitution.
    local _code _rc
    _code="$(curl -fsSL --remove-on-error -w '%{http_code}' \
         --connect-timeout "${HTTP_CONNECT_TIMEOUT_SECONDS:-10}" \
         --max-time "$maxtime" \
         -o "$dest" "$url")" && _rc=0 || _rc=$?
    if [ "$_rc" -eq 0 ]; then
      return 0
    fi
    # Remember the LAST failure, not the first: a 000 that becomes a 403 on retry means the box
    # got a route and then hit a filter, and the second fact is the actionable one.
    # ⚠️ curl's stdout is LOAD-BEARING here, and a ~/.curlrc can contaminate it: with
    # `dump-header = -` the capture becomes a multi-line header dump (MEASURED). Do NOT "fix" that
    # with `-q` — that would also disable a .curlrc an operator legitimately uses for a corporate
    # proxy, which is live configuration on exactly the boxes this runs on. Bound it instead: a
    # non-numeric value stays UN-BUCKETABLE (it falls to the `*)` arm and is printed as-is) but
    # cannot flood the die.
    case "$_code" in ''|*[!0-9]*) _code="$(printf '%.24s' "$_code" | tr -d '\n')" ;; esac
    last_code="${_code:-000}"; last_rc="$_rc"
    if [ "$i" -lt "$attempts" ]; then
      now=$(date +%s); elapsed=$(( now - started ))
      # Do not start a sleep we cannot finish inside the budget.
      if [ "$budget" -gt 0 ] && [ "$(( elapsed + delay ))" -ge "$budget" ]; then
        die "failed to download ${url}: gave up after ${elapsed}s (HTTP_GET_TOTAL_BUDGET_SECONDS=${budget}), ${i} attempt(s).
  last: $(_http_fail_hint "$last_code" "$last_rc")"
      fi
      log_warn "download failed (attempt ${i}/${attempts}): ${url} — retrying in ${delay}s"
      sleep "$delay"
      delay=$(( delay * 2 ))
      # `if`, NOT `[ ... ] && delay=...` — that is the A&&B-as-loop-body shape
      # this repo has a rule about: when the test is FALSE the list returns 1,
      # which is the loop body's status, and reasoning about whether `set -e`
      # fires there is exactly the thing the rule says not to do.
      if [ "$delay" -gt "$maxdelay" ]; then delay="$maxdelay"; fi
    fi
  done
  die "failed to download ${url} after ${attempts} attempts.
  last: $(_http_fail_hint "$last_code" "$last_rc")"
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

# harbor_scheme — http when HARBOR_INSECURE=1, https otherwise.
#
# ⚠️ THIS EXISTS BECAUSE THE PROBE BELOW HARDCODED `https://`, AND WAS THEREFORE PERMANENTLY BLIND
# IN THE INSECURE LEG. `06-install-harbor.sh:16` documents HARBOR_INSECURE=1 as "plain HTTP
# LoadBalancer at the LB IP", and `_harbor_ca_args` answers that mode with `-k` — so the probe spoke
# TLS to a plain-HTTP listener. MEASURED:
#
#     curl -k https://<plain-http-listener>/   ->   http_code=000, rc=35 (wrong version number)
#
# and `_harbor_auth_code` collapses any non-zero rc to 000, so `harbor_auth_verdict` returned
# `unchecked:…` FOREVER in that mode — a credential gate that never reaches a verdict, in the leg
# the KinD e2e exercises. `02-env.sh:349` had the correct derivation all along; this is that same
# rule, single-sourced, so the two cannot drift again.
harbor_scheme() { if [ "${HARBOR_INSECURE:-0}" = 1 ]; then printf 'http'; else printf 'https'; fi; }

# IT LIVES HERE, NOT IN lib/harbor.sh, for the reason `is_placeholder` does (see above): a SECOND
# consumer appeared. 02-env.sh sources lib/os.sh + lib/tls.sh but NOT lib/harbor.sh, so defining
# it there and calling it from 02-env.sh is `harbor_scheme: command not found` under
# `set -euo pipefail` — the moment HARBOR_URL is set, which is the only path that reaches it.
# Caught by checking the scope rather than by running env-validate, whose Harbor block SKIPS
# when HARBOR_URL is unset: the edit would have passed a green run and failed on a real lab.

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
      local _cls; _cls="$(classify_argocd_failure "$_err")"
    rm -f "$_err"; printf 'unknown|%s' "$_cls"; return 0
  fi
  rm -f "$_err"
  case "$_out" in yes) printf 'yes|' ;; no) printf 'no|' ;; *) printf 'unknown|UNPARSEABLE' ;; esac
}

# classify_argocd_failure <errfile> — classify_kube_failure, REFINED for argocd's own vocabulary.
#
# WHY IT IS A FUNCTION NOW. This logic lived INSIDE argocd_can_i, reachable by exactly one caller.
# MEASURED 2026-08-17 by an implementation-round adversary driving the real script: the two argocd
# failure sites in 70-configure-argocd.sh called `classify_kube_failure` RAW, so an EXPIRED TOKEN —
# which argocd_can_i's own comment calls "the most common argocd fault" — classified UNKNOWN and was
# reported as an AppProject/RBAC question at one site and as "repo-server cannot reach Gitea" at the
# other: a claim about a DIFFERENT COMPONENT. One implementation, three callers.
#
# ⚠️ FOR argocd CALLERS ONLY. `k_can_i` is a KUBECTL probe and must keep calling classify_kube_failure
# directly — the two call sites look identical and are one function apart. (I edited the wrong one
# first; the tell was k_can_i losing its `rm -f`.)
#
# argocd is a THIRD vendor vocabulary — JSON, not kubectl's plain text — so the shared classifier
# misses its shapes. AUTH IS TESTED BEFORE TRANSPORT so a token message is not swallowed by the
# connection arm.
classify_argocd_failure() {
  local _err="${1:-/dev/null}" _cls
  _cls="$(classify_kube_failure "$_err")"
  # KUBECONFIG_UNUSABLE / NO_KUBE_TARGET are KUBECTL verdicts and mean nothing for an argocd probe
  # (argocd uses no kubeconfig), so they must not BYPASS the refinement the way a relevant class
  # would. Without this, an argocd config error reading "stat …: no such file" would be reported to
  # the operator as a problem with their KUBE configuration.
  if [ "$_cls" = UNKNOWN ] || [ "$_cls" = KUBECONFIG_UNUSABLE ] || [ "$_cls" = NO_KUBE_TARGET ]; then
    if command grep -qiE 'Unauthenticated|invalid session token|token is expired|Unauthorized' "$_err" 2>/dev/null; then
      _cls=UNAUTHORIZED
    elif command grep -qiE 'failed to establish connection|connection refused|x509|tls' "$_err" 2>/dev/null; then
      _cls=UNREACHABLE
    fi
  fi
  printf '%s' "$_cls"
}

classify_kube_failure() {
  local errfile="${1:-/dev/null}" e=""
  [ -r "$errfile" ] && e="$(cat "$errfile" 2>/dev/null || true)"
  # ⚠️ ARM ORDER IS PART OF THE CONTRACT. First match wins, so an arm that can match text belonging
  # to another class SHADOWS every arm below it. UNAUTHORIZED used to sit second and did exactly
  # that — see the 401 note below; a genuine FORBIDDEN was classified UNAUTHORIZED.
  case "$e" in
    # KUBECONFIG_UNUSABLE: something the kube configuration NAMES is missing, unreadable or malformed,
    # so NOTHING WAS EVER DIALLED. This must
    # not be reported as a reachability verdict. MEASURED against a genuinely down lab: kubectl
    # emitted `error: stat ./secrets/<x>.kubeconfig: no such file or directory`, no arm matched, and
    # argocd-preflight rendered it as "the GUEST cluster did not answer ... and the error is not one
    # we classify" — a claim about the network from an error about the filesystem. Verified against
    # ⚠️ THE PATTERNS ARE DELIBERATELY NARROW. A bare `*"no such file or directory"*` SHADOWS the
    # auth classes below: measured, a Forbidden or Unauthorized message carrying any stray
    # `open /x: no such file or directory` line classified as this instead — the arm sits first, and
    # first match wins. Anchoring on kubectl's own config vocabulary keeps the position (which is
    # correct — a config fault precedes any dial) without swallowing anything else. Verified over a
    # 9-case corpus: Forbidden/Unauthorized-with-stray-file-line now classify correctly, all five
    # real missing-file shapes still classify here, and `no such host` stays UNREACHABLE.
    # The NAME says "unusable", not "missing", because it also covers a PRESENT but malformed file
    # and a missing exec credential plugin — see the consumers' wording.
    *"stat "*"no such file or directory"*|*"error loading config file"*|\
    *"unable to read certificate-authority"*|*"unable to read client-cert"*|*"unable to read client-key"*|\
    *"getting credentials: exec:"*)                                              printf 'KUBECONFIG_UNUSABLE' ;;
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
    # ⚠️ THE LAST TOKEN IS kubectl's TERSE FORM, AND IT IS NOT REDUNDANT. `kubectl version` skips
    # discovery, so it prints ONLY "The connection to the server H:P was refused - did you specify
    # the right host or port?" — which contains NEITHER "connection refused" (kubectl writes
    # "was refused") NOR "dial tcp". MEASURED: that string classified UNKNOWN while the klog form
    # from `cluster-info`/`get nodes`/`auth can-i`/`api-resources` classified UNREACHABLE.
    #
    # ⚠️ MATCH THE FORMAT-STRING SUFFIX, *NOT* "was refused". MEASURED over a 13-case corpus: the
    # suffix is identical to the old behaviour on every input except the target one, while adding
    # "was refused" INVERTS an auth verdict — this arm sits ABOVE UNAUTHORIZED/FORBIDDEN, so any
    # auth text containing that generic English substring flips to a network cause. The suffix is a
    # kubectl internal format string and cannot appear in prose; "was refused" can.
    # NO_KUBE_TARGET — kubectl NEVER HAD A TARGET. It falls back to http://localhost:8080 when the
    # config is missing/empty or no current-context is set, then reports a connection failure to it.
    # ⚠️ THIS ARM MUST SIT ABOVE UNREACHABLE, and it is why the KUBECONFIG_UNUSABLE arm alone was
    # not enough. MEASURED (kubectl 1.36.3), and the asymmetry is the whole point:
    #     --kubeconfig <missing>   -> "error: stat …: no such file or directory"  -> KUBECONFIG_UNUSABLE
    #     KUBECONFIG=<missing>     -> "…server localhost:8080 was refused"        -> UNREACHABLE  ← WRONG
    # Three of the four consumers use the ENV form, so the class added to fix "a filesystem error
    # reported as a network claim" could not fire at the sites that needed it most.
    # A real lab endpoint is never localhost:8080; the one false positive is an operator genuinely
    # using `kubectl proxy`, so the message hedges rather than asserting.
    *"localhost:8080"*|*"127.0.0.1:8080"*)                                       printf 'NO_KUBE_TARGET' ;;
    *"no route to host"*|*"connection refused"*|*"i/o timeout"*|*"dial tcp"*|*"no such host"*|\
    *"did you specify the right host or port"*) \
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

# ---------------------------------------------------------------------------------------------
# shell_rc_file / shell_activate_line — do NOT make the operator work out which shell they use.
#
# Telling a reader `>> ~/.bashrc   # or ~/.zshrc` hands them a decision they should never have been
# asked to make, and gets it wrong for anyone on zsh (the default on macOS and on plenty of Linux
# boxes, including this repo's own author). $SHELL is the login shell from /etc/passwd, which is
# exactly the right question: "which rc file does MY interactive shell read".
#
# fish is not a bourne shell and needs a different activation syntax entirely, which is precisely
# the kind of thing a generic instruction gets wrong.
shell_rc_file() {
  case "$(basename "${SHELL:-}" 2>/dev/null)" in
    zsh)  printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) printf '%s' "$HOME/.bashrc" ;;
    fish) printf '%s' "$HOME/.config/fish/config.fish" ;;
    ksh)  printf '%s' "$HOME/.kshrc" ;;
    *)    printf '%s' "" ;;          # unknown: the caller must degrade, not guess
  esac
}

# shellcheck disable=SC2016  # single quotes are the POINT: this string is WRITTEN INTO the
# operator's rc file and must be expanded by THEIR shell at login, not by us at write time.
shell_activate_line() {
  case "$(basename "${SHELL:-}" 2>/dev/null)" in
    fish)          printf '%s' 'mise activate fish | source' ;;
    zsh)           printf '%s' 'eval "$(mise activate zsh)"' ;;
    bash|ksh)      printf '%s' 'eval "$(mise activate bash)"' ;;
    *)             printf '%s' "" ;;
  esac
}
