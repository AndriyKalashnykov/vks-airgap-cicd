#!/usr/bin/env bash
# ci-tier: fast — offline; a throwaway COPY of scripts/lib under mktemp, canary files only (~4s).
# ============================================================================
# scripts/lib/test-sandbox.sh must actually CLOSE what it says it closes — measured against the
# real resolver and the real load_env, with every hazard PRESENT.
#
# WHY THE CONTROL ARM IS THE POINT (B751). "The resolver found nothing" is green on a box that has
# no lab, no .env and no secrets/ at all -- which is every CI runner. So each hazard is PLANTED
# first (a canary Supervisor kubeconfig in all four resolver slots, canary values in .env,
# .env.state and .env.kind), the UNFENCED probe is shown to reach every one of them, and only then
# is the fenced probe required to reach none. A fence that is green only where there was nothing
# to fence proves nothing.
#
# THE FAKE REPO is a copy of scripts/lib/ and scripts/test-guard/ in a temp dir, so the helper's
# own "real repo" is a tree this test owns and can fill with canaries. Nothing here reads or
# writes the checkout it runs from, and every probe runs with a throwaway HOME.
# ============================================================================
set -uo pipefail
# This test is fenced like any other that starts a background job. Every probe below then UNDOES
# the fence explicitly for its control arm (`env -u ...`, its own HOME), which is the point.
# shellcheck source=scripts/lib/test-sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# ---- the fake repo, with every hazard planted ---------------------------------------------------
F="$T/fake"; mkdir -p "$F/scripts" "$F/secrets" "$F/docs" "$F/bundle" "$T/home/.local/state/nested-lab"
cp -r "$SCRIPTS/lib" "$F/scripts/lib"
cp -r "$SCRIPTS/test-guard" "$F/scripts/test-guard"
printf 'EXAMPLE_ONLY=from-example\n'                    > "$F/.env.example"
printf 'CANARY_DOTENV=from-dotenv\n'                    > "$F/.env"
printf 'CANARY_STATE=from-state\n'                      > "$F/.env.state"
printf 'CANARY_KIND=from-kind\n'                        > "$F/.env.kind"
printf 'canary-repo-secrets\n'                          > "$F/secrets/supervisor.kubeconfig"
printf 'canary-lab\n'                                   > "$T/home/.local/state/nested-lab/kubeconfig"
printf 'canary-argocd\n'                                > "$T/argocd.kubeconfig"
printf 'canary-explicit\n'                              > "$T/explicit.kubeconfig"
: > "$F/docs/marker"

