#!/bin/sh
# UI-CONTRACT PRODUCER for javawebapp. Renders through the REAL Spring+Thymeleaf pipeline (MockMvc),
# so the artifact is what a user would be served -- not a hand-rolled TemplateEngine render.
# See apps/go/gowebapp/ui-contract.sh for why this is a per-app FILE and not a central `case`.
# POSIX sh, deliberately: this runs INSIDE the app's builder image (check-ui-contract
# renders every app in its own builder), and four of those are alpine with NO bash.
# `pipefail` is NOT POSIX and dash REJECTS it, so the shebang alone is not enough --
# the java and go builders are Debian, where /bin/sh is dash.
# There are no pipes in this script; the only `|` is the `||` of the guard below.
set -eu
out="${1:?usage: ui-contract.sh <out-file>}"
cd "$(dirname "$0")"   # $0, not BASH_SOURCE: this file is EXECUTED, never sourced
UI_CONTRACT_OUT="$out" ./mvnw -q -B -Dtest=UiContractRenderTest test >/dev/null 2>&1
[ -s "$out" ] || { echo "javawebapp: producer wrote nothing to $out" >&2; exit 1; }
