#!/usr/bin/env bash
# 15-build-push-builder.sh — (DUAL-HOMED box) build the offline Maven builder image and push it to Harbor.
#
# THIS IS NOW A THIN ORCHESTRATOR OVER THE TWO HALVES, AND THAT IS THE POINT.
#
# The builder needs TWO networks at once — Maven Central (Dockerfile.builder runs `mvn verify` to bake
# ~/.m2, because the in-cluster Kaniko build cannot reach Maven Central) and Harbor (base ref, login,
# push). A dual-homed jump box has both, so this target still does it in one command.
#
# But a SNEAKERNET split has NEITHER box with both — the outside box died at the Harbor login probe and
# the inside box died inside `mvn verify` — so `make builder-image` was UNRUNNABLE ON EITHER BOX, and the
# air-gapped Java build could not be produced at all. The halves:
#
#     14-builder-build.sh   internet only   build -> save into bundle/builders/   (no Harbor)
#     22-builder-push.sh    Harbor only     crane push the carried tarball        (no internet, no engine)
#
# This script runs BOTH, so the dual-homed path exercises exactly the code the sneakernet path uses.
# Two separate implementations of "build the builder" would drift, and the one nobody runs locally
# (the air-gap one) is the one that would rot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

log_info "dual-homed builder: build (needs Maven Central) then push (needs Harbor)"
run "${SCRIPT_DIR}/14-builder-build.sh"
run "${SCRIPT_DIR}/22-builder-push.sh"
