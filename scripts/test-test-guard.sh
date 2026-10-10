#!/usr/bin/env bash
# ci-tier: fast — offline; fake "real" tools under mktemp. Dials nothing, not even loopback.
# ============================================================================
# The guard directory (scripts/test-guard/) must REFUSE what it claims to refuse, LET THROUGH what
# the suite legitimately needs, and be FIRST on PATH for every test the runner starts.
#
# WHY (B751). The guard is the run-time half of the test fence: the stand-ins under
# scripts/test-guard/bin are what a unit test gets when it reaches for kubectl, helm, a container
# engine, ssh or sudo without stubbing it. A stand-in that silently execs the real tool, or a
# runner that stops putting the directory on PATH, is a fence that reads as present and is not.
#
# THE "REAL" TOOL HERE IS A FAKE that prints `REAL <tool> <argv>`. So "let through" is observable
# without running anything real, and a refusal is distinguishable from a real tool's own failure:
# the guard's rc is 97.
# ============================================================================
set -uo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPTS/test-guard/bin"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

TOOLS="kubectl helm argocd vcf crane kind docker podman ssh sudo curl"
mkdir -p "$T/real" "$T/dir"
for t in $TOOLS; do
  # shellcheck disable=SC2016  # $* belongs to the fake, at ITS run time
  printf '#!/bin/sh\necho "REAL %s $*"\n' "$t" > "$T/real/$t"; chmod +x "$T/real/$t"
done
LOG="$T/guard.log"

# run <expect: refuse|real|rc=N> <label> <tool> [argv...]   (env for the call: G_ENV, an array)
G_ENV=()
run() {
  local expect="$1" label="$2"; shift 2
  local out rc want
  out="$(env -u TEST_GUARD_ALLOW -u TEST_GUARD_CURL_HOSTS -u TEST_GUARD_QUIET ${G_ENV[@]+"${G_ENV[@]}"} \
           TEST_GUARD_LOG="$LOG" TEST_GUARD_TEST=self \
           PATH="$GUARD:$T/real:/usr/bin:/bin" "$@" 2>&1)"; rc=$?
  case "$expect" in
    refuse) # rc 97 -- except kubectl, which fails the way kubectl does with no cluster (rc 1)
            want=97; [ "$1" != kubectl ] || want=1
            if [ "$rc" -eq "$want" ] && [ "${out#REAL }" = "$out" ] && has "$out" 'test-guard: REFUSED'; then ok "REFUSED  $label"
            else bad "NOT refused: $label" "rc=$rc (want $want) out=${out:0:120}"; fi ;;
    real)   if [ "$rc" -eq 0 ] && [ "${out#REAL }" != "$out" ]; then ok "allowed  $label"
            else bad "not let through: $label" "rc=$rc out=${out:0:120}"; fi ;;
    rc=*)   if [ "$rc" -eq "${expect#rc=}" ] && [ "${out#REAL }" = "$out" ]; then ok "rc=${expect#rc=}    $label"
            else bad "wrong rc for: $label" "want ${expect#rc=}, rc=$rc out=${out:0:120}"; fi ;;
  esac
}

# ---- 0. the directory is complete and executable ----------------------------------------------
missing=""
for t in $TOOLS; do [ -x "$GUARD/$t" ] || missing="$missing $t"; done
[ -x "$SCRIPTS/test-guard/refuse.sh" ] || missing="$missing refuse.sh"
if [ -z "$missing" ]; then ok "every stand-in exists and is executable ($(printf '%s' "$TOOLS" | wc -w) tools)"
else bad "stand-in(s) missing or not executable:$missing" "git lost the mode bit, or a tool was dropped from scripts/test-guard/bin"; fi

# ---- 1. the outright refusals -----------------------------------------------------------------
: > "$LOG"
run refuse "kubectl get ns"                         kubectl get ns
run refuse "kubectl delete (a mutation)"            kubectl -n lab delete cluster gc1
run refuse "kubectl version WITHOUT --client"       kubectl --request-timeout=3s version -o json
run refuse "kubectl config use-context (writes)"    kubectl config use-context x
run refuse "kubectl -n config get view (a namespace NAMED config)" kubectl -n config get view
run refuse "kubectl kustomize <remote base>"        kubectl kustomize https://example.invalid/base
run refuse "helm version"                           helm version
run refuse "helm upgrade --install"                 helm upgrade --install x y
run refuse "argocd app sync"                        argocd app sync demo
run refuse "argocd version (server side)"           argocd version
run refuse "vcf plugin list"                        vcf plugin list
run refuse "crane push"                             crane push a.tar reg.invalid/x:1
run refuse "kind delete cluster"                    kind delete cluster --name x
run refuse "docker ps"                              docker ps
run refuse "podman run"                             podman run --rm x
run refuse "ssh"                                    ssh root@192.0.2.9 true
run refuse "sudo anything but the probe"            sudo systemctl restart libvirtd
n_logged="$(wc -l < "$LOG" | tr -d ' ')"
if [ "$n_logged" -eq 17 ]; then ok "every refusal wrote one line to TEST_GUARD_LOG (17)"
else bad "TEST_GUARD_LOG holds $n_logged line(s), want 17" "$(head -3 "$LOG")"; fi
if grep -q "^self	kubectl	-n lab delete cluster gc1$" "$LOG"; then ok "a log line is <test> TAB <tool> TAB <argv>"
else bad "the log line format changed" "$(sed -n 2p "$LOG")"; fi

