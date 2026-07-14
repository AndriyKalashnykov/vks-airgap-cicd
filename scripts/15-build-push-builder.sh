#!/usr/bin/env bash
# 15-build-push-builder.sh — (INTERNET side) build the air-gap Maven builder image
# (apps/java/javawebapp/Dockerfile.builder) with this pom's dependencies pre-baked, and push it to
# Harbor. The in-cluster CI (kaniko) and the Tekton maven-test task then build/test
# OFFLINE using this image's warm ~/.m2 cache.
#
# Requires docker or podman + internet (to pull Maven Central deps during the build).
# Rebuild whenever apps/java/javawebapp/pom.xml dependencies change (bump BUILDER_IMAGE_TAG).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# Serialize registry mutation on this host: a concurrent push corrupts Harbor's blob store
# (MANIFEST_UNKNOWN/BLOB_UNKNOWN later, recoverable only by rebuilding the registry). Re-exec
# ourselves under the lock; the second caller fails fast instead of silently corrupting.
if [ -z "${__REGISTRY_LOCK_HELD:-}" ]; then
  export __REGISTRY_LOCK_HELD=1
  with_registry_lock "$(basename "$0")" "$0" "$@"
  exit $?
fi

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never on argv)}"
: "${BUILDER_IMAGE_TAG:?}"

# Container engine — podman preferred (honours --tls-verify=false per-command for
# an insecure/HTTP Harbor; docker would need a daemon insecure-registries entry).
# Override with CONTAINER_ENGINE=docker.
ENGINE="$(container_engine)"
log_info "using container engine: $ENGINE"

# Which apps need a pre-baked builder image? The ones that SHIP a Dockerfile.builder — keyed on
# the FILE, not on a language name, so a future app that needs one just adds the file (and
# gowebapp, which is stdlib-only and fetches nothing offline, correctly needs none).
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# `if ... fi`, NOT `app_has_builder "$a" && printf ...`: a bare `A && B` returns NON-ZERO when A
# is false, so the last iteration (gowebapp has no builder) made the command substitution fail and
# `set -e` killed the script. `if` returns 0 when the condition is false.
BUILDER_APPS="$(app_names | while read -r a; do if app_has_builder "$a"; then printf '%s ' "$a"; fi; done)"
[ -n "$BUILDER_APPS" ] || { log_info "no app ships a Dockerfile.builder — nothing to build (stdlib-only apps need no offline dependency cache)"; exit 0; }
log_info "apps needing an offline builder image: ${BUILDER_APPS}"
MAVEN_BASE="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/maven:3.9-eclipse-temurin-25"
TLS_VERIFY="true"; [ "${HARBOR_INSECURE:-0}" = "1" ] && TLS_VERIFY="false"
# SECURE Harbor: point podman at the CA via --cert-dir (a clean dir holding only ca.crt) so
# pull/login/push verify the self-signed cert WITHOUT writing to /etc/containers/certs.d or
# the system store (no sudo). Empty in insecure mode (TLS skipped) or when the engine isn't podman.
CERT_DIR_ARG=()
if [ "$TLS_VERIFY" = "true" ] && [ -n "${HARBOR_CA_FILE:-}" ] && [ -f "$HARBOR_CA_FILE" ] && [ "$ENGINE" = podman ]; then
  BUILDER_CERTD="$(mktemp -d)"; trap 'rm -rf "$BUILDER_CERTD"' EXIT
  cp "$HARBOR_CA_FILE" "${BUILDER_CERTD}/ca.crt"
  CERT_DIR_ARG=(--cert-dir "$BUILDER_CERTD")
  log_info "trusting Harbor CA via podman --cert-dir=$BUILDER_CERTD (no sudo)"
fi

