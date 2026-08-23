#!/bin/sh
# UI-CONTRACT PRODUCER for pythonwebapp. Renders the landing page through the REAL Flask handler and
# writes it to $1. One of these per app; check-ui-contract.sh resolves it from the registry's `src`
# column, so adding a language adds a FILE and touches no central `case`.
# POSIX sh, deliberately: this runs INSIDE the app's builder image (check-ui-contract
# renders every app in its own builder), and four of those are alpine with NO bash.
# `pipefail` is NOT POSIX and dash REJECTS it, so the shebang alone is not enough --
# the java and go builders are Debian, where /bin/sh is dash.
# There are no pipes in this script; the only `|` is the `||` of the guard below.
set -eu
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "$0")"   # $0, not BASH_SOURCE: this file is EXECUTED, never sourced
# uv is the repo's pinned python tool (see .mise.toml); it resolves Flask from requirements.txt into
# an ephemeral env, so this needs no venv on the box and no global pip install.
# Two environments, one producer. INSIDE the builder image (where check-ui-contract now runs this)
# there is no `uv` and no network -- but /opt/venv-dev already carries requirements.txt AND pytest,
# baked by Dockerfile.builder. On the HOST there is no /opt/venv-dev, and `uv` self-provisions.
# MEASURED without this: `./ui-contract.sh: line 10: uv: command not found`, rc=127.
if [ -x /opt/venv-dev/bin/python ]; then
  UI_CONTRACT_OUT="$out" PYTHONDONTWRITEBYTECODE=1 \
    /opt/venv-dev/bin/python -m pytest -q -p no:cacheprovider -k ui_contract_producer >/dev/null
else
  UI_CONTRACT_OUT="$out" uv run --quiet --with-requirements requirements.txt --with pytest \
    python -m pytest -q -k ui_contract_producer >/dev/null
fi
[ -s "$out" ] || { echo "pythonwebapp: producer wrote nothing to $out" >&2; exit 1; }