# ---- 2. the closed list of local-only invocations -----------------------------------------------
run real "kubectl --kubeconfig F config view --minify"  kubectl --kubeconfig "$T/kc" config view --minify -o 'jsonpath={.clusters[0].cluster.server}'
run real "kubectl config view --raw"                    kubectl config view --raw
run real "kubectl config current-context"               kubectl --kubeconfig "$T/kc" config current-context
run real "kubectl version --client"                     kubectl version --client -o json
run real "kubectl kustomize <local dir>"                kubectl kustomize "$T/dir"
run real "argocd version --client"                      argocd version --client --short
: > "$LOG"
run rc=1 "sudo -n true answers 'a password is required' (lib/os.sh's source-time probe)" sudo -n true
if [ ! -s "$LOG" ]; then ok "the sudo probe is NOT logged (it would bury every real hit)"
else bad "the sudo probe was logged" "$(cat "$LOG")"; fi

# ---- 3. curl: by DESTINATION ------------------------------------------------------------------
printf 'url = "https://harbor.example.invalid/api/v2.0/users"\nuser = "a:b"\n' > "$T/k-foreign"
printf 'url = "http://127.0.0.1:8080/api"\nuser = "a:b"\n'                     > "$T/k-loop"
run real   "curl --version"                                 curl --version
run real   "curl --help all"                                curl --help all
run real   "curl 127.0.0.1"                                 curl -fsSL http://127.0.0.1:8080/x
run real   "curl localhost, glued short options"            curl -sS -m5 -o/dev/null -w '%{http_code}' https://localhost:8443/
run real   "curl [::1]"                                     curl 'http://[::1]:80/'
run real   "curl with credentials in the URL, loopback"     curl http://u:p@127.0.0.1:5000/v2/
run real   "curl --resolve name -> 127.0.0.1"               curl --resolve harbor.test:8443:127.0.0.1 --cacert /x https://harbor.test:8443/v2/
run real   "curl --connect-to ::127.0.0.1:9000"             curl --connect-to ::127.0.0.1:9000 https://harbor.test/
run real   "curl --connect-to name:443:127.0.0.1:9000"      curl --connect-to harbor.test:443:127.0.0.1:9000 https://harbor.test/
run real   "curl -K <config naming loopback>"               curl -sS -K "$T/k-loop"
run real   "curl --unix-socket"                             curl --unix-socket "$T/sock" http://x/
run real   "curl file://"                                   curl -fsSL -o "$T/out" "file://$T/k-loop"
run real   "curl -H/-u/-X/-d values are not read as URLs"   curl -H 'Host: evil.example' -u a:b -X POST -d '{"a":1}' http://127.0.0.1:1/
run refuse "curl a public name"                             curl https://harbor.example.invalid/
run refuse "curl a bare RFC1918 address"                    curl -sS 10.1.2.3
run refuse "curl -sSkm 3 https://vc.invalid/api"            curl -sSkm 3 https://vc.invalid/api
run refuse "curl --resolve name -> a foreign address"       curl --resolve harbor.test:8443:192.0.2.7 https://harbor.test:8443/v2/
run refuse "curl --resolve for ANOTHER name"                curl --resolve other.test:8443:127.0.0.1 https://harbor.test:8443/v2/
run refuse "curl --connect-to for ANOTHER name"             curl --connect-to a.test:443:127.0.0.1:9000 https://harbor.test/
run refuse "curl -K <config naming a foreign host>"         curl -K "$T/k-foreign"
run refuse "curl -K - (config on stdin cannot be read)"     curl -K -
run refuse "curl -x <foreign proxy> to loopback"            curl -x http://proxy.example.invalid:3128 http://127.0.0.1/
run refuse "curl 127.0.0.1.evil (a NAME that starts like loopback)" curl http://127.0.0.1.evil.example/
run refuse "curl user@evil@127.0.0.1.x"                     curl http://user@evil.example@127.0.0.1.x/
run refuse "curl two URLs, the second foreign"              curl http://127.0.0.1/ https://harbor.example.invalid/
run refuse "curl an option the guard does not know + value (fail CLOSED)" curl --some-future-option value http://127.0.0.1/

