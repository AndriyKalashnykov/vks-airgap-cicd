#!/bin/sh
# UI-CONTRACT PRODUCER for rustwebapp. Renders the landing page and writes it to $1. One of these
# per app; check-ui-contract.sh resolves it from the registry's `src` column, so adding a language
# adds a FILE and touches no central `case`.
# POSIX sh, deliberately: this runs INSIDE the app's builder image (check-ui-contract
# renders every app in its own builder), and four of those are alpine with NO bash.
# `pipefail` is NOT POSIX and dash REJECTS it, so the shebang alone is not enough --
# the java and go builders are Debian, where /bin/sh is dash.
# There are no pipes in this script; the only `|` is the `||` of the guard below.
set -eu
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "$0")"   # $0, not BASH_SOURCE: this file is EXECUTED, never sourced
# --quiet keeps cargo's progress off stdout; the test itself writes the file.
UI_CONTRACT_OUT="$out" cargo test --quiet ui_contract_producer -- --exact tests::ui_contract_producer >/dev/null
[ -s "$out" ] || { echo "rustwebapp: producer wrote nothing to $out" >&2; exit 1; }
