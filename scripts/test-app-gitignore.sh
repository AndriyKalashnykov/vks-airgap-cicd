#!/usr/bin/env bash
# ci-tier: fast — offline; throwaway git repos under mktemp. No network, no cluster.
#
# test-app-gitignore.sh — RED-proofs for check-app-gitignore.sh (B535).
#
# ⚠️ IT OPERATES ON A THROWAWAY COPY, never the real tree. The gate's instrument is `git ls-files`,
# so the fixture must be a real git repo — a `test -f` fixture would pass a gate this one fails, and
# that difference IS the property under test (present-but-untracked never reaches the operator).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

# Build a minimal fixture repo: registry + N app dirs, each optionally carrying a tracked .gitignore.
mkfix() { # mkfix <n-apps> <n-with-gitignore>
  local T; T="$(mktemp -d /tmp/appgi.XXXX)"
  mkdir -p "$T/scripts/lib" "$T/apps"
  cp "${SCRIPT_DIR}/lib/os.sh" "$T/scripts/lib/os.sh"
  cp "${SCRIPT_DIR}/check-app-gitignore.sh" "$T/scripts/"
  printf '' > "$T/apps/registry.tsv"
  local i
  for i in $(seq 1 "$1"); do
    mkdir -p "$T/apps/l${i}/app${i}"
    printf 'x\n' > "$T/apps/l${i}/app${i}/main.src"
    printf 'app%s\tl%s\tapps/l%s/app%s\t-\n' "$i" "$i" "$i" "$i" >> "$T/apps/registry.tsv"
    [ "$i" -le "$2" ] && printf 'obj/\n' > "$T/apps/l${i}/app${i}/.gitignore"
  done
  ( cd "$T" && git init -q . && git add -A >/dev/null 2>&1 \
      && git -c user.email=t@t -c user.name=t commit -qm f >/dev/null 2>&1 )
  printf '%s' "$T"
}
run() { ( cd "$1" && REPO_ROOT="$1" bash scripts/check-app-gitignore.sh >"$1/.out" 2>&1 ); echo $?; }

# ── 1. all apps carry one -> GREEN ───────────────────────────────────────────────────────────────
T="$(mkfix 3 3)"; rc="$(run "$T")"
if [ "$rc" -eq 0 ] && grep -q 'all 3 app' "$T/.out"; then ok "3 of 3 tracked -> GREEN, denominator 3"
else bad "3 of 3 tracked should be GREEN; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 2. one MISSING -> RED, and it must NAME the app ──────────────────────────────────────────────
T="$(mkfix 3 2)"; rc="$(run "$T")"
if [ "$rc" -ne 0 ] && grep -q 'apps/l3/app3/.gitignore' "$T/.out"; then ok "1 missing -> RED and names the app dir"
else bad "1 missing must be RED and name apps/l3/app3; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 3. PRESENT BUT UNTRACKED -> RED. This is the case a `test -f` gate would PASS, and it is the
#      whole reason the gate uses `git ls-files`. `cp -a` copies it, but the operator never gets it.
T="$(mkfix 3 2)"; printf 'obj/\n' > "$T/apps/l3/app3/.gitignore"; rc="$(run "$T")"
if [ "$rc" -ne 0 ]; then ok "present-but-UNTRACKED -> still RED (a test -f gate would pass this)"
else bad "an untracked .gitignore must NOT satisfy the gate; rc=$rc"; fi; rm -rf "$T"

# ── 4. ZERO apps parsed -> RED. A gate that looked at nothing must not report a clean repo. ───────
T="$(mkfix 2 2)"; : > "$T/apps/registry.tsv"; rc="$(run "$T")"
if [ "$rc" -ne 0 ] && grep -q 'ZERO apps' "$T/.out"; then ok "empty registry -> RED (vacuity guard), not a false GREEN"
else bad "an empty registry must be RED, not 'OK — all 0 apps'; rc=$rc: $(tail -1 "$T/.out")"; fi; rm -rf "$T"

# ── 5. missing registry -> RED with a message naming the FILE it could not read ──────────────────
T="$(mkfix 2 2)"; rm -f "$T/apps/registry.tsv"; rc="$(run "$T")"
if [ "$rc" -ne 0 ] && grep -q 'registry.tsv' "$T/.out"; then ok "missing registry -> RED, and names the file it read"
else bad "missing registry must be RED and name the file; rc=$rc"; fi; rm -rf "$T"

# ── 6. THE REAL TREE must be green (this is the one that regresses if someone deletes a file) ────
rc=0; bash "${SCRIPT_DIR}/check-app-gitignore.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then ok "the real repo passes"; else bad "the real repo FAILS the gate (rc=$rc)"; fi

printf '\ntest-app-gitignore: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