# The probe: what a test does -- (optionally) source the helper, then lib/os.sh, then ask the real
# resolver and the real load_env what they can see. One KEY=value line per fact.
cat > "$F/scripts/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PROBE_FENCED:-0}" = 1 ]; then . "$here/lib/test-sandbox.sh"; fi
# KUBECONFIG as the helper left it, read BEFORE load_env gives it a default of its own
if [ -n "${KUBECONFIG+set}" ]; then _ambient_kc="$KUBECONFIG"; fi
. "$here/lib/os.sh" >/dev/null 2>&1
. "$here/lib/state.sh" >/dev/null 2>&1
printf 'resolver=%s\n' "$(supervisor_kubeconfig 2>/dev/null || printf NONE)"
load_env >/dev/null 2>&1
printf 'dotenv=%s\nstate=%s\nkind=%s\nexample=%s\n' "${CANARY_DOTENV:-}" "${CANARY_STATE:-}" "${CANARY_KIND:-}" "${EXAMPLE_ONLY:-}"
printf 'repo_root=%s\nhome=%s\nkubeconfig=%s\ntmpdir=%s\n' "$REPO_ROOT" "$HOME" "${_ambient_kc-UNSET}" "${TMPDIR:-}"
printf 'skip_dotenv=%s\nstate_var=%s\nstate_file=%s\nlab=%s\nsup=%s\nargocd_kc=%s\n' "${SKIP_DOTENV:-}" "${VKS_STATE_FILE-UNSET}" "$(state_file)" "${VKS_LAB_STATE_DIR:-}" "${VKS_SUPERVISOR_KUBECONFIG:-}" "${ARGOCD_KUBECONFIG-UNSET}"
printf 'path1=%s\n' "${PATH%%:*}"
printf 'sandbox=%s\nreal_repo=%s\nreal_home=%s\nsandbox_root=%s\n' "${TEST_SANDBOX:-}" "${TEST_REAL_REPO:-}" "${TEST_REAL_HOME:-}" "${TEST_SANDBOX_ROOT:-}"
printf 'sandbox_root_example=%s\n' "$([ -f "${TEST_SANDBOX_ROOT:-/nonexistent}/.env.example" ] && echo yes || echo no)"
printf 'has_scripts=%s\nhas_docs=%s\nhas_bundle=%s\nhas_git=%s\n' \
  "$([ -f "$REPO_ROOT/scripts/lib/os.sh" ] && echo yes || echo no)" "$([ -f "$REPO_ROOT/docs/marker" ] && echo yes || echo no)" \
  "$([ -e "$REPO_ROOT/bundle" ] && echo yes || echo no)" "$([ -e "$REPO_ROOT/.git" ] && echo yes || echo no)"
printf 'secrets=%s\n' "$(find "$REPO_ROOT/secrets/" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
printf 'mktemp=%s\n' "$(mktemp -u)"
PROBE
mkdir -p "$F/.git"

# probe <fenced: 0|1> [extra env...]  -- every hazard ambient, in every slot
probe() {
  local fenced="$1"; shift
  env -u REPO_ROOT -u SKIP_DOTENV -u VKS_LAB_STATE_DIR -u TMPDIR \
      -u __VKS_OS_SH_LOADED -u VKS_SUDO_PROBED VKS_STATE_FILE="$F/.env.state" \
      HOME="$T/home" KUBECONFIG="$T/explicit.kubeconfig" ARGOCD_KUBECONFIG="$T/argocd.kubeconfig" \
      VKS_SUPERVISOR_KUBECONFIG="$T/explicit.kubeconfig" PROBE_FENCED="$fenced" "$@" \
      bash "$F/scripts/probe.sh" 2>&1
}
val() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# ---- 1. POSITIVE CONTROL: unfenced, every hazard is reachable -----------------------------------
c="$(probe 0)"
if [ "$(val "$c" resolver)" = "$T/explicit.kubeconfig" ]; then ok "control: UNFENCED, the resolver returns the ambient Supervisor kubeconfig (slot 1)"
else bad "control: the unfenced resolver did not return the planted slot-1 canary" "$(val "$c" resolver)"; fi
for slot in "2 $F/secrets/supervisor.kubeconfig" "3 $T/argocd.kubeconfig" "4 $T/home/.local/state/nested-lab/kubeconfig"; do
  n="${slot%% *}"; want="${slot#* }"
  # knock out the earlier slots so THIS one is what the unfenced resolver falls to
  case "$n" in
    2) c2="$(probe 0 VKS_SUPERVISOR_KUBECONFIG=/nonexistent)" ;;
    3) mv "$F/secrets/supervisor.kubeconfig" "$T/held"; c2="$(probe 0 VKS_SUPERVISOR_KUBECONFIG=/nonexistent)"; mv "$T/held" "$F/secrets/supervisor.kubeconfig" ;;
    4) mv "$F/secrets/supervisor.kubeconfig" "$T/held"; c2="$(probe 0 VKS_SUPERVISOR_KUBECONFIG=/nonexistent ARGOCD_KUBECONFIG=)"; mv "$T/held" "$F/secrets/supervisor.kubeconfig" ;;
  esac
  if [ "$(val "$c2" resolver)" = "$want" ]; then ok "control: UNFENCED, resolver slot $n is reachable (${want##*/})"
  else bad "control: unfenced resolver slot $n did not return its canary" "got $(val "$c2" resolver)"; fi
