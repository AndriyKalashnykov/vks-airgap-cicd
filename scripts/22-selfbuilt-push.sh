#!/usr/bin/env bash
# 22-selfbuilt-push.sh — AIR-GAP BOX. Push the carried self-built images into Harbor.
#
# THIS BOX NEEDS NO CONTAINER ENGINE — exactly as 22-builder-push.sh explains: `crane push` reads a
# docker-style tarball (which is what `podman save`/`docker save` produce), and crane is CARRIED IN
# THE BUNDLE. Sibling of that script; see 14-selfbuilt-build.sh for why this is separate from the
# per-APP builder path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/selfbuilt.sh
. "${SCRIPT_DIR}/lib/selfbuilt.sh"
# shellcheck source=scripts/lib/mirror.sh
. "${SCRIPT_DIR}/lib/mirror.sh"
# ⚠️ lib/tls.sh BEFORE lib/harbor.sh — harbor_setup() calls ca_bundle_with_system() from tls.sh.
# OMITTING THIS PAIR WAS A CRITICAL BUG IN THE FIRST VERSION OF THIS FILE: without harbor_setup,
# SSL_CERT_FILE is never exported, and on the repo's DEFAULT posture (HARBOR_INSECURE unset => 0,
# self-signed Harbor) the very first crane call dies `x509: certificate signed by unknown authority`
# -- so `make selfbuilt-push` could not work at all, on the air-gap box, the one that cannot debug it.
# 22-builder-push.sh:26-33 documents the IDENTICAL omission being caught by the e2e once before; this
# file repeated it. shellcheck cannot see across a runtime source, so no linter catches it.
# shellcheck source=scripts/lib/tls.sh
. "${SCRIPT_DIR}/lib/tls.sh"
# shellcheck source=scripts/lib/harbor.sh
. "${SCRIPT_DIR}/lib/harbor.sh"
load_env

# Serialize registry mutation on this host (the same lock the mirror push takes): two concurrent
# pushers make any failure unattributable — and a Harbor blob-store wipe with exactly that signature
# is this repo's most expensive recorded incident.
if [ -z "${__REGISTRY_LOCK_HELD:-}" ]; then
  export __REGISTRY_LOCK_HELD=1
  with_registry_lock "$(basename "$0")" "$0" "$@"
  exit $?
fi

: "${BUNDLE_DIR:?BUNDLE_DIR must be set (see .env.example)}"
: "${HARBOR_URL:?HARBOR_URL must be set}"
: "${HARBOR_INFRA_PROJECT:?HARBOR_INFRA_PROJECT must be set}"

selfbuilt_validate || die "images/selfbuilt.tsv is not usable — fix the rows above."

NAMES="$(selfbuilt_names | tr '\n' ' ')"
if [ -z "${NAMES// /}" ]; then
  log_info "images/selfbuilt.tsv lists nothing — nothing to push."
  exit 0
fi

IN_DIR="${BUNDLE_DIR}/selfbuilt"
require_cmd crane "crane is carried in the bundle — is BUNDLE_DIR right?"

CRANE_INSECURE=()
[ "${HARBOR_INSECURE:-0}" = "1" ] && CRANE_INSECURE=(--insecure)

# harbor_setup exports SSL_CERT_FILE (how crane trusts a self-signed Harbor, sudo-free) and sets the
# curl/TLS posture. It must run BEFORE any crane call.
HARBOR_TMP="$(mktemp -d)"; trap 'rm -rf "$HARBOR_TMP"' EXIT
harbor_setup "$HARBOR_TMP"

# A project-scoped robot may be unable to HEAD Harbor's system /projects endpoint, so a 403 on an
# EXISTING project is the known gap — warn, do not die (same handling as 21-mirror-push.sh:60).
ensure_project "$HARBOR_INFRA_PROJECT" || log_warn "ensure_project('$HARBOR_INFRA_PROJECT') non-zero — a 403 on an EXISTING project is the known project-scoped-robot gap; continuing"

# Secret on stdin, never argv.
printf '%s' "${HARBOR_PASSWORD:?HARBOR_PASSWORD must be set}" \
  | run crane auth login "$HARBOR_URL" -u "${HARBOR_USERNAME:?HARBOR_USERNAME must be set}" --password-stdin "${CRANE_INSECURE[@]}"

pushed=""
for name in $NAMES; do
  tarball="${IN_DIR}/${name}.tar"
  ref="$(selfbuilt_harbor_ref "$name")"
  [ -f "$tarball" ] || die "'${name}' is listed in images/selfbuilt.tsv but the bundle carries no ${tarball}.
  Re-cut the bundle on the internet box: make selfbuilt-build && make bundle"

  log_info "[${name}] pushing the carried image -> ${ref}"
  mirror_retry "${MIRROR_RETRIES:-5}" run crane push "$tarball" "$ref" "${CRANE_INSECURE[@]}"
  pushed="${pushed} ${name}"
done

# VERIFY BY FETCHING, NOT BY THE PUSH'S EXIT CODE.
# A registry that HEAD-200s a blob it cannot serve makes `crane push` a SILENT NO-OP THAT EXITS 0 —
# that happened to this repo's Harbor (36/36 "pushed", 153 manifest links, ZERO blobs). The push's
# status cannot see it; only a fetch can.
for name in $NAMES; do
  ref="$(selfbuilt_harbor_ref "$name")"
  run crane validate --remote "$ref" "${CRANE_INSECURE[@]}"
  log_info "[${name}] verified intact in Harbor: ${ref}"
done

# ---- RECORD (and, on a re-run, COMPARE) THE REGISTRY DIGEST -------------------
# The build side records the ENGINE's image id, which is a CONFIG digest and is NOT comparable to
# what a registry reports (measured: 1253e769... vs 95106555...). Without this, the lock could not
# verify anything -- it was provenance you could not check. Here we ask the registry what it now
# serves, and on a re-run we FAIL when the same tag serves different bytes, which is the mutable-tag
# hazard this repo has already been bitten by.
PUSHED_LOCK="${IN_DIR}/selfbuilt-pushed.lock"
drift=0
for name in $NAMES; do
  ref="$(selfbuilt_harbor_ref "$name")"
  # `|| true`: a crane failure here must not abort before we can report it (set -e).
  now="$(crane digest "$ref" "${CRANE_INSECURE[@]}" 2>/dev/null || true)"
  [ -n "$now" ] || { log_warn "[${name}] could not read the registry digest — recording nothing"; continue; }
  was="$(awk -F'\t' -v n="$name" '$1==n {print $2}' "$PUSHED_LOCK" 2>/dev/null | tail -1)"
  if [ -n "$was" ] && [ "$was" != "$now" ]; then
    log_error "[${name}] ${ref} now serves ${now}, but a previous verified push recorded ${was}."
    log_error "  The SAME TAG is serving DIFFERENT BYTES. Either the tag was overwritten (give the new"
    log_error "  content its own tag — see the tag rule in images/selfbuilt.tsv) or the registry is lying."
    drift=1
  fi
  printf '%s\t%s\t%s\n' "$name" "$now" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PUSHED_LOCK"
  log_info "[${name}] registry digest: ${now}"
done
[ "$drift" -eq 0 ] || die "a self-built tag changed content under the same name — refusing to call this a clean push."

log_info "self-built images pushed + verified:${pushed}"
