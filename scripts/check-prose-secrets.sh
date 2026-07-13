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
PATTERN='password ?[:/]|passwd|pwd ?[:/]|sshpass -p|admin ?/ ?[A-Za-z0-9]|token ?[:/]|secret ?[:/]'

# `--untracked` covers tracked AND present-but-untracked *.md (it still honours
# .gitignore, so bundle/ and other ignored trees are skipped) — so a scratch
# runbook staged locally is caught before it can be committed. Capture the full
# result and test it (NEVER `grep -q` under pipefail — SIGPIPE false-negatives;
# see coding-style.md). `|| true` absorbs the no-match exit of the filter chain.
hits="$(git grep --untracked -nEi "$PATTERN" -- '*.md' 2>/dev/null |
  # Documented placeholder conventions — the security.md-preferred safe form.
  grep -vE '<SET-|<REDACTED|placeholder' |
  # Secret-handling MECHANISMS, not values (stdin/fd delivery, k8s secret refs).
  grep -vE 'password-stdin|password-fd|--passphrase-fd|kind: Secret|secretName|secretRef|secretKeyRef' |
  # Env-var NAME references (SNAKE_CASE). gitleaks owns real KEY=value secrets;
  # this gate targets prose, so a bare env-var name (HARBOR_PASSWORD, OSS_INDEX_TOKEN,
  # GPG_PASSPHRASE, …) is a reference, not a leak.
  grep -vE '\b[A-Z][A-Z0-9]*_(PASSWORD|PASSWD|PWD|TOKEN|SECRET|KEY|PASSPHRASE)\b' |
  # `$PWD/` is the shell's working-directory variable, not a password. The `pwd ?[:/]` pattern (which
  # hunts for prose like `pwd: hunter2`) matches it, and every `export KUBECONFIG=$PWD/secrets/...` in
  # a runbook trips the gate. A path is not a credential.
  grep -vE '\$\{?PWD\}?/' |
  grep -vE 'GPG_' |
  # README "**Get the admin password:**" — a value-less markdown instruction
  # heading; the NEXT line shows the `kubectl get secret … | base64 -d` read
  # command (reference-the-source, exactly what security.md prescribes), no value.
  grep -vE 'password:\*\*' |
  # README "…no download client / token / network at install time." — prose
  # slash-list stating no auth token is NEEDED, not a credential value.
  grep -vE '/ token / network' ||
  true)"

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
echo "check-prose-secrets: OK (no prose credentials in *.md)"
