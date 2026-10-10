#!/usr/bin/env bash
# scripts/lib/test-sandbox.sh — the ONE fence a unit test puts between itself and this machine.
#
#   # shellcheck source=scripts/lib/test-sandbox.sh
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
#
# Source it FIRST. What it pins, how a pin is lifted, and how its clean-up composes with a test's
# own trap are documented where the code is: scripts/test-guard/sandbox.sh.
#
# WHY THIS FILE IS ONLY A POINTER. check-lib-sourcing.sh treats every function DEFINED under
# scripts/lib/ as a library helper and requires each script that calls one to source its library.
# The fence wraps `trap` (so a test's `trap ... EXIT` composes with the clean-up instead of
# replacing it), and a `trap()` defined here made that gate flag every script in the repo that
# traps anything (MEASURED: the gate went from green to red on this file alone). The definitions
# therefore live beside the guard they belong with, outside the directory that gate reads.
# shellcheck shell=bash
# shellcheck source=scripts/test-guard/sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../test-guard" && pwd)/sandbox.sh"
