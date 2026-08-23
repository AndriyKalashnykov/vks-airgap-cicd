#!/usr/bin/env bash
# UI-CONTRACT PRODUCER for pythonwebapp. Renders the landing page through the REAL Flask handler and
# writes it to $1. One of these per app; check-ui-contract.sh resolves it from the registry's `src`
# column, so adding a language adds a FILE and touches no central `case`.
set -euo pipefail
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "${BASH_SOURCE[0]}")"
# uv is the repo's pinned python tool (see .mise.toml); it resolves Flask from requirements.txt into
# an ephemeral env, so this needs no venv on the box and no global pip install.
UI_CONTRACT_OUT="$out" uv run --quiet --with-requirements requirements.txt --with pytest \
  python -m pytest -q -k ui_contract_producer >/dev/null
[ -s "$out" ] || { echo "pythonwebapp: producer wrote nothing to $out" >&2; exit 1; }
