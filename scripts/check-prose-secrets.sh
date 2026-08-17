#!/usr/bin/env bash
# check-prose-secrets.sh — catch NATURAL-LANGUAGE / prose credentials in *.md.
#
# gitleaks (already run by `make secrets`) is tuned for MACHINE-shaped secrets:
# `KEY=value` assignments, known token prefixes (ghp_/AKIA…/xox…), high-entropy
# base64/hex blobs, PEM blocks. It does NOT reliably catch a credential written
# in prose in a markdown runbook (e.g. "use admin / uS$yQqHN4YMCpB1K@eO@").
# This gate is the COMPLEMENT: a case-insensitive grep for credential-shaped
# prose over *.md, minus a narrow, commented allowlist of legitimate non-secrets.
# See ~/projects/claude-config/rules/common/security.md
#   "gitleaks 'no leaks found' ≠ 'no secrets present'".
#
# Exit 1 (printing the offending lines) on a real hit; exit 0 when clean.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || { echo "check-prose-secrets: cannot cd to repo root"; exit 1; }

# Credential-shaped PROSE (from security.md). The `admin ?/ ?[A-Za-z0-9]` arm
# catches a restated `admin/Harbor12345`-style default AND `admin / password`,
# while NOT matching plain URL paths like `admin/settings` (verified against the
# repo: the only `admin/<alnum>` hit is a real restated default credential).
# ⚠️ `?(:|/[^/])` and NOT `?[:/]` on the four value-bearing arms: a DOUBLED slash is jq's
# ALTERNATIVE operator, not a separator. `jq -r '.token // empty'` (lib/argocd.sh:343) matched the
# old form and reddened the `secrets` job on a docs-only PR, where that job IS the whole gate —
# and then the write-up OF that false positive was flagged six times, because documenting the trap
# means writing the trigger (B164).
# ⛔ THE OBVIOUS FIX — a `grep -vE` allowlist for the jq form — IS REFUTED, with a measured exploit:
# the chain is LINE-level and BACKLOG.md lines run to 12,845 characters, so excluding a line that
# contains a jq expression suppresses the WHOLE ROW, credential included. Proven both ways: a line
# carrying `.token // empty` AND `admin / <value>` is REPORTED by this form and was SILENCED by the
# allowlist. That case is pinned in --selftest below. Narrow the MATCH, never exclude the LINE.
# MEASURED residual, benign and recorded rather than hidden: this loses `token /` and `password /`
# when the separator ends the LINE — by construction such a line carries no value after it.
# The `admin ?/ ?[A-Za-z0-9]` arm needs no change: it already demands an alphanumeric after the
# slash, so `.admin // empty` never matched it.
PATTERN='password ?(:|/[^/])|passwd|pwd ?(:|/[^/])|sshpass -p|admin ?/ ?[A-Za-z0-9]|token ?(:|/[^/])|secret ?(:|/[^/])'

# `--untracked` covers tracked AND present-but-untracked *.md (it still honours
# .gitignore, so bundle/ and other ignored trees are skipped) — so a scratch
# runbook staged locally is caught before it can be committed. Capture the full
# result and test it (NEVER `grep -q` under pipefail — SIGPIPE false-negatives;
# see coding-style.md). `|| true` absorbs the no-match exit of the filter chain.
# THE EXCLUSION CHAIN, as a FUNCTION so the selftest below and the real run share ONE
# implementation and ONE $PATTERN. A selftest that copied the pattern into a second file would
# be a second source of truth, and it would go stale the first time either was edited.
_prose_exclude() {
  # Documented placeholder conventions — the security.md-preferred safe form.
  grep -vE '<SET-|<REDACTED|placeholder' |
  # Secret-handling MECHANISMS, not values (stdin/fd delivery, k8s secret refs).
  grep -vE 'password-stdin|password-fd|--passphrase-fd|kind: Secret|secretName|secretRef|secretKeyRef' |
  # Env-var NAME references (SNAKE_CASE). gitleaks owns real KEY=value secrets;
  # this gate targets prose, so a bare env-var name (HARBOR_PASSWORD, OSS_INDEX_TOKEN,
  # GPG_PASSPHRASE, …) is a reference, not a leak.
  # NOTE the `_` inside the character class. It used to be `[A-Z][A-Z0-9]*_(TOKEN|…)`, which CANNOT match
  # a var name carrying a SECOND underscore: `ARGOCD_AUTH_TOKEN` fails, because the segment before
  # `_TOKEN` is `ARGOCD_AUTH` and `[A-Z0-9]*` does not admit `_`. So the allowlist silently missed exactly
  # the multi-word names this repo uses, and the gate flagged honest var-name REFERENCES as leaks.
  grep -vE '\b[A-Z][A-Z0-9_]*_(PASSWORD|PASSWD|PWD|TOKEN|SECRET|KEY|PASSPHRASE)\b' |
  # A slash-separated PROSE LIST OF NOUNS is not a credential: "Istio exposes no login/token/admin API",
  # "control-plane (cluster-ADMIN/SSH) access". The `token ?[:/]` and `admin ?/ ?[A-Za-z0-9]` patterns
  # match the separator, not a value — and there IS no value: the next token is another English noun in
  # the list. Kept deliberately tight (letters only, then a word boundary), so `admin / Harbor12345` — a
  # real leak — still trips the gate, because a digit-bearing value does not match `[A-Za-z]+\b`.
  grep -vE '\b(login|token|admin|secret|password)/(login|token|admin|secret|password|ssh|sso|rbac|api)\b' |
  grep -vE '\b[A-Z]+/(SSH|SSO|API|RBAC|TLS)\b' |
  # "…`--kubeconfig` swallows the next token: `kubectl …`" — "token" here is a SHELL WORD, not a
  # credential, and the colon is prose punctuation introducing a code span. What follows is a backtick,
  # never a value.
  grep -vE '\bnext token: *`' |
  # `$PWD/` is the shell's working-directory variable, not a password. The `pwd ?[:/]` pattern (which
  # hunts for prose like `pwd: hunter2`) matches it, and every `export KUBECONFIG=$PWD/secrets/...` in
  # a runbook trips the gate. A path is not a credential.
  grep -vE '\$\{?PWD\}?/' |
  # README "**Get the admin password:**" — a value-less markdown instruction
  # heading; the NEXT line shows the `kubectl get secret … | base64 -d` read
  # command (reference-the-source, exactly what security.md prescribes), no value.
  grep -vE 'password:\*\*' |
  # README "…no download client / token / network at install time." — prose
  # slash-list stating no auth token is NEEDED, not a credential value.
  grep -vE '/ token / network' ||
  true
}

