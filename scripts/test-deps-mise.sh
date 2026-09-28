#!/usr/bin/env bash
# ci-tier: fast — offline; drives `make deps-mise` against a FAKE mise, no network.
# test-deps-mise.sh — deps-mise must SUCCEED when the only tools that failed to install are ci-only
# lint/scan tools (a blocked PyPI must not fail `make deps` on a corporate Mac), and must still FAIL
# when anything else is missing — including when it cannot even tell what is missing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.local/bin"
# The Makefile puts $HOME/.local/bin ahead of PATH, so a fake HOME is where the fake mise must live.
cat > "$tmp/home/.local/bin/mise" <<'EOF'
#!/bin/bash
echo "call $*" >> "$FAKE_LOG"
case "$1" in
  install) [ "$FAKE_MODE" = ok ] && exit 0; exit 1 ;;
  ls) case "$FAKE_MODE" in
        lint) echo "yamllint  1.38.0 (missing)" ;;
        req)  printf 'yamllint 1.38.0 (missing)\nkubectl 1.36.4 (missing)\n' ;;
        lserr) exit 1 ;;
      esac; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/home/.local/bin/mise"

run() {  # run <mode> -> sets rc, installs, out
  : > "$tmp/log"
  out="$(FAKE_MODE="$1" FAKE_LOG="$tmp/log" HOME="$tmp/home" make --no-print-directory deps-mise 2>&1)"; rc=$?
  installs="$(grep -c '^call install' "$tmp/log" || true)"
}

run ok
if [ "$rc" -eq 0 ] && [ "$installs" = 1 ]; then ok "all tools install: one attempt, rc=0"
else bad "all tools install: rc=$rc installs=$installs"; fi

run lint
if [ "$rc" -eq 0 ] && [ "$installs" = 1 ] && printf '%s' "$out" | grep -q 'WARNING: deps succeeded WITHOUT: yamllint'; then
  ok "only a ci-only tool missing: no retry, warns, rc=0"
else bad "only a ci-only tool missing: rc=$rc installs=$installs out=${out: -200}"; fi

run req
if [ "$rc" -ne 0 ] && [ "$installs" = 2 ]; then ok "a required tool missing: retries once, then fails (rc=$rc)"
else bad "a required tool missing: rc=$rc installs=$installs"; fi

run lserr
if [ "$rc" -ne 0 ]; then ok "cannot list what is missing: fails closed (rc=$rc)"
else bad "cannot list what is missing: rc=0 — a failure was reported as success"; fi

# ── PyPI reachability (unattended stand-in for a corporate network) ──────────────────────────────
# A fake curl answers or times out per host; the fake mise reports yamllint as a MISSING pypi: tool,
# and its install fails (like uv timing out) unless yamllint is disabled OR the wheel host is up.
# MEASURED on the operator's Mac: pypi.org answers and files.pythonhosted.org times out — so a probe
# of only one host is the bug this section exists to catch.
cat > "$tmp/home/.local/bin/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in https://*)
  h="${a#https://}"; h="${h%%/*}"
  case " $FAKE_BLOCKED " in *" $h "*) echo "curl: (28) Connection timed out" >&2; exit 28 ;; esac ;;
esac; done; exit 0
EOF
chmod +x "$tmp/home/.local/bin/curl"
cat > "$tmp/home/.local/bin/mise" <<'EOF'
#!/bin/bash
echo "call $* DISABLE=${MISE_DISABLE_TOOLS:-}" >> "$FAKE_LOG"
case "$1" in
  install)
    case ",${MISE_DISABLE_TOOLS:-}," in *,yamllint,*) exit 0 ;; esac
    case " $FAKE_BLOCKED " in *" files.pythonhosted.org "*|*" pypi.org "*) exit 1 ;; esac
    : > "$FAKE_STATE/yamllint"; exit 0 ;;
  ls)   [ -e "$FAKE_STATE/yamllint" ] || echo "yamllint  1.38.0 (missing)"; exit 0 ;;
  tool) echo "Backend:            pypi:yamllint"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/home/.local/bin/mise"

net() {  # net "<blocked hosts>" -> rc, out, log
  rm -rf "$tmp/state"; mkdir -p "$tmp/state"; : > "$tmp/log"
  out="$(FAKE_BLOCKED="$1" FAKE_STATE="$tmp/state" FAKE_LOG="$tmp/log" HOME="$tmp/home" \
         make --no-print-directory deps-mise 2>&1)"; rc=$?
}
for blocked in "files.pythonhosted.org" "pypi.org" "pypi.org files.pythonhosted.org"; do
  net "$blocked"
  tried="$(grep -c '^call install DISABLE=$' "$tmp/log" || true)"
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'PyPI is unreachable' \
     && printf '%s' "$out" | grep -q 'WARNING: deps succeeded WITHOUT: yamllint' && [ "$tried" = 0 ]; then
    ok "blocked [$blocked]: skips yamllint without ever attempting it, rc=0"
  else bad "blocked [$blocked]: rc=$rc attempts-without-skip=$tried out=${out: -200}"; fi
done
net ""
if [ "$rc" -eq 0 ] && [ -e "$tmp/state/yamllint" ] && ! printf '%s' "$out" | grep -qE 'unreachable|WARNING'; then
  ok "nothing blocked: yamllint is installed, no skip, no warning"
else bad "nothing blocked: rc=$rc installed=$([ -e "$tmp/state/yamllint" ] && echo y || echo n) out=${out: -200}"; fi

printf 'test-deps-mise: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
