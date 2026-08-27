#!/usr/bin/env bash
# 15-build-push-selfbuilt.sh — (DUAL-HOMED box) build the self-built images and push them to Harbor.
#
# A THIN ORCHESTRATOR OVER THE TWO HALVES, deliberately — exactly like 15-build-push-builder.sh,
# and for the same reason its header gives: two separate implementations would drift.
#
# WHY IT IS A SCRIPT AND NOT `selfbuilt-image: selfbuilt-build selfbuilt-push`.
# A make-prereq chain has no guaranteed order under `-j`, and these two halves are strictly
# sequential: the second reads the tarball the first writes. A script cannot be reordered.
#
# The images in images/selfbuilt.tsv have NO upstream to pull (Google archived kaniko; the
# maintained fork publishes no image), so `mirror-pull` cannot supply them and only this can.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/selfbuilt.sh
. "${SCRIPT_DIR}/lib/selfbuilt.sh"

load_env

# Nothing to do is a legitimate state (an empty or all-comment TSV), and it must be SILENT-ish
# rather than a failure: a repo that self-builds nothing still runs install-all.
if [ -z "$(selfbuilt_names)" ]; then
  log_info "images/selfbuilt.tsv lists no images — nothing to build or push"
  exit 0
fi

log_info "self-built images: build (internet) then push (Harbor), in one shot"
run "${SCRIPT_DIR}/14-selfbuilt-build.sh"
run "${SCRIPT_DIR}/22-selfbuilt-push.sh"
