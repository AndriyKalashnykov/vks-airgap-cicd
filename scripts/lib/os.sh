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
    log_error "  Concurrent pushes CORRUPT the registry's blob store (MANIFEST_UNKNOWN/BLOB_UNKNOWN later,"
    log_error "  recoverable only by rebuilding it). Wait for it to finish, then re-run."
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
  have "$cmd" && return 0
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
  # (uncommented, line 73) was sourced back over it and you mirrored to the default while believing you
  # had switched — the same shape as the KUBECONFIG bug that let a command run against the wrong cluster.
  # It surfaced in the jump-box matrix: the container is handed `-e HARBOR_URL=<the LB IP>`, load_env
  # replaced it with `harbor.vks.local`, and all four legs died resolving a hostname that exists nowhere.
  for _sel in KUBECONFIG ARGOCD_KUBECONFIG GUEST_KUBECONFIG ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_DEST_SERVER ARGOCD_DEST_CLUSTER_NAME ARGOCD_NAMESPACE VKS_CONTEXT HARBOR_CA_FILE HARBOR_URL; do
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
pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
}

# ---------------------------------------------------------------------------
# The stamped state sink (state_file / state_set / state_check / state_stamp / state_archive).
# Sourced LAST: state.sh uses log_* from this file. os.sh is the only thing that sources it, so every
# script that already sources os.sh gets the sink for free.
# ---------------------------------------------------------------------------
# shellcheck source=scripts/lib/state.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh"
