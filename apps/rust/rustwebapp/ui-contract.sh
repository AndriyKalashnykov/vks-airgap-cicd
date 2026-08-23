#!/usr/bin/env bash
# UI-CONTRACT PRODUCER for rustwebapp. Renders the landing page and writes it to $1. One of these
# per app; check-ui-contract.sh resolves it from the registry's `src` column, so adding a language
# adds a FILE and touches no central `case`.
set -euo pipefail
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
# --quiet keeps cargo's progress off stdout; the test itself writes the file.
UI_CONTRACT_OUT="$out" cargo test --quiet ui_contract_producer -- --exact tests::ui_contract_producer >/dev/null
[ -s "$out" ] || { echo "rustwebapp: producer wrote nothing to $out" >&2; exit 1; }
