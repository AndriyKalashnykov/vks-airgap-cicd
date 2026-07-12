#!/usr/bin/env bash
# 15-build-push-builder.sh — (INTERNET side) build the air-gap Maven builder image
# (apps/java/webui/Dockerfile.builder) with this pom's dependencies pre-baked, and push it to
# Harbor. The in-cluster CI (kaniko) and the Tekton maven-test task then build/test
# OFFLINE using this image's warm ~/.m2 cache.
#
# Requires docker or podman + internet (to pull Maven Central deps during the build).
# Rebuild whenever apps/java/webui/pom.xml dependencies change (bump BUILDER_IMAGE_TAG).
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

REF="${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/webui-builder:${BUILDER_IMAGE_TAG}"
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

# Base the builder on the MIRRORED maven image if pullable, else the public one.
# Fully-qualified (docker.io/library/...) so podman — which does NOT assume a
# default registry for short names — can resolve it. --tls-verify is podman-only.
BUILD_BASE="docker.io/library/maven:3.9-eclipse-temurin-25"
pull_args=("$MAVEN_BASE")
[ "$ENGINE" = podman ] && pull_args=(--tls-verify="$TLS_VERIFY" "${CERT_DIR_ARG[@]}" "$MAVEN_BASE")
if "$ENGINE" pull "${pull_args[@]}" >/dev/null 2>&1; then
  BUILD_BASE="$MAVEN_BASE"; log_info "basing builder on mirrored $MAVEN_BASE"
else
  log_warn "mirrored maven image not pullable; using public $BUILD_BASE"
fi

log_info "building builder image $REF (this pulls Maven deps — needs internet)"
run "$ENGINE" build \
  --build-arg "MAVEN_IMAGE=${BUILD_BASE}" \
  -f "${REPO_ROOT}/apps/java/webui/Dockerfile.builder" \
  -t "$REF" \
  "${REPO_ROOT}/apps/java/webui"

log_info "logging in to Harbor and pushing $REF"
# --tls-verify is a podman flag (docker uses daemon insecure-registries / certs.d).
login_args=(--username "$HARBOR_USERNAME" --password-stdin)
[ "$ENGINE" = podman ] && login_args=(--tls-verify="$TLS_VERIFY" "${CERT_DIR_ARG[@]}" "${login_args[@]}")
printf '%s' "$HARBOR_PASSWORD" | run "$ENGINE" login "${login_args[@]}" "$HARBOR_URL"

push_args=("$REF")
[ "$ENGINE" = podman ] && push_args=(--tls-verify="$TLS_VERIFY" "${CERT_DIR_ARG[@]}" "$REF")
run "$ENGINE" push "${push_args[@]}"

log_info "builder image pushed: $REF"
log_info "the pipeline references it as BUILDER_IMAGE; the app Dockerfile builds offline against it"
