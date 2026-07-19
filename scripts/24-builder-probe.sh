#!/usr/bin/env bash
# 24-builder-probe.sh — the carried builder image must be RUNNABLE, not merely FETCHABLE.
#
# WHY THIS EXISTS, AND WHY IT IS NOT `mirror-verify` (B3):
#   `mirror-verify` and `test-builder-save-crane` both prove BLOB INTEGRITY: every layer round-trips
#   and `crane validate --remote` fetches them all back. Neither executes the image. The thing they
#   cannot see is whether `<engine> save` -> tar -> carry across the gap -> `crane push` preserved a
#   usable CONFIG BLOB — entrypoint, user, workdir, env, PATH. An image whose layers are perfect and
#   whose config is mangled passes every check this repo had, and then fails inside a Tekton TaskRun
#   with an error that names the pipeline, not the carry.
#
#   The full proof of that is `make verify` (the pipeline runs `mvn` INSIDE this image, and Kaniko
#   uses it as `FROM ${BUILDER_IMAGE}`). But `verify` needs Gitea + Tekton + ArgoCD and ~10 minutes.
#   This probe gets the SAME delta in one pod and ~30 seconds, with no ArgoCD, so it can live on the
#   air-gap leg where the carried image actually is.
#
# WHAT IT DOES NOT PROVE (do not over-read the green): that the pipeline as a whole works, that the
# baked ~/.m2 is complete, or that the app builds. It proves the carried image STARTS and its Maven
# is executable offline. `make verify` remains the end-to-end claim.
#
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

: "${HARBOR_URL:?}"; : "${HARBOR_INFRA_PROJECT:?}"
require_cmd kubectl
: "${KUBECONFIG:?no KUBECONFIG — this probe runs a pod, so it needs the cluster the images were pushed for}"

NS="${BUILDER_PROBE_NAMESPACE:-${CI_NAMESPACE:-ci}}"
TIMEOUT="${BUILDER_PROBE_TIMEOUT:-180s}"

probed=0
fail=0

for app in $(app_names); do
  [ -n "$app" ] || continue
  # Only apps that actually HAVE a pre-baked builder are in scope. A go app's "builder" is the
  # mirrored upstream golang image, which the mirror already verifies and which we did not carry as
  # a saved tarball — probing it would measure the mirror, not the carry.
  app_has_builder "$app" || continue

  ref="$(app_builder_image "$app")"
  pod="builder-probe-$(printf '%s' "$app" | tr -c 'a-z0-9' '-' | cut -c1-40)"
  log_info "[${app}] probing the CARRIED builder is runnable: ${ref}"

  # `mvn -o -v` is deliberate: -o (offline) so a missing Maven Central cannot make this pass or fail
  # for the wrong reason, and -v because it exercises the JVM + the image's PATH/entrypoint without
  # needing a project. A mangled config blob fails here with "executable file not found" / no such
  # command, which is exactly the signal the blob checks cannot produce.
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
  if kubectl -n "$NS" run "$pod" \
        --image="$ref" --restart=Never --attach --rm \
        --pod-running-timeout="$TIMEOUT" \
        --command -- mvn -o -v > "${TMPDIR:-/tmp}/probe-${app}.log" 2>&1; then
    log_info "[${app}] OK — the carried image started and its Maven ran:"
    grep -m1 -E '^Apache Maven' "${TMPDIR:-/tmp}/probe-${app}.log" | sed 's/^/      /' || true
    probed=$((probed + 1))
  else
    log_error "[${app}] the CARRIED builder ${ref} did NOT run. Blob integrity is not the question —"
    log_error "  mirror-verify already passed. This is the CONFIG BLOB (entrypoint/user/workdir/PATH)"
    log_error "  or the image genuinely cannot start on this node. Output:"
    sed 's/^/      /' "${TMPDIR:-/tmp}/probe-${app}.log" >&2 || true
    fail=1
  fi
  kubectl -n "$NS" delete pod "$pod" --ignore-not-found >/dev/null 2>&1 || true
done

# Fail-check FIRST: `probed` counts only SUCCESSES, so if every app failed, probed==0 AND fail==1 —
# checking the "nothing to probe" skip first would exit 0 on a run that printed nothing but errors.
[ "$fail" -eq 0 ] || die "builder-probe: a carried builder image is not runnable (see above)."
[ "$probed" -gt 0 ] || { log_warn "builder-probe: no app declares a pre-baked builder — nothing to probe."; exit 0; }
log_info "builder-probe: OK — ${probed} carried builder image(s) start and run offline."