# ---- 4. the opt-ins ---------------------------------------------------------------------------
G_ENV=(TEST_GUARD_ALLOW="docker kind")
run real   "TEST_GUARD_ALLOW='docker kind' lets docker through"   docker ps
run real   "                         ...and kind"                 kind get clusters
run refuse "                         ...and NOT podman"           podman ps
G_ENV=(TEST_GUARD_ALLOW="dockerx")
run refuse "TEST_GUARD_ALLOW matches whole names (dockerx is not docker)" docker ps
G_ENV=(TEST_GUARD_CURL_HOSTS="192.0.2.1 vc.invalid")
run real   "TEST_GUARD_CURL_HOSTS lets exactly the named host through"  curl -sS https://192.0.2.1/api/session
run refuse "                      ...and not its neighbour"             curl -sS https://192.0.2.2/api/session
G_ENV=(TEST_GUARD_ALLOW="curl")
run real   "TEST_GUARD_ALLOW=curl lets every destination through"       curl https://harbor.example.invalid/
G_ENV=(TEST_GUARD_QUIET="kubectl curl")
: > "$LOG"
run refuse "TEST_GUARD_QUIET=kubectl: STILL refused"                    kubectl get ns
run refuse "TEST_GUARD_QUIET=curl: STILL refused"                       curl https://harbor.example.invalid/
run refuse "                 ...a tool NOT declared is refused AND logged" helm version
if [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ] && grep -q "^self	helm	version$" "$LOG"; then ok "a DECLARED refusal is not logged; the undeclared one is (1 line: helm)"
else bad "TEST_GUARD_QUIET did not keep exactly the declared tools out of the log" "$(tr '\n' '|' < "$LOG")"; fi
G_ENV=()

# kubectl's refusal carries kubectl's own no-cluster line, which the scripts under test classify
out="$(TEST_GUARD_LOG="$LOG" PATH="$GUARD:$T/real:/usr/bin:/bin" kubectl get ns 2>&1)"
if has "$out" 'The connection to the server localhost:8080 was refused'; then ok "kubectl's refusal ends with kubectl's own 'connection ... was refused' line"
else bad "kubectl's refusal no longer reads as an unreachable cluster" "$out"; fi