done
if [ "$(val "$c" dotenv)" = from-dotenv ] && [ "$(val "$c" state)" = from-state ] && [ "$(val "$c" kind)" = from-kind ]; then
  ok "control: UNFENCED, load_env sources .env, .env.state AND the legacy .env.kind"
else bad "control: unfenced load_env did not read all three planted files" "dotenv=$(val "$c" dotenv) state=$(val "$c" state) kind=$(val "$c" kind)"; fi
# ...and SKIP_DOTENV=1 alone closes only ONE of the three -- the gap the helper exists for.
c3="$(probe 0 SKIP_DOTENV=1)"
if [ -z "$(val "$c3" dotenv)" ] && [ "$(val "$c3" state)" = from-state ] && [ "$(val "$c3" kind)" = from-kind ]; then
  ok "control: SKIP_DOTENV=1 ALONE skips .env and still sources .env.state and .env.kind"
else bad "control: SKIP_DOTENV=1 alone did not behave as recorded" "dotenv=$(val "$c3" dotenv) state=$(val "$c3" state) kind=$(val "$c3" kind)"; fi

# ---- 2. FENCED: the same ambient hazards, none reachable ----------------------------------------
f="$(probe 1)"
sb="$(val "$f" sandbox)"
if [ "$(val "$f" resolver)" = NONE ]; then ok "fenced: the resolver finds NO Supervisor kubeconfig, with a canary in all four slots"
else bad "fenced: the resolver still returned a kubeconfig" "$(val "$f" resolver)"; fi
if [ -z "$(val "$f" dotenv)" ] && [ -z "$(val "$f" state)" ] && [ -z "$(val "$f" kind)" ]; then
  ok "fenced: load_env reads none of .env, .env.state, .env.kind"
else bad "fenced: load_env still read a planted file" "dotenv=$(val "$f" dotenv) state=$(val "$f" state) kind=$(val "$f" kind)"; fi
if [ "$(val "$f" example)" = from-example ]; then ok "fenced: .env.example IS still read (a copy in the sandbox root)"
else bad "fenced: the sandbox root has no usable .env.example" "$(val "$f" example)"; fi
if [ -n "$sb" ] && has "$(val "$f" repo_root)" "$sb/" && [ "$(val "$f" real_repo)" = "$F" ]; then
  ok "fenced: REPO_ROOT is inside the sandbox; TEST_REAL_REPO still names the real tree"
else bad "fenced: REPO_ROOT / TEST_REAL_REPO are not as documented" "repo_root=$(val "$f" repo_root) real_repo=$(val "$f" real_repo)"; fi
if [ "$(val "$f" has_scripts)" = yes ] && [ "$(val "$f" has_docs)" = yes ]; then ok "fenced: scripts/ and docs/ resolve through the sandbox root"
else bad "fenced: the sandbox root does not expose the repo's read-only trees" "scripts=$(val "$f" has_scripts) docs=$(val "$f" has_docs)"; fi
if [ "$(val "$f" has_bundle)" = no ] && [ "$(val "$f" has_git)" = no ] && [ "$(val "$f" secrets)" = 0 ]; then
  ok "fenced: bundle/ and .git are NOT carried, and secrets/ is empty"
