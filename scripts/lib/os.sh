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

# container_engine — the OCI engine to use, podman preferred over docker.
# Override with CONTAINER_ENGINE. Prints the engine name (podman|docker) or dies.
container_engine() {
  if [ -n "${CONTAINER_ENGINE:-}" ]; then printf '%s' "$CONTAINER_ENGINE"; return 0; fi
  if have podman; then printf 'podman'
  elif have docker; then printf 'docker'
  else die "no container engine found — install podman (preferred) or docker"; fi
}

# require_cmd cmd [human hint] — fail fast with an actionable message.
require_cmd() {
  local cmd="$1" hint="${2:-run scripts/00-install-prereqs.sh}"
  have "$cmd" || die "required command '$cmd' not found — $hint"
}

# ---------------------------------------------------------------------------
# Environment loading — .env.example (committed defaults) then .env (overrides).
# `set -a` exports everything so child processes (crane, kubectl, curl) see it.
# ---------------------------------------------------------------------------
load_env() {
  local example="${REPO_ROOT}/.env.example" override="${REPO_ROOT}/.env" kind="${REPO_ROOT}/.env.kind"
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
  for _sel in KUBECONFIG ARGOCD_KUBECONFIG GUEST_KUBECONFIG ARGOCD_SERVER ARGOCD_AUTH_TOKEN ARGOCD_DEST_SERVER ARGOCD_DEST_CLUSTER_NAME ARGOCD_NAMESPACE; do
    if [ -n "${!_sel:-}" ]; then
      _snap_names="${_snap_names} ${_sel}"
      _snap_vals="${_snap_vals}${_sel}=${!_sel}"$'\n'
    fi
  done

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
  # .env.kind is written by the KinD flow (discovered LB IP, kubeconfig, ...) and
  # overrides the above so the normal scripts run unchanged against the kind cluster.
  # shellcheck disable=SC1090
  [ -f "$kind" ] && . "$kind"
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
}

# set_env_var KEY VALUE [file] — idempotently upsert KEY=VALUE (default .env.kind).
# Used by the KinD flow to publish discovered values to the normal scripts.
set_env_var() {
  local key="$1" val="$2" file="${3:-${REPO_ROOT}/.env.kind}"
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
