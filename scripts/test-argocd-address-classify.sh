#!/usr/bin/env bash
# ci-tier: slow
# Offline RED/GREEN for 09-argocd-address.sh's wait classifier (B210).
#
# THE BUG: it merged kubectl's stderr into the VALUE (`2>&1`), which lib/os.sh's classify_kube_failure
# header forbids in as many words ("NEVER MERGE THE STREAMS"). Point $KUBECONFIG at a GUEST cluster --
# which is what it is from scenario-1 Step 6 onward -- and `-n <ns>` does not exist, so kubectl exits
# non-zero, _state says `absent`, and the script waits ARGOCD_ADDRESS_WAIT_SECONDS (default 900) while
# printing "the ArgoCD instance is still reconciling": a positive claim about a cluster it is not
# pointed at.
#
# THE CASE THAT MATTERS MOST IS THE ONE THAT MUST STILL WAIT. This is a classifier, not a gate: a real
# fresh Supervisor whose Service has not reconciled yet MUST keep waiting, or the fix is a false-block
# and is refuted on sight. Both directions are asserted below.
#
# Fakes kubectl on PATH; touches no cluster.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf 'apiVersion: v1\n' > "$T/sup.kubeconfig"
: > "$T/.env.example"

mk_kubectl() {   # $1 = stderr text, $2 = rc, $3 = stdout
  { printf '#!/usr/bin/env bash\n'
    printf 'printf %%s %s >&2\n' "$(printf '%q' "$1")"
    printf 'printf %%s %s\n'     "$(printf '%q' "${3:-}")"
    printf 'exit %s\n' "$2"
  } > "$T/bin/kubectl"; chmod +x "$T/bin/kubectl"
}

