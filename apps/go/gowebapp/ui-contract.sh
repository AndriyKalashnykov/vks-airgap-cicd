#!/usr/bin/env bash
# UI-CONTRACT PRODUCER for gowebapp. Renders the landing page with the contract's FIXED inputs and
# writes it to $1. One of these per app; check-ui-contract.sh discovers them by convention, so
# adding a language adds a FILE and touches no central `case` (lib/apps.sh already has 7 such
# branches; this deliberately does not become the 8th).
set -euo pipefail
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
UI_CONTRACT_OUT="$out" go test -run TestUIContractRender ./... >/dev/null 2>&1
[ -s "$out" ] || { echo "gowebapp: producer wrote nothing to $out" >&2; exit 1; }
