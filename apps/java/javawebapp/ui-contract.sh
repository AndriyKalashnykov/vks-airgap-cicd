#!/usr/bin/env bash
# UI-CONTRACT PRODUCER for javawebapp. Renders through the REAL Spring+Thymeleaf pipeline (MockMvc),
# so the artifact is what a user would be served -- not a hand-rolled TemplateEngine render.
# See apps/go/gowebapp/ui-contract.sh for why this is a per-app FILE and not a central `case`.
set -euo pipefail
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
UI_CONTRACT_OUT="$out" ./mvnw -q -B -Dtest=UiContractRenderTest test >/dev/null 2>&1
[ -s "$out" ] || { echo "javawebapp: producer wrote nothing to $out" >&2; exit 1; }