else bad "fenced: the sandbox root carries something it must not" "bundle=$(val "$f" has_bundle) git=$(val "$f" has_git) secrets=$(val "$f" secrets)"; fi
want_pins="skip_dotenv=1 lab=/nonexistent-lab sup=/nonexistent kubeconfig=UNSET argocd_kc=UNSET"
got_pins="skip_dotenv=$(val "$f" skip_dotenv) lab=$(val "$f" lab) sup=$(val "$f" sup) kubeconfig=$(val "$f" kubeconfig) argocd_kc=$(val "$f" argocd_kc)"
if [ "$got_pins" = "$want_pins" ]; then ok "fenced: $want_pins"
else bad "fenced: the scalar pins differ" "got: $got_pins"; fi
if has "$(val "$f" home)" "$sb/" && has "$(val "$f" tmpdir)" "$sb/" && has "$(val "$f" mktemp)" "$sb/" \
   && [ "$(val "$f" real_home)" = "$T/home" ]; then
  ok "fenced: HOME and TMPDIR (so mktemp) are inside the sandbox"
else bad "fenced: HOME / TMPDIR escaped the sandbox" "home=$(val "$f" home) tmpdir=$(val "$f" tmpdir)"; fi
# The caller EXPORTED VKS_STATE_FILE at the real overlay (see probe()). Fenced, it is unset, so the
# overlay is <the sandbox root>/.env.state -- and follows a root the test builds for itself.
if [ "$(val "$f" state_var)" = UNSET ] && [ "$(val "$f" state_file)" = "$(val "$f" repo_root)/.env.state" ]; then
  ok "fenced: an ambient VKS_STATE_FILE is dropped; the overlay is <REPO_ROOT>/.env.state, absent in the sandbox root"
else bad "fenced: the state overlay is not <REPO_ROOT>/.env.state" "var=$(val "$f" state_var) file=$(val "$f" state_file) root=$(val "$f" repo_root)"; fi
if [ "$(val "$f" path1)" = "$F/scripts/test-guard/bin" ]; then ok "fenced: the guard directory is first on PATH"
else bad "fenced: PATH does not start with the guard" "$(val "$f" path1)"; fi
if [ -n "$sb" ] && [ ! -e "$sb" ]; then ok "the sandbox is REMOVED when the test exits"
else bad "the sandbox outlived the test" "$sb"; fi
# the canaries are intact: the fence closed the READ, it did not delete the thing read
if [ "$(cat "$F/secrets/supervisor.kubeconfig")" = canary-repo-secrets ] && [ -f "$F/.env.state" ]; then ok "the real tree's own files are untouched"
else bad "the fenced probe changed the real tree"; fi

# keep mode leaves REPO_ROOT alone and still sets every other pin
k="$(probe 1 TEST_SANDBOX_REPO_ROOT=keep)"
if [ "$(val "$k" repo_root)" = "$F" ] && [ "$(val "$k" lab)" = /nonexistent-lab ] && [ -z "$(val "$k" dotenv)" ]; then
  ok "TEST_SANDBOX_REPO_ROOT=keep: REPO_ROOT stays real, the lab slot is pinned, .env is still not read"
else bad "keep mode is not as documented" "repo_root=$(val "$k" repo_root) lab=$(val "$k" lab) dotenv=$(val "$k" dotenv)"; fi
if has "$(val "$k" sandbox_root)" "$(val "$k" sandbox)/" && [ "$(val "$k" sandbox_root_example)" = yes ] && [ "$(val "$k" sandbox_root)" != "$F" ]; then
  ok "keep mode still BUILDS the sandbox root and names it in TEST_SANDBOX_ROOT (for the one child that needs it)"
else bad "keep mode did not provide TEST_SANDBOX_ROOT" "sandbox_root=$(val "$k" sandbox_root) example=$(val "$k" sandbox_root_example)"; fi
# ...and what keep mode does NOT close is asserted, so the header cannot drift into over-claiming it
if [ "$(val "$k" resolver)" = "$F/secrets/supervisor.kubeconfig" ] && [ "$(val "$k" kind)" = from-kind ] && [ "$(val "$k" state)" = from-state ]; then
  ok "keep mode leaves resolver slot 2, the .env.state overlay and the legacy .env.kind OPEN (documented residual)"