run() {  # elapsed:rc:output
  local s e rc out
  s=$(date +%s)
  # REPO_ROOT is pinned to the throwaway dir: without it, case 4 reaches set_env_var and writes
  # ARGOCD_SERVER=<fixture-ip> into the OPERATOR'S REAL .env. That is not hypothetical -- it happened
  # (live .env line 1029, removed 2026-08-22). Because 09 is deliberately non-destructive, a later
  # REAL discovery would then REFUSE to overwrite the fake and argocd login would dial 10.20.30.40.
  # $T/.env.example must exist so lib/os.sh does not fall back to `git rev-parse` for the root.
  out="$(PATH="$T/bin:$PATH" VKS_SUPERVISOR_KUBECONFIG="$T/sup.kubeconfig" REPO_ROOT="$T" \
         ARGOCD_NAMESPACE=cicd ARGOCD_ADDRESS_WAIT_SECONDS="${WAITS:-30}" SKIP_DOTENV=1 \
         bash "$SCRIPT_DIR/09-argocd-address.sh" 2>&1)" ; rc=$?
  e=$(date +%s)
  printf '%s:%s:%s' "$((e-s))" "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

p=0; f=0
ck(){ if [ "$2" = "$3" ]; then p=$((p+1)); printf '  ok    %s\n' "$1"; else f=$((f+1)); printf '  FAIL  %s (got=%s want=%s)\n' "$1" "$2" "$3"; fi; }

# RED 1 — a GUEST kubeconfig: namespace absent. Must NOT wait, must name the guest.
mk_kubectl 'Error from server (NotFound): namespaces "cicd" not found' 1 ''
r="$(run)"; el=${r%%:*}; rest=${r#*:}; rc=${rest%%:*}; out=${rest#*:}
ck "missing namespace -> non-zero"        "$rc" "1"
ck "missing namespace -> did NOT wait"    "$([ "$el" -lt 12 ] && echo fast || echo "waited_${el}s")" "fast"
ck "missing namespace -> names GUEST"     "$(printf '%s' "$out" | grep -c 'GUEST')" "1"
ck "missing namespace -> no false 'reconciling' claim" \
   "$(printf '%s' "$out" | grep -c 'still reconciling')" "0"

# RED 2 — a stale CA. Waiting cannot fix it either.
mk_kubectl 'Unable to connect to the server: x509: certificate signed by unknown authority' 1 ''
r="$(run)"; el=${r%%:*}; rest=${r#*:}; rc=${rest%%:*}
ck "stale CA -> non-zero"                 "$rc" "1"
ck "stale CA -> did NOT wait"             "$([ "$el" -lt 12 ] && echo fast || echo "waited_${el}s")" "fast"

# GREEN (the no-false-block control) — namespace EXISTS, Service not yet created. MUST still wait.
mk_kubectl 'Error from server (NotFound): services "argocd-server" not found' 1 ''
WAITS=16 r="$(run)"; el=${r%%:*}
ck "reconciling Supervisor -> STILL WAITS" "$([ "$el" -ge 14 ] && echo waited || echo "fast_${el}s")" "waited"

# GREEN — an address is returned and printed.
mk_kubectl '' 0 '10.20.30.40'
r="$(run)"; rest=${r#*:}; rc=${rest%%:*}; out=${rest#*:}
ck "address -> rc 0"                      "$rc" "0"
ck "address -> printed"                   "$(printf '%s' "$out" | grep -c '10.20.30.40')" "1"

# THE NO-FALSE-BLOCK CONTROLS. The suite was 9/9 green on the shipped version AND on both fixes for
# it, i.e. it could not see the two HIGH defects an implementation round found. These two cases are
# the ones that discriminate; without them this gate measures nothing about the arms that broke.
mk_kubectl 'Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout' 1 ''
WAITS=16 r="$(run)"; el=${r%%:*}
ck "transient i/o timeout -> STILL WAITS" "$([ "$el" -ge 14 ] && echo waited || echo "fast_${el}s")" "waited"

# rc=0 with retry NOISE on stderr is the NORMAL pending state -- it must never be classified.
# ⚠️ THE STDERR TEXT MUST CLASSIFY, or this case is VACUOUS. A first draft used a generic
# "transient warning", which classify_kube_failure maps to UNKNOWN -- so it waited with OR without
# the fix and could not fail on the defect. Measured: 1 of 2 new cases fired on the revert. The noise
# must be text that WOULD classify (here UNREACHABLE) while the probe itself SUCCEEDS (rc=0).
# ⚠️ AND IT MUST CLASSIFY INTO A STATE THAT IS STILL IN THE DON'T-WAIT SET. A second draft used an
# i/o timeout -- but the fix above REMOVED UNREACHABLE from that set, so it waits either way and the
# case was vacuous a second time. x509 -> STALE_CA, which IS still don't-wait, so without the errfile
# truncation this rc=0 probe is wrongly classified and exits 0s. The two fixes INTERACT: a fixture
# for one must be chosen against the other.
mk_kubectl 'W0822 client retrying: x509: certificate signed by unknown authority' 0 ''
WAITS=16 r="$(run)"; el=${r%%:*}
ck "rc=0 with stderr noise -> STILL WAITS" "$([ "$el" -ge 14 ] && echo waited || echo "fast_${el}s")" "waited"


# ══ THE VIP MOVED UNDERNEATH US (measured on the live 3.7 lab, certification row 1, 2026-08-26) ══
#
#   05:56:14 svc created  ->  05:56:24 this script published .131  ->  .131 answered NOTHING, ever
#   the SAME Service object (same uid, never recreated) later carried .138, which answered 200.
#
# THE RED IS THE PUBLISHED VALUE, NOT THE EXIT CODE. On the unfixed tree rc is 0 and .env holds the
# DEAD address, so asserting rc would PASS on the defect. Both stubs are STATEFUL (a counter file)
# because the whole defect is that the answer CHANGES over time; a static stub cannot express it.
# shellcheck disable=SC2016  # the single quotes are the POINT: this printf EMITS a script, so
# `$c` / `$(cat ...)` must reach the stub UNEXPANDED and be evaluated when the STUB runs. Expanding
# them here would bake in this shell's values and the stub could never change its answer -- which is
# the entire behaviour under test.
mk_moving() {
  { printf '#!/usr/bin/env bash\n'
    printf 'c="$(cat %s/kc 2>/dev/null || echo 0)"; c=$((c+1)); printf %%s "$c" > %s/kc\n' "$T" "$T"
    printf 'if [ "$c" -le 2 ]; then printf 192.168.101.131; else printf 192.168.101.138; fi\n'
    printf 'exit 0\n'
  } > "$T/bin/kubectl"; chmod +x "$T/bin/kubectl"
  { printf '#!/usr/bin/env bash\n'
    printf 'touch %s/curl-ran\n' "$T"
    printf 'case "$*" in *192.168.101.138*) printf 200 ;; *) printf 000 ;; esac\n'
    printf 'exit 0\n'
  } > "$T/bin/curl"; chmod +x "$T/bin/curl"
}

rm -f "$T/kc" "$T/curl-ran" "$T/.env"
mk_moving
WAITS=90 r="$(run)"
_env="$(cat "$T/.env" 2>/dev/null || true)"
ck "moving VIP -> publishes the address that ANSWERED" \
   "$(printf '%s' "$_env" | grep -qF 'ARGOCD_SERVER=192.168.101.138' && echo yes || echo no)" "yes"
ck "moving VIP -> the DEAD address is NOT published" \
   "$(printf '%s' "$_env" | grep -qF '192.168.101.131' && echo leaked || echo clean)" "clean"
ck "moving VIP -> says the address changed" \
   "$(printf '%s' "$r" | grep -qiF 'CHANGED underneath us' && echo said || echo silent)" "said"
ck "the curl probe actually RAN (not passing by not looking)" \
   "$([ -f "$T/curl-ran" ] && echo ran || echo never)" "ran"

# CONTROL — an L7 LB or a --rootpath install answers 403/404 unauthenticated. NOT a failure; treating
# it as one would be a brand-new false BLOCK on a perfectly good lab.
rm -f "$T/kc" "$T/.env"
printf '#!/usr/bin/env bash\nprintf 192.168.101.150\nexit 0\n' > "$T/bin/kubectl"; chmod +x "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nprintf 403\nexit 0\n' > "$T/bin/curl"; chmod +x "$T/bin/curl"
WAITS=30 r="$(run)"
ck "403 counts as ANSWERING (no false block on --rootpath / an L7 LB)" \
   "$(grep -qF 'ARGOCD_SERVER=192.168.101.150' "$T/.env" 2>/dev/null && echo published || echo blocked)" "published"
ck "403 publishes FAST (did not sit out the budget)" \
   "$([ "${r%%:*}" -lt 20 ] && echo fast || echo slow)" "fast"

# CONTROL — budget expires, nothing ever answers: WARN and PUBLISH, rc 0. A die would convert a late
# failure into an EARLY hard stop on a lab whose address is fine and only this probe is wrong.
rm -f "$T/kc" "$T/.env"
printf '#!/usr/bin/env bash\nprintf 192.168.101.160\nexit 0\n' > "$T/bin/kubectl"; chmod +x "$T/bin/kubectl"
printf '#!/usr/bin/env bash\nprintf 000\nexit 0\n' > "$T/bin/curl"; chmod +x "$T/bin/curl"
WAITS=16 r="$(run)"
ck "never answers -> still PUBLISHES (warn, not die)" \
   "$(grep -qF 'ARGOCD_SERVER=192.168.101.160' "$T/.env" 2>/dev/null && echo published || echo blocked)" "published"
ck "never answers -> rc 0" "$(printf '%s' "$r" | cut -d: -f2)" "0"

rm -f "$T/bin/curl"

printf '\n  %d passed, %d failed\n' "$p" "$f"; [ "$f" -eq 0 ]
