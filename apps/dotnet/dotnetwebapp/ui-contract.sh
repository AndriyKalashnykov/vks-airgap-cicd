#!/usr/bin/env bash
# UI-CONTRACT PRODUCER for dotnetwebapp. Renders the landing page and writes it to $1. One of these
# per app; check-ui-contract.sh resolves it from the registry's `src` column, so adding a language
# adds a FILE and touches no central `case`.
set -euo pipefail
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
UI_CONTRACT_OUT="$out" dotnet run --nologo --verbosity quiet >/dev/null 2>&1
[ -s "$out" ] || { echo "dotnetwebapp: producer wrote nothing to $out" >&2; exit 1; }