else bad "keep mode's residual changed -- update the helper's header" "resolver=$(val "$k" resolver) kind=$(val "$k" kind) state=$(val "$k" state)"; fi

# A guard that cannot run must STOP the test, not let it run unfenced: a stand-in without its mode
# bit is not found by a PATH lookup at all, so the real tool behind it would simply answer.
chmod -x "$F/scripts/test-guard/bin/kubectl"
g="$(probe 1)"; grc=$?
chmod +x "$F/scripts/test-guard/bin/kubectl"
if [ "$grc" -ne 0 ] && has "$g" 'not executable' && ! has "$g" 'resolver='; then ok "a stand-in that lost its mode bit STOPS the test before anything runs (rc=$grc)"
else bad "a non-executable guard did not stop the fenced test" "rc=$grc out=${g:0:160}"; fi

# ---- 3. the test's own EXIT trap still runs, in every shape -------------------------------------
# t <case>  -> prints what the handler saw; the sandbox path goes to $T/sb
cat > "$F/scripts/trapcase.sh" <<'TRAPCASE'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"
printf '%s' "$TEST_SANDBOX" > "$SB_OUT"
D="$(mktemp -d)"
case "$1" in
  plain)    trap 'echo "handler rc=$?"; rm -rf "$D"' EXIT; exit 3 ;;
  errexit)  trap 'echo "handler rc=$?"' EXIT; false ;;
  exits)    trap 'rc=$?; echo "handler rc=$rc"; exit 7' EXIT; sleep 30 & exit 3 ;;
  bareexit) trap 'rm -rf "$D"; exit' EXIT; exit 3 ;;
  fn)       cleanup() { echo "cleanup ran"; rm -rf "$D"; }; trap cleanup EXIT; exit 0 ;;
  reset)    trap 'echo SHOULD-NOT-RUN' EXIT; trap - EXIT; exit 5 ;;
  subshell) ( trap 'echo "sub handler"' EXIT; exit 0 ); [ -d "$TEST_SANDBOX" ] && echo "sandbox alive after subshell"; exit 0 ;;
  multi)    trap 'echo "multi handler"' EXIT INT TERM; trap -p TERM | grep -c 'multi handler'; exit 0 ;;
  twice)    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"; [ "$(cat "$SB_OUT")" = "$TEST_SANDBOX" ] && echo "same sandbox"; exit 0 ;;
esac
TRAPCASE
tc() {  # tc <case> <want rc> <want output, flattened> <label>
  local out rc sbx
  out="$(SB_OUT="$T/sb" HOME="$T/home" bash "$F/scripts/trapcase.sh" "$1" 2>&1 | tr '\n' '|')"; rc="${PIPESTATUS[0]}"
  sbx="$(cat "$T/sb" 2>/dev/null)"
  if [ "$rc" = "$2" ] && [ "$out" = "$3" ] && [ -n "$sbx" ] && [ ! -e "$sbx" ]; then ok "trap: $4"
  else bad "trap: $4" "rc=$rc (want $2) out=[$out] (want [$3]) sandbox-left=$([ -e "$sbx" ] && echo YES || echo no)"; fi
}
tc plain    3 'handler rc=3|'                    "the test's handler runs, sees the test's \$?, and the exit status is kept"
tc errexit  1 'handler rc=1|'                    "under set -e, a failing command still reaches the handler with rc=1"
tc exits    7 'handler rc=3|'                    "a handler that calls exit keeps ITS status -- and the sandbox is still removed"
tc bareexit 3 ''                                 "a handler ending in a BARE exit keeps the TEST's status (a failing test must not turn green)"
tc fn       0 'cleanup ran|'                     "a function handler (trap cleanup EXIT) runs"
tc reset    5 ''                                 "trap - EXIT removes the test's handler, not the sandbox clean-up"
tc subshell 0 'sub handler|sandbox alive after subshell|' "a SUBSHELL's EXIT trap runs there and does not remove the sandbox"
tc multi    0 '1|multi handler|'                 "trap H EXIT INT TERM: H is set for INT/TERM as asked, and runs at exit"
tc twice    0 'same sandbox|'                    "sourcing the helper twice keeps ONE sandbox"

