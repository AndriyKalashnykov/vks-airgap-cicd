#!/bin/sh
# UI-CONTRACT PRODUCER for gowebapp. Renders the landing page with the contract's FIXED inputs and
# writes it to $1. One of these per app; check-ui-contract.sh discovers them by convention, so
# adding a language adds a FILE and touches no central `case` (lib/apps.sh already has 7 such
# branches; this deliberately does not become the 8th).
# POSIX sh, deliberately: this runs INSIDE the app's builder image (check-ui-contract
# renders every app in its own builder), and four of those are alpine with NO bash.
# `pipefail` is NOT POSIX and dash REJECTS it, so the shebang alone is not enough --
# the java and go builders are Debian, where /bin/sh is dash.
# There are no pipes in this script; the only `|` is the `||` of the guard below.
set -eu
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "$0")"   # $0, not BASH_SOURCE: this file is EXECUTED, never sourced
UI_CONTRACT_OUT="$out" go test -run TestUIContractRender ./... >/dev/null 2>&1
[ -s "$out" ] || { echo "gowebapp: producer wrote nothing to $out" >&2; exit 1; }
