#!/usr/bin/env bash
# test-shell-rc-file.sh — pin shell_rc_file and the `make shell-rc-file` target across shells.
#
# WHY THIS EXISTS AS AN OFFLINE TEST: the VM matrix CANNOT catch a shell-portability defect in the
# runbook, by construction. walkbox-vm.sh gives the `vks` user `shell: /bin/bash` on BOTH OS images,
# and walk-matrix.sh runs every block under `bash /tmp/walk.sh` — so $SHELL is /bin/bash on every
# row, Photon and Ubuntu alike. scenario-1 hardcoded `source ~/.bashrc` for months and two GREEN
# rows (ubuntu + photon) never noticed, because the harness is a single-shell environment. It was
# caught by a human reading the document, on a box whose shell is zsh.
#
# So the coverage has to come from here. This asserts the RESOLVER, which is what the runbook now
# calls instead of naming a file.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# shellcheck source=scripts/lib/os.sh
. "${REPO_ROOT}/scripts/lib/os.sh"

# ── 1. the resolver answers for every shell the repo claims to support ───────────────────────
#    HOME is pinned so the expectation is exact rather than "contains .zshrc".
H=/tmp/rcprobe-home
while IFS='|' read -r sh want; do
  [ -n "$sh" ] || continue
  got="$(SHELL="$sh" HOME="$H" ZDOTDIR="" shell_rc_file)"
  if [ "$got" = "$want" ]; then ok "shell_rc_file: $(basename "$sh") -> $want"
  else bad "shell_rc_file: $(basename "$sh")" "wanted '$want', got '$got'"; fi
done <<EOF
/bin/bash|$H/.bashrc
/usr/bin/zsh|$H/.zshrc
/bin/fish|$H/.config/fish/config.fish
/bin/ksh|$H/.kshrc
EOF

# ── 2. an UNSUPPORTED shell returns EMPTY — it must not guess ────────────────────────────────
# A guess here is the whole defect: naming ~/.bashrc for a shell that does not read it sends the
# operator to edit a file nothing will ever load, and the failure surfaces much later as "the tools
# are not on PATH".
got="$(SHELL=/bin/tcsh HOME="$H" shell_rc_file)"
if [ -z "$got" ]; then ok "an UNSUPPORTED shell returns empty (it does not guess)"
else bad "an UNSUPPORTED shell returns empty" "got '$got'"; fi

# ── 3. zsh honours ZDOTDIR — a zsh user who moved their rc file is not sent to \$HOME ─────────
got="$(SHELL=/usr/bin/zsh HOME="$H" ZDOTDIR=/tmp/zdot shell_rc_file)"
if [ "$got" = "/tmp/zdot/.zshrc" ]; then ok "zsh honours ZDOTDIR"
else bad "zsh honours ZDOTDIR" "wanted /tmp/zdot/.zshrc, got '$got'"; fi

# ── 4. the TARGET the runbook actually calls agrees with the resolver, and FAILS on unknown ──
# scenario-1 runs `. "$(make -s shell-rc-file)"`. If the target ever printed something on an
# unsupported shell, that line would source a path nobody maintains.
got="$(cd "$REPO_ROOT" && SHELL=/usr/bin/zsh HOME="$H" ZDOTDIR="" make -s shell-rc-file 2>/dev/null)"
if [ "$got" = "$H/.zshrc" ]; then ok "make shell-rc-file agrees with the resolver (zsh)"
else bad "make shell-rc-file agrees with the resolver (zsh)" "got '$got'"; fi

if ! (cd "$REPO_ROOT" && SHELL=/bin/tcsh HOME="$H" make -s shell-rc-file >/dev/null 2>&1); then
  ok "make shell-rc-file FAILS on an unsupported shell (never prints a guess)"
else
  bad "make shell-rc-file FAILS on an unsupported shell" "it exited 0"
fi

# ── 5. the runbook must not hardcode an rc file next to that command ─────────────────────────
# This is the defect itself, pinned: `source ~/.bashrc` on a line that follows a shell-DETECTING
# command. Matches the runbook only, not the notes.
if grep -nE '^\s*(source|\.)\s+~/\.(bashrc|zshrc|profile)' "${REPO_ROOT}/docs/scenario-1.md" "${REPO_ROOT}/docs/scenario-2.md" "${REPO_ROOT}/docs/common-bootstrap.md" >/dev/null 2>&1; then
  bad "no runbook hardcodes an rc file" "$(grep -nE '^\s*(source|\.)\s+~/\.(bashrc|zshrc|profile)' "${REPO_ROOT}"/docs/scenario-*.md "${REPO_ROOT}"/docs/common-bootstrap.md | head -2)"
else
  ok "no runbook hardcodes ~/.bashrc where the shell is detected"
fi

printf '\ntest-shell-rc-file: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'test-shell-rc-file: OK\n'