# ---- 4. a killed test leaves nothing running ----------------------------------------------------
# The shape that hurts: the test stubs kubectl in a mktemp dir, starts a child that keeps calling
# kubectl, and is KILLED. bash runs the test's EXIT trap (MEASURED: on TERM and HUP), which deletes
# the stub dir -- and the child, still alive, resolves its next `kubectl` from what is left on PATH.
# Here "what is left" is a fake that records the call. CONTROL first: without the helper it does.
#
# ⚠️ THE CHILD LOOKS kubectl UP IN A NEW PROCESS (`bash -c`), AND THAT IS THE REALISTIC SHAPE.
# MEASURED: a loop calling a bare `kubectl` in ONE bash keeps its hashed path and fails with "No
# such file" once the stub is gone -- it never falls through. What falls through is every FRESH
# lookup: a script the child starts, `timeout 5 kubectl ...`, `env kubectl`, `$(command -v ...)`.
# The scripts under test are full of those, so that is what this models.
mkdir -p "$T/realbin"
# shellcheck disable=SC2016  # $* and $REACHED belong to the fake, at ITS run time
printf '#!/bin/sh\necho "REAL kubectl $*" >> "$REACHED"\n' > "$T/realbin/kubectl"; chmod +x "$T/realbin/kubectl"
cat > "$F/scripts/orphan.sh" <<'ORPHAN'
#!/usr/bin/env bash
set -uo pipefail
if [ "${PROBE_FENCED:-0}" = 1 ]; then . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/test-sandbox.sh"; fi
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$D/kubectl"; chmod +x "$D/kubectl"
PATH="$D:$PATH"
( while :; do bash -c 'kubectl get ns'; sleep 0.2; done ) &
echo "$!" > "$CHILD_OUT"
: > "$READY"
sleep 30
ORPHAN
orphan() {  # orphan <fenced 0|1>  -> "reached=<n> alive=<yes|no>"
  local fenced="$1" tp child n alive
  : > "$T/reached"; rm -f "$T/ready" "$T/child"
  PROBE_FENCED="$fenced" REACHED="$T/reached" CHILD_OUT="$T/child" READY="$T/ready" HOME="$T/home" \
    TEST_GUARD_LOG="$T/guard.log" PATH="$T/realbin:$PATH" bash "$F/scripts/orphan.sh" >/dev/null 2>&1 &
  tp=$!
  for _ in $(seq 1 50); do [ -e "$T/ready" ] && break; sleep 0.1; done
  child="$(cat "$T/child" 2>/dev/null)"
  kill -TERM "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
  sleep 1
  n="$(wc -l < "$T/reached" | tr -d ' ')"
  if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then alive=yes; kill -KILL "$child" 2>/dev/null; else alive=no; fi
  printf 'reached=%s alive=%s' "$n" "$alive"
}
: > "$T/guard.log"
r0="$(orphan 0)"
if [ "${r0#reached=0 }" = "$r0" ] && has "$r0" "alive=yes"; then ok "control: WITHOUT the helper, the killed test's child outlives it and reaches the next kubectl on PATH ($r0)"
else bad "control: the orphan did not reproduce, so the next assertion discriminates nothing" "$r0"; fi
r1="$(orphan 1)"
if [ "$r1" = "reached=0 alive=no" ]; then ok "WITH the helper, the killed test's child is killed before the stub dir goes ($r1)"
else bad "with the helper, a child still outlived the killed test" "$r1"; fi
if [ ! -s "$T/guard.log" ]; then ok "  ...and nothing fell through to the guard either"
else bad "the guard was reached after the kill" "$(head -2 "$T/guard.log")"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
