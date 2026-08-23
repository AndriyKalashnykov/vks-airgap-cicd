#!/usr/bin/env bash
# UI-CONTRACT PRODUCER for nodejswebapp. Renders the landing page through the REAL express handler
# and writes it to $1. One of these per app; check-ui-contract.sh resolves it from the registry's
# `src` column, so adding a language adds a FILE and touches no central `case`.
set -euo pipefail
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
UI_CONTRACT_OUT="$out" npm test --silent >/dev/null
[ -s "$out" ] || { echo "nodejswebapp: producer wrote nothing to $out" >&2; exit 1; }
