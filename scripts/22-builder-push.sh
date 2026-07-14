#!/usr/bin/env bash
# 22-builder-push.sh — (AIR-GAP side, Harbor only) push the carried Maven builder image(s) into Harbor.
#
# The sibling of 14-builder-build.sh. See that file for WHY the builder is split: it used to need the
# internet AND Harbor in one command, so on a sneakernet split NEITHER box could run it.
#
# THIS BOX NEEDS NO CONTAINER ENGINE. `crane push` reads a docker-style tarball (which is what
# `podman save`/`docker save` produce), and crane is CARRIED IN THE BUNDLE. So the air-gap box's whole
# toolchain for the mirror half stays: tar + curl + sha256sum + the carried crane.
#
# THE DESTINATION REF IS COMPUTED HERE, NOT ON THE BUILD BOX — on purpose. It is
# ${HARBOR_URL}/${HARBOR_INFRA_PROJECT}/<app>-builder:<tag>, and the build box has no Harbor and does not
# know its address. This box does. app_builder_image() is the single source of that ref (lib/apps.sh),
# the same function that renders it into the Kaniko build-arg and the Tekton trigger — so they cannot drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# lib/tls.sh BEFORE lib/harbor.sh — harbor_setup calls ca_bundle_with_system() from tls.sh, and
# harbor.sh's own header says the CALLER must source it. Omitting it is not a lint error (shellcheck
# cannot see across a runtime source), it is a `command not found` at the first TLS setup — which is
# exactly where the e2e caught it.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
load_env

# Serialize registry mutation on this host (same lock the mirror push takes): two concurrent pushers
# make any failure unattributable.
if [ -z "${__REGISTRY_LOCK_HELD:-}" ]; then
  export __REGISTRY_LOCK_HELD=1
  with_registry_lock "$(basename "$0")" "$0" "$@"
  exit $?
fi

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"; : "${HARBOR_USERNAME:?}"
: "${HARBOR_PASSWORD:?set HARBOR_PASSWORD in .env (never on argv)}"
: "${BUNDLE_DIR:?}"
require_cmd crane "it is carried in the bundle — run 'make bundle-load' first"

IN_DIR="${BUNDLE_DIR}/builders"
if [ ! -d "$IN_DIR" ]; then
  # Do NOT pass silently: the Java pipeline's Kaniko build asks Harbor for this exact image, and if it
  # is absent the failure surfaces as an ImagePullBackOff at the far end of the pipeline, naming the
  # image rather than the missing carry. Say it HERE, where it is fixable.
  die "the bundle carries no builder images (${IN_DIR} is missing).
  The offline Maven builder cannot be built on this box — it needs Maven Central, and this box is
  air-gapped. Build it on the INTERNET box and re-cut the bundle:
      make mirror-pull && make builder-build && make bundle
  (An all-stdlib deployment with no Dockerfile.builder legitimately has none — but then
  bundle/builders/ would not be referenced by any app either.)"
fi

# harbor_setup exports SSL_CERT_FILE (how crane trusts a self-signed Harbor, sudo-free) and sets
# HARBOR_TLS_VERIFY / the curl config — identical to 21-mirror-push.sh, so trust behaves the same way.
# It takes a scratch dir (the CA bundle + the curl config land there, mode 0600 — never on argv).
HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
harbor_setup "$HARBOR_TMP"
CRANE_INSECURE=()
[ "${HARBOR_INSECURE:-0}" = "1" ] && CRANE_INSECURE=(--insecure)

printf '%s' "$HARBOR_PASSWORD" | run crane auth login "$HARBOR_URL" \
  --username "$HARBOR_USERNAME" --password-stdin "${CRANE_INSECURE[@]}"
ensure_project "$HARBOR_INFRA_PROJECT"

pushed=0
for app in $(app_names); do
  app_has_builder "$app" || continue
  tarball="${IN_DIR}/${app}-builder.tar"
  [ -f "$tarball" ] || die "app '${app}' needs a builder image, but the bundle carries none for it (${tarball}).
  Re-cut the bundle on the internet box: make builder-build && make bundle"

  ref="$(app_builder_image "$app")"
  log_info "[${app}] pushing the carried builder -> ${ref}"
  run crane push "$tarball" "$ref" "${CRANE_INSECURE[@]}"
  pushed=$((pushed + 1))
done

if [ "$pushed" -eq 0 ]; then
  log_info "no app needs a builder image — nothing pushed"
  exit 0
fi

# VERIFY BY FETCHING, NOT BY THE PUSHER'S EXIT CODE. An OCI push establishes blob existence with a
# HEAD and SKIPS the upload if the registry claims to have it — so a registry that answers 200 for a
# blob it cannot serve makes `crane push` a SILENT NO-OP THAT EXITS 0. That happened to this repo's
# whole mirror. crane validate --remote FETCHES every blob back.
for app in $(app_names); do
  app_has_builder "$app" || continue
  ref="$(app_builder_image "$app")"
  run crane validate --remote "$ref" "${CRANE_INSECURE[@]}"
  log_info "[${app}] verified intact in Harbor: ${ref}"
done

log_info "builder images pushed + verified: ${pushed}"