# _prose_scan — apply PATTERN then the chain to TEXT on stdin. Used only by --selftest; the real
# run uses `git grep` so it can report file:line.
_prose_scan() { grep -nEi "$PATTERN" 2>/dev/null | _prose_exclude; }

# --selftest — THE POSITIVE CONTROL. Without it this gate has never been proven to CATCH anything:
# a matcher that can never match prints "OK — examined 10724 line(s)", BYTE-IDENTICAL to a healthy
# green, because the denominator at the bottom comes from a SEPARATE `git grep -I -n ''` that never
# touches $PATTERN — it measures the CORPUS, not the MATCHER. MEASURED 2026-08-17 with a deliberately
# dead pattern: raw hits 0, denominator unchanged, message identical. So every edit to PATTERN or the
# chain — including a well-meant narrowing — could weaken this gate silently. This is the gate whose
# absence let three live plaintext passwords sit in a runbook that gitleaks reported clean.
if [ "${1:-}" = --selftest ]; then
  _st_pass=0; _st_fail=0
  # MUST BE CAUGHT. A high-entropy value on purpose: security.md records that a low-entropy
  # placeholder can false-pass a scanner and make a WORKING gate look broken.
  _must_catch() {
    if [ -n "$(printf '%s\n' "$2" | _prose_scan)" ]; then _st_pass=$((_st_pass+1)); printf '  PASS  catches   %s\n' "$1"
    else _st_fail=$((_st_fail+1)); printf '  FAIL  MISSED    %s\n' "$1"; fi
  }
  # MUST NOT BE CAUGHT — a false positive taxes every author and trains "make the gate shut up".
  _must_pass() {
    if [ -z "$(printf '%s\n' "$2" | _prose_scan)" ]; then _st_pass=$((_st_pass+1)); printf '  PASS  allows    %s\n' "$1"
    else _st_fail=$((_st_fail+1)); printf '  FAIL  FLAGGED   %s\n' "$1"; fi
  }
  echo "== check-prose-secrets --selftest =="
  # ⚠️ THE FIXTURE VALUES ARE DELIBERATELY LOW-ENTROPY AND OBVIOUSLY FAKE. Do NOT "improve" them to