# --------------------------------------------------------------------------------------------------
# PRE-BUILD TRUST PROBE. Log in to Harbor NOW, before the ~20-minute build.
#
# This replaces a guard that inspected the FILESYSTEM (`is there a ca.crt under /etc/docker/certs.d?`)
# and died if it was absent. That guard was WRONG: docker on Linux MERGES certs.d with the HOST SYSTEM
# STORE (moby daemon/pkg/registry/registry.go -> loadTLSConfig seeds RootCAs from x509.SystemCertPool
# and APPENDS), so an operator who ran `update-ca-certificates` has a WORKING docker — and the guard
# hard-blocked them. It was also wrong in the other direction: a stale/expired ca.crt in certs.d
# PASSED the file check and then died 20 minutes later at `docker login` anyway.
#
# The only honest test of trust is a TRUST OPERATION. `login` does the real TLS handshake AND the auth,
# for whichever engine we are, wherever that engine happens to read its CA from. It cannot false-fire,
# and it needs no knowledge of certs.d rules. Do it FIRST, so a bad setup costs seconds, not a build.
# (Login is also required before the push at the end, so this is not an extra round-trip — it is the
# same one, moved to where its failure is cheap.)
log_info "probing Harbor trust + auth with $ENGINE (before the build, so a failure costs seconds)"
login_args=(--username "$HARBOR_USERNAME" --password-stdin)
[ "$ENGINE" = podman ] && login_args=(--tls-verify="$TLS_VERIFY" "${CERT_DIR_ARG[@]}" "${login_args[@]}")
if ! printf '%s' "$HARBOR_PASSWORD" | "$ENGINE" login "${login_args[@]}" "$HARBOR_URL" >/dev/null 2>&1; then
  log_error "$ENGINE cannot authenticate to Harbor at ${HARBOR_URL}."
  if [ "$ENGINE" = podman ]; then
    log_error "  podman takes the CA per-command. Check HARBOR_CA_FILE points at Harbor's CA:"
    log_error "      HARBOR_CA_FILE=${HARBOR_CA_FILE:-<unset>}"
    log_error "      make fetch-harbor-ca     # re-fetch it"
  else
    # NO `docker info | grep -q rootless`: under `set -o pipefail`, grep -q exits at the first match
    # and SIGPIPEs `docker info` (141), so the pipeline is non-zero and the `if` takes the WRONG
    # branch even when "rootless" IS present. It is invisible on a rootful box (both branches agree).
    # Read the field with --format instead — no pipe, no trap.
    sec="$(docker info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>/dev/null || true)"  # docker-ok: only reached when the operator CHOSE CONTAINER_ENGINE=docker, so docker exists; never on the podman path
    case "$sec" in
      *rootless*) certd="${HOME}/.config/docker/certs.d/${HARBOR_URL}/ca.crt"; sudo_="" ;;
      *)          certd="/etc/docker/certs.d/${HARBOR_URL}/ca.crt";            sudo_="sudo " ;;
    esac
    log_error "  Docker's DAEMON does the registry TLS, so the CA must be installed for the daemon."
    log_error "  Install it (no daemon restart needed — certs.d is read per request):"
    log_error "      ${sudo_}install -D -m0644 '${HARBOR_CA_FILE:-<HARBOR_CA_FILE unset — run: make fetch-harbor-ca>}' '${certd}'"
    log_error "  Then re-run. Or use podman (the default, no sudo, nothing installed): unset CONTAINER_ENGINE"
    [ "$TLS_VERIFY" = "false" ] && log_error "  NOTE: HARBOR_INSECURE=1 (plain HTTP) is PODMAN-ONLY — docker needs an insecure-registries entry."
  fi
  die "refusing to start a ~20-minute build that would fail at the push."
fi
log_info "Harbor trust + auth OK ($ENGINE)"

# Base the builder on the MIRRORED maven image if pullable, else the public one.
# Fully-qualified (docker.io/library/...) so podman — which does NOT assume a
# default registry for short names — can resolve it. --tls-verify is podman-only.
BUILD_BASE="docker.io/library/maven:3.9-eclipse-temurin-25"
pull_args=("$MAVEN_BASE")
[ "$ENGINE" = podman ] && pull_args=(--tls-verify="$TLS_VERIFY" "${CERT_DIR_ARG[@]}" "$MAVEN_BASE")
if "$ENGINE" pull "${pull_args[@]}" >/dev/null 2>&1; then
  BUILD_BASE="$MAVEN_BASE"; log_info "basing builder on mirrored $MAVEN_BASE"
elif [ "${ALLOW_PUBLIC_BASE:-0}" = "1" ]; then
  log_warn "mirrored maven image not pullable; ALLOW_PUBLIC_BASE=1 -> falling back to PUBLIC $BUILD_BASE (NOT air-gap faithful)"
else
  # This used to be a silent log_warn + fall back to docker.io. On a dual-homed box — which is
  # exactly where this script runs — that turns a BROKEN MIRROR into a GREEN BUILD: the image is
  # pulled from Docker Hub, the builder is published, and nothing has proven the air gap. It
  # would have masked the registry wipe that this branch fixes. A mirror we cannot pull from is
  # a failure, not a fallback; the escape hatch has to be asked for by name.
  die "cannot pull the MIRRORED base '$MAVEN_BASE' from Harbor.
  The builder must be based on the mirrored image — falling back to Docker Hub would build green
  while proving nothing about the air gap (and would hide a broken Harbor).
  Fix the mirror first:  make mirror   (it now ends in mirror-verify)
  Deliberately building against the public base anyway:  ALLOW_PUBLIC_BASE=1 make builder-image"
fi

for app in $BUILDER_APPS; do
REF="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/${app}-builder:${BUILDER_IMAGE_TAG}"
src="${REPO_ROOT}/$(app_src "$app")"
log_info "building builder image $REF for '${app}' (this pulls its deps — needs internet)"
run "$ENGINE" build \
  --build-arg "MAVEN_IMAGE=${BUILD_BASE}" \
  -f "${src}/Dockerfile.builder" \
  -t "$REF" \
  "${src}"

# Already logged in by the pre-build trust probe above — do not re-login per app.
log_info "pushing $REF"
push_args=("$REF")
[ "$ENGINE" = podman ] && push_args=(--tls-verify="$TLS_VERIFY" "${CERT_DIR_ARG[@]}" "$REF")
run "$ENGINE" push "${push_args[@]}"

log_info "builder image pushed: $REF"
done

log_info "builder images pushed for: ${BUILDER_APPS}"
log_info "each app's pipeline references its own as BUILDER_IMAGE; the app Dockerfile then builds OFFLINE against it"