# TWO guard directories on PATH (a test running from a COPY of the repo): no exec ping-pong
cp -r "$SCRIPTS/test-guard" "$T/guard-copy"
out="$(PATH="$T/guard-copy/bin:$GUARD:$T/real:/usr/bin:/bin" timeout 10 curl -sS http://127.0.0.1:1/x 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "${out#REAL curl}" != "$out" ]; then ok "two guard dirs on PATH: the stand-in skips BOTH and reaches the real tool (no loop)"
else bad "two guard dirs on PATH did not resolve to the real tool" "rc=$rc (124 = they exec each other for ever) out=${out:0:100}"; fi
out="$(PATH="$T/guard-copy/bin:$GUARD:$T/real:/usr/bin:/bin" timeout 10 kubectl config view 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "${out#REAL kubectl}" != "$out" ]; then ok "  ...and so does an allowed kubectl call"
else bad "two guard dirs: an allowed kubectl call did not reach the real tool" "rc=$rc out=${out:0:100}"; fi
if [ -f "$GUARD/.test-guard" ]; then ok "the marker file the stand-ins key on exists (bin/.test-guard)"
else bad "scripts/test-guard/bin/.test-guard is missing" "without it a stand-in cannot tell a guard dir from a real one and execs ITSELF"; fi

# an allowed tool that is not installed must say so, not loop back into the stand-in
mkdir -p "$T/min"
for b in bash dirname; do ln -s "$(command -v "$b")" "$T/min/$b"; done     # all the stand-in itself needs
out="$(env TEST_GUARD_ALLOW=helm PATH="$GUARD:$T/min" "$GUARD/helm" version 2>&1)"; rc=$?
if [ "$rc" -eq 127 ] && printf '%s' "$out" | grep -q 'not installed'; then ok "an ALLOWED tool that is absent -> rc 127 and says so (no self-exec loop)"
else bad "allowed-but-absent tool: rc=$rc" "$out"; fi

# ---- 5. a test's own stub still wins ----------------------------------------------------------
mkdir -p "$T/stub"; printf '#!/bin/sh\necho "STUB kubectl"\n' > "$T/stub/kubectl"; chmod +x "$T/stub/kubectl"
out="$(PATH="$T/stub:$GUARD:$T/real:/usr/bin:/bin" kubectl get ns 2>&1)"
if [ "$out" = "STUB kubectl" ]; then ok "a stub dir IN FRONT of the guard is what runs"
else bad "the test's own stub did not win" "$out"; fi

# ---- 6. the runner puts the guard first, and it SURVIVES the test's own clean-up ----------------
# The probe test deletes its own mktemp stub dir on exit (as 63 tests do) and prints what
# `kubectl` resolves to before and after that. Before: its stub. After: the guard -- not the
# "real" one further down PATH.
cat > "$T/test-probe.sh" <<'PROBE'
#!/usr/bin/env bash
d="$(mktemp -d)"; printf '#!/bin/sh\necho stub\n' > "$d/kubectl"; chmod +x "$d/kubectl"
PATH="$d:$PATH"
printf 'first=%s\n' "$(printf '%s' "$PATH" | cut -d: -f2)"
printf 'with-stub=%s\n' "$(kubectl get ns 2>&1)"
rm -rf "$d"; hash -r
printf 'after-rm=%s\n' "$(kubectl get ns 2>&1 | head -1)"
printf 'guard-test=%s\n' "${TEST_GUARD_TEST:-}"
printf 'optins=[%s|%s|%s]\n' "${TEST_GUARD_ALLOW:-}" "${TEST_GUARD_CURL_HOSTS:-}" "${TEST_GUARD_QUIET:-}"
exit 1
PROBE
# rc=1 on purpose: run-test-set.sh prints a test's output only when it FAILS.
# TEST_GUARD_LOG is pointed at THIS test's own file: the probe's refusals are the experiment, and
# they must not land in a log the caller is keeping for the suite.
out="$(TEST_GUARD_ALLOW='kubectl curl' TEST_GUARD_CURL_HOSTS=elsewhere.invalid TEST_GUARD_QUIET=kubectl TEST_GUARD_LOG="$LOG" PATH="$T/real:/usr/bin:/bin" bash "$SCRIPTS/run-test-set.sh" probe "$T/test-probe.sh" 2>&1)"
if printf '%s' "$out" | grep -qF 'optins=[||]'; then ok "the runner does not pass the caller's TEST_GUARD_ALLOW / _CURL_HOSTS / _QUIET on to a test"
else bad "an opt-in inherited from the caller's shell reached the test: the guard is open for the whole set" "$(printf '%s' "$out" | grep 'optins=')"; fi
if printf '%s' "$out" | grep -qF "first=$GUARD"; then ok "run-test-set.sh puts scripts/test-guard/bin FIRST on the test's PATH"
else bad "the runner did not put the guard first on PATH" "$(printf '%s' "$out" | grep -E 'first=' | head -1)"; fi
if printf '%s' "$out" | grep -q 'with-stub=stub' && printf '%s' "$out" | grep -q 'after-rm=.*test-guard: REFUSED'; then
  ok "after the test deletes its stub dir, kubectl resolves to the GUARD, not the next real one"
else
  bad "the guard was not what a deleted stub fell through to" "$(printf '%s' "$out" | grep -E 'with-stub|after-rm' | tr '\n' ' ')"
fi
if printf '%s' "$out" | grep -q 'guard-test=test-probe.sh'; then ok "the runner names the running test in TEST_GUARD_TEST"
else bad "TEST_GUARD_TEST is not the test's name" "$(printf '%s' "$out" | grep 'guard-test=')"; fi

# ---- 7. a runner with NO guard refuses to run the set -------------------------------------------
mkdir -p "$T/noguard"; cp "$SCRIPTS/run-test-set.sh" "$T/noguard/"
printf '#!/usr/bin/env bash\necho RAN-UNFENCED\n' > "$T/noguard/test-x.sh"
out="$(bash "$T/noguard/run-test-set.sh" probe "$T/noguard/test-x.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && has "$out" 'test guard is missing' && ! has "$out" 'ok    test-x.sh'; then ok "run-test-set.sh REFUSES a set when scripts/test-guard is missing (rc=$rc)"
else bad "the runner ran a set with no guard" "rc=$rc out=${out:0:160}"; fi
mkdir -p "$T/noguard/test-guard"; cp -r "$SCRIPTS/test-guard/." "$T/noguard/test-guard/"; chmod -x "$T/noguard/test-guard/bin/kubectl"
out="$(bash "$T/noguard/run-test-set.sh" probe "$T/noguard/test-x.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && has "$out" 'not executable'; then ok "  ...and when a stand-in has lost its mode bit"
else bad "the runner ran a set with a non-executable stand-in" "rc=$rc out=${out:0:160}"; fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
