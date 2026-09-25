#!/usr/bin/env bash
# ============================================================================
# platform-report.sh — measure THIS host for the README "Tested platforms" table.
#
#   make platform-report                                   # default target set
#   make platform-report PLATFORM_REPORT_TARGETS="static-check docs-lint"
#
# Prints the host facts a reader needs to reproduce the row, runs each target with its OWN rc,
# and prints ONE markdown table row whose every claim came from this run.
#
# WHAT IT REFUSES TO CLAIM, and why (two adversary rounds, 2026-09-25):
#   * No "M need a live lab / K are Linux-only" split. The Makefile's `##@` groups are TOPICAL,
#     not execution classes -- the "KinD" group holds install-ingress, which install-all runs on a
#     real lab. Any class count derived from them is confidently wrong in both directions. So it
#     counts only what it EXECUTED (make --trace) against the documented total, and says the rest
#     were NOT run by it.
#   * No versions of mise-pinned tools. They live in .mise.toml and rot on the next Renovate merge;
#     the row names the commit instead. Only HOST-supplied tools are printed.
#   * No test count without its skip count. "152/152" and "157/157" are not comparable when one
#     host skips arms the other runs, so the runner's own verdict line is copied verbatim.
#
# It uses the make that is EXECUTING it ($MAKE / $MAKE_VERSION from the recipe), never `make`
# off PATH: on a Mac a bare `make` is Apple's 3.81, which the Makefile refuses, and reading its
# version would record a make that ran nothing.
#
# POSITIVE CHECK: `git status --porcelain` must be identical before and after. A report that
# dirtied the tree measured a different tree than the one it names.
# ============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 2

MAKE_BIN="${MAKE:?platform-report must be run through make (make platform-report) so it reports the make that runs it}"
MAKE_VER="${PLATFORM_REPORT_MAKE_VERSION:-unknown}"
TARGETS="${PLATFORM_REPORT_TARGETS:-static-check docs-lint}"
OUT="${PLATFORM_REPORT_DIR:-${TMPDIR:-/tmp}/platform-report}"
mkdir -p "$OUT" || exit 2
case "$OUT" in "$REPO_ROOT"/*) printf 'platform-report: PLATFORM_REPORT_DIR must be OUTSIDE the repo (it would dirty the tree it measures)\n' >&2; exit 2 ;; esac

# ── host facts ───────────────────────────────────────────────────────────────────────────
os="unknown"
if [ "$(uname -s)" = Darwin ]; then
  os="macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
elif [ -r /etc/os-release ]; then
  os="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-$NAME}")"
fi
arch="$(uname -m)"
git_v="$(git --version 2>/dev/null | awk '{print $3}')"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
# A row must not name a commit it does not match: uncommitted changes (tracked OR untracked) make
# the measured tree something no commit describes.
[ -z "$(git status --porcelain 2>/dev/null)" ] || commit="${commit}+dirty"
engine_v=""
for e in podman docker; do
  command -v "$e" >/dev/null 2>&1 || continue
  c="$("$e" version --format '{{.Client.Version}}' 2>/dev/null || true)"
  # podman names the field OsArch; docker splits it into Os + Arch. Asking podman for Os/Arch
  # prints "linux/" -- measured 2026-09-25 -- so each engine gets its own template.
  case "$e" in
    podman) fmt='{{.Server.Version}} {{.Server.OsArch}}' ;;
    *)      fmt='{{.Server.Version}} {{.Server.Os}}/{{.Server.Arch}}' ;;
  esac
  s="$("$e" version --format "$fmt" 2>/dev/null || true)"
  engine_v="${engine_v}${engine_v:+, }${e} ${c:-?}${s:+ (server ${s})}"
done
documented="$(grep -cE '^[a-zA-Z0-9_.-]+:.*##' Makefile || true)"

printf 'platform-report @ %s on %s\n' "$commit" "$(date -u +%Y-%m-%dT%H:%MZ)"
printf '  OS      : %s\n  arch    : %s\n  make    : GNU Make %s (%s)\n  bash    : %s\n  git     : %s\n  engine  : %s\n' \
  "$os" "$arch" "$MAKE_VER" "$MAKE_BIN" "${BASH_VERSION%%(*}" "$git_v" "${engine_v:-none}"
printf '  pinned  : .mise.toml @ %s\n\n' "$commit"

# ── run ──────────────────────────────────────────────────────────────────────────────────
before="$(git status --porcelain 2>/dev/null)"
fail=0; results=""; executed_file="$OUT/executed.txt"; : > "$executed_file"
for t in $TARGETS; do
  log="$OUT/${t}.log"
  t0=$SECONDS
  "$MAKE_BIN" --no-print-directory --trace "$t" > "$log" 2>&1
  rc=$?
  # --trace prints every target it considers: "target 'x' does not exist" / "update target 'x' due to:"
  grep -oE "(update )?target '[^']+' (does not exist|due to)" "$log" \
    | sed -E "s/^(update )?target '([^']+)'.*/\2/" >> "$executed_file"
  verdict="$(grep -E '^run-test-set \[' "$log" | tail -1 | sed -E 's/^run-test-set \[[^]]*\]: //')"
  status=PASS; [ "$rc" -eq 0 ] || { status="FAIL rc=$rc"; fail=1; }
  printf '  %-6s %-20s %4ds  %s\n' "${status%% *}" "$t" "$((SECONDS - t0))" "${verdict:-}"
  results="${results}${results:+; }\`${t}\` ${status}${verdict:+ (${verdict})}"
done
after="$(git status --porcelain 2>/dev/null)"

executed="$(sort -u "$executed_file" | grep -cxFf <(grep -oE '^[a-zA-Z0-9_.-]+:.*##' Makefile | cut -d: -f1) || true)"
printf '\n  %s of %s documented targets executed by this report; the rest were NOT run by it.\n' "$executed" "$documented"
printf '  logs: %s\n' "$OUT"

if [ "$before" != "$after" ]; then
  printf '\nFAIL: the run changed git status -- the row would describe a tree that no longer exists:\n' >&2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  fail=1
fi

# shellcheck disable=SC2016  # the backticks are LITERAL markdown code spans in the printed row
printf '\nREADME row:\n| %s | %s | GNU Make %s, bash %s, git %s, %s | %s @ `%s`, %s |\n' \
  "$os" "$arch" "$MAKE_VER" "${BASH_VERSION%%(*}" "$git_v" "${engine_v:-no engine}" \
  "$results" "$commit" "$(date -u +%Y-%m-%d)"

[ "$fail" -eq 0 ] && printf '\nplatform-report: OK\n' || printf '\nplatform-report: FAILED\n'
exit "$fail"