# random high-entropy strings: this gate matches the PROSE SHAPE ("token:", "secret:"), never the
# value, so entropy buys it nothing -- and MEASURED 2026-08-17, high-entropy fixtures made the
# SIBLING scanner (gitleaks, same `make secrets-scan` target) report "leaks found: 2". Because
# `secrets` runs BEFORE `prose-secrets`, that meant THIS gate never executed in CI at all.
# A path allowlist is NOT the fix either: check-secrets-untracked FAILS if an allowlisted path is
# tracked, and this file is tracked. Low-entropy fixtures are also MORE representative -- a real
# prose leak looks like "password: hunter2", not like a random token.
_must_catch 'admin / <value>'          'use admin / Sup3rSecret99x7 on the bastion'
  _must_catch 'token: <value>'           'the token: EXAMPLE-NOT-A-REAL-TOKEN is in the vault'
  _must_catch 'token / <value>'          'log in with token / EXAMPLE-NOT-A-REAL-TOKEN'
  _must_catch 'password: <value>'        'the password: p8krX3cBoBLI323 was rotated'
  _must_catch 'sshpass -p'               "sshpass -p 'Sekrit1x9Qm' ssh root@host"
  _must_catch 'secret: <value>'          'the secret: EXAMPLE-NOT-A-REAL-SECRET belongs to ops'
  _must_catch 'pwd: <value>'             'root pwd: letmein9Xq2 on the console'
  # THE EXPLOIT the B164 idea round built: a jq expression and a REAL credential on ONE line. A
  # LINE-level allowlist for the jq form would suppress this entire line — and BACKLOG.md lines run
  # to 12,845 characters. This case is why the fix narrows the PATTERN instead of excluding a line.
  _must_catch 'jq form AND a real credential on ONE line' \
    'B99 fix jq -r ".token // empty" — meanwhile ops confirmed admin / Sup3rSecret99x7 on the bastion'
  # MUST NOT: jq's alternative operator after a credential-named field. Three forms.
  _must_pass  'jq .token // empty'       'the check ends jq -r ".token // empty" (lib/argocd.sh:343)'
  _must_pass  'jq .password // null'     'the same shape bites .password // null in a filter'
  _must_pass  'jq .secret // ""'         'and .secret // "" behaves identically'
  # MUST NOT: the two previously-known false-positive classes.
  # shellcheck disable=SC2016  # the literal $PWD is the fixture; expanding it defeats the case
  _must_pass  'shell $PWD in a mount'    'run it with -v $PWD/secrets:/s to mount the dir'
  _must_pass  'SNAKE_CASE var reference' 'set HARBOR_PASSWORD and ARGOCD_AUTH_TOKEN in .env'
  _must_pass  'prose noun slash-list'    'Istio exposes no login/token/admin API at all'
  _must_pass  'documented placeholder'   'HARBOR_PASSWORD=<SET-IN-PASSWORD-MANAGER>'
  _must_pass  'secret-handling mechanism' 'pipe it with --password-stdin, never on argv'
  echo "  ${_st_pass} passed, ${_st_fail} failed"
  [ "$_st_fail" -eq 0 ] || exit 1
  exit 0
fi

# `|| true` INSIDE the braces, on the git-grep side — NOT at the end of the chain. With ZERO raw
# matches (a dead PATTERN, or simply a corpus with nothing credential-shaped in it) `git grep` exits
# 1, and under `set -euo pipefail` that propagates through the pipe to the ASSIGNMENT and kills the
# script silently, rc=1 with no output. MEASURED while RED-proving the selftest: an earlier draft of
# this refactor put the `|| true` inside _prose_exclude and did exactly that. Same shape as the
# `lines=` line below, and the same documented `x=$(grep ...)` trap.
hits="$( { git grep --untracked -nEi "$PATTERN" -- '*.md' 2>/dev/null || true; } | _prose_exclude )"

# ITEM count. This gate had NO denominator at all: it is a pure "no hits => green" grep, so an
# empty corpus and a clean corpus were byte-identical in its output. Counting MATCHES is wrong in
# the other direction (zero matches is the HEALTHY state); the item the verdict is actually over is
# LINES SEARCHED, mirroring check-doc-robot-quoting. NOTE: `die` is deliberately NOT used -- this
# gate does not source lib/os.sh, so it would be `command not found` -> rc 127, which the vacuity
# harness classifies as INCONCLUSIVE (never a pass) rather than a demonstrated RED.
# `|| true` INSIDE the braces, before the pipe: with every doc empty, `git grep` matches nothing and
# exits 1, and under `set -euo pipefail` that non-zero propagates through the pipeline to the
# ASSIGNMENT, killing the script silently (rc=1, no output) -- the documented `x=$(grep ...)` trap.
# The vacuity harness caught exactly that here and reported INCONCLUSIVE rather than banking a pass.
lines="$( { git grep --untracked -I -n '' -- '*.md' 2>/dev/null || true; } | wc -l | tr -d ' ')"
if [ "${lines:-0}" -eq 0 ]; then
  echo "check-prose-secrets: examined 0 line(s) of *.md — the gate has gone BLIND (pathspec broken or every doc empty). A clean result here would mean nothing." >&2
  exit 1
fi

if [ -n "$hits" ]; then
  echo "ERROR: credential-shaped PROSE found in markdown (gitleaks does NOT catch these):"
  echo "$hits"
  echo
  echo "Fix per security.md: do not restate a credential VALUE in prose — REFERENCE"
  echo "its source instead (e.g. 'the ARGOCD_ADMIN_PASSWORD in .env.example', or show"
  echo "the read command 'kubectl get secret … | base64 -d')."
  echo "If a hit is a value-less false positive, add a NARROW allowlist grep to"
  echo "scripts/check-prose-secrets.sh with a comment naming exactly why."
  exit 1
fi
echo "check-prose-secrets: OK — examined ${lines} line(s) of *.md, no prose credentials"
