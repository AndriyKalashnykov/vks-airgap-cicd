#!/usr/bin/env bash
# env-check must NOT require the .env FILE to exist (B478).
#
# THE DEFECT, in one sentence: the gate demanded the presence of a file that its very next line --
# `load_env` under SKIP_DOTENV=1 -- is contractually obliged to IGNORE. That made the documented
# KinD quickstart impossible on a clean clone: `make e2e-kind` -> install-all -> preflight -> here
# -> rc=2 "no .env yet", while README.md:68, docs/kind-local.md:6/:77 and Makefile:201 all promise
# "zero .env" and the last calls it an ENFORCED property.
#
# WHY THE EXISTING scripts/test-env-check.sh CANNOT SEE IT: its run_check() calls write_env()
# unconditionally on every path, so all 6 invocations fabricate a .env before running the script.
# The `[ -f "$ENV_FILE" ]` branch is never exercised in EITHER direction, and SKIP_DOTENV appears
# zero times in that file. A fixture that hard-supplies the input the product is supposed to supply
# is structurally blind to that input's absence.
#
# The corpus is `git archive HEAD` -- tracked files only, so .env CANNOT exist. That is what makes
# this honest, and it cannot rot into a passing test on a box that happens to have one.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0; T=""
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
cleanup(){ [ -n "$T" ] && rm -rf "$T"; }
trap cleanup EXIT

# --- corpus, with EVERY setup step checked -------------------------------------------------------
# An unchecked `git archive | tar` is the harness trap: a partial extract fails LATER, as the thing
# under test going red on inputs that were never copied, and the message accuses the product.
T="$(mktemp -d)" || { echo "  FAIL mktemp"; exit 1; }
if ! git -C "$ROOT" archive HEAD > "$T/a.tar" 2>/dev/null; then
  if [ -n "${CI:-}" ]; then
    printf '  FAIL  no git repo (or no HEAD) and CI is set — a SKIP here is a green that measured NOTHING\n'
    exit 1
  fi
  printf '  SKIP  not a git repo (or no HEAD) — this test needs git archive for a .env-free tree\n'; exit 0
fi
tar -xf "$T/a.tar" -C "$T" || { bad "HARNESS: tar extract" "this is the TEST's setup, not the product"; printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; }
n="$(find "$T/scripts" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"
if [ ! -s "$T/scripts/02-env.sh" ] || [ ! -s "$T/scripts/lib/os.sh" ] || [ "$n" -lt 50 ]; then
  bad "HARNESS: corpus is incomplete" "extracted $n scripts; 02-env.sh/lib/os.sh non-empty required. This is the TEST's setup — do not go looking at env-check."
  printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"; exit 1
fi
[ -f "$T/.env" ] && { bad "HARNESS: .env leaked into the corpus" "git archive emitted a .env — the whole point is that it cannot"; }

# OVERLAY THE WORKING TREE's scripts onto the archived corpus. `git archive HEAD` gives a tree that
# provably has no .env -- which is the whole point -- but it is the COMMITTED tree, so on its own
# this would test the wrong artifact: an uncommitted fix is invisible and an uncommitted REGRESSION
# is missed. The archive supplies the .env-free SHAPE; the working tree supplies the CODE.
cp -a "$ROOT/scripts/." "$T/scripts/" || { bad "HARNESS: overlay the working tree" "could not copy scripts/"; printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; }
# NOTE: no post-overlay ".env leaked" guard here. `cp -a "$ROOT/scripts/."` writes into
# $T/scripts/, so it CANNOT create $T/.env -- a guard there could never fire, and a check that
# cannot fire reads as a guarantee while providing none. The pre-overlay check above is the real
# one. (An untracked scripts/.env WOULD be copied, to $T/scripts/.env, which load_env never reads.)
ok "corpus: $n scripts from HEAD, code overlaid from the working tree, NO .env"

# `env -i`, NOT `env "$@"`: the latter ADDS variables and never clears the inherited environment,
# so an ambient KUBECONFIG or HARBOR_PASSWORD in the operator's shell flips this test. MEASURED:
# KUBECONFIG=/nonexistent -> the KinD case FALSE-REDs; HARBOR_PASSWORD=x -> the teeth case
# FALSE-GREENs. load_env snapshot-protects both by design (they outrank .env.state), so this is the
# product behaving correctly and the HARNESS lying. PATH and HOME are the only carry-overs.
run() { ( cd "$T" && env -i PATH="$PATH" HOME="$HOME" "$@" bash scripts/02-env.sh check >"$T/out" 2>&1 ); }

# 1. real-lab FIRST run: no .env, no state -> must be RED, and must name VALUES not a file
run E=1; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'required value' "$T/out"; then
  ok "no .env, no state -> RED, naming the missing VALUES"
else
  bad "clean box still fails loudly" "rc=$rc; a clean real-lab box must still be told what is missing. out: $(head -2 "$T/out" | tr '\n' ' ')"
fi
if grep -q "no .env yet — run 'make env-init' first" "$T/out"; then
  bad "no longer dies on the FILE" "it still dies naming a FILE when the reader's problem is VALUES"
else
  ok "...and does not die naming the FILE"
fi

# 2. THE DECISIVE PATH: no .env, but a complete KinD .env.state -> must be GREEN
cat > "$T/.env.state" <<'STATE'
HARBOR_USERNAME=admin
HARBOR_PASSWORD=generated-by-kind-up
GITEA_ADMIN_PASSWORD=generated-by-kind-up
HARBOR_URL=172.18.0.3
KUBECONFIG=./secrets/kind.kubeconfig
STATE
# NON-EMPTY on purpose: the KUBECONFIG check is `-s`, not `-f`. A path value that exists but is
# empty is exactly the "set but not usable" case that gate exists for, so an empty fixture file
# fails for the RIGHT reason -- which cost me a debugging round and is worth pinning here.
mkdir -p "$T/secrets" && printf 'apiVersion: v1\nkind: Config\nclusters: []\n' > "$T/secrets/kind.kubeconfig"
run SKIP_DOTENV=1; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "no .env + a complete .env.state -> GREEN (this is what 'zero .env' MEANS)"
else
  bad "the KinD path passes without a .env" "rc=$rc — this is the exact chain 'make e2e-kind' takes on a clean clone. out: $(head -3 "$T/out" | tr '\n' ' ')"
fi

# 3. TEETH: same, but a generated secret is blank -> must still be RED
sed -i 's/^HARBOR_PASSWORD=.*/HARBOR_PASSWORD=/' "$T/.env.state"
run SKIP_DOTENV=1; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'HARBOR_PASSWORD' "$T/out"; then
  ok "a BLANK generated secret is still caught (the gate keeps its teeth)"
else
  bad "blank generated secret still RED" "rc=$rc — lib/os.sh:610 records a CI run that FATAL'd on an empty HARBOR_PASSWORD while every local run was green; making this gate a no-op would disable exactly that"
fi

printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
