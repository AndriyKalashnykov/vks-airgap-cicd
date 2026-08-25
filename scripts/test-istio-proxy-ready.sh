#!/usr/bin/env bash
# istio_wait_gwapi_address must NOT report success over a data plane that is not serving (B477).
#
# MEASURED on the lab 2026-08-25: the Gateway was Programmed=True with LB IP 192.168.101.135 while
# its provisioned proxy sat in CrashLoopBackOff (it could not reach istiod's CA -- istiod's Service
# had ZERO endpoints because its kapp-injected selector matched no helm-installed pod). The function
# returned the address, install/attach exited 0, a dead IP was published to .env.state, and nothing
# was red until verify-ingress polled 8 hosts x 300s = 40 minutes later.
#
# Three states, never two: 0 = Ready, 1 = not Ready, 2 = COULD NOT ASK. "Cannot ask" is not a
# verdict; it degrades to a WARNING and still returns the address, because the alternative is
# false-blocking a tenant whose RBAC cannot read the namespace.
set -uo pipefail
export LC_ALL=C
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
pass=0; fail=0; STUB=""
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
cleanup(){ [ -n "$STUB" ] && rm -rf "$STUB"; }
trap cleanup EXIT

# stub <pods-jsonpath-output> <pods-rc> [programmed] [address]
stub() {
  cleanup; STUB="$(mktemp -d)"; mkdir -p "$STUB/bin"
  printf '%s' "${1:-}" > "$STUB/pods.out"; printf '%s' "${2:-0}" > "$STUB/pods.rc"
  printf '%s' "${5:-0}" > "$STUB/failfirst"; : > "$STUB/calls"
  printf '%s' "${6:-gateway.networking.k8s.io/gateway-name=}" > "$STUB/selector"
  printf '%s' "${3:-True}" > "$STUB/prog";  printf '%s' "${4:-10.0.0.9}" > "$STUB/addr"
  cat > "$STUB/bin/kubectl" <<'K'
#!/usr/bin/env bash
case "$*" in
  *'get pods'*jsonpath*)
     echo x >> "$STUBDIR/calls"; n=$(wc -l < "$STUBDIR/calls"); ff=$(cat "$STUBDIR/failfirst")
     # The stub HONOURS the selector. Without this it returned the same pods for ANY selector, so a
     # copy-pasted gateway-name selector on the classic path passed VACUOUSLY -- proven by mutation:
     # the case went GREEN over exactly the defect the adversary warned about. An empty set is what
     # a wrong selector really produces, and it must read as "not Ready", never as Ready.
     want="$(cat "$STUBDIR/selector")"
     case "$*" in *"$want"*) : ;; *) exit 0 ;; esac   # wrong selector -> NO pods, rc=0
     if [ "$n" -le "$ff" ]; then
       # a TRANSIENT local/api error -- NOT Forbidden. This is the realistic trigger for state 2,
       # and the old test only ever emitted Forbidden, pinning the RBAC flavour and never this one.
       echo 'Error from server: etcdserver: request timed out' >&2; exit 1
     fi
     rc=$(cat "$STUBDIR/pods.rc")
     [ "$rc" -ne 0 ] && { echo 'Error from server (Forbidden): pods is forbidden' >&2; exit "$rc"; }
     cat "$STUBDIR/pods.out"; exit 0 ;;
  # ORDER MATTERS: `-o jsonpath=` STARTS WITH `-o json`, so the plain-JSON pattern must come LAST
  # or it swallows every jsonpath query. It did, and the test caught it as a FAIL rather than a
  # silent pass -- which is the only reason this stub is trustworthy.
  *'get svc'*'{.spec.type}'*)          echo LoadBalancer; exit 0 ;;
  *'get svc'*'loadBalancer.ingress'*ip*) cat "$STUBDIR/addr"; exit 0 ;;
  *'get svc'*hostname*)                exit 0 ;;
  *'get svc'*'-o json'*)               printf '{"spec":{"selector":{"istio":"ingressgateway","app":"istio-ingressgateway"}}}'; exit 0 ;;
  *'get gateway'*Programmed*) cat "$STUBDIR/prog"; exit 0 ;;
  *'get gateway'*addresses*)  cat "$STUBDIR/addr"; exit 0 ;;
  *) exit 0 ;;
esac
K
  chmod +x "$STUB/bin/kubectl"
}

# call <fn> -> prints "rc|stdout"; stderr kept separately so a diagnostic cannot corrupt the value
call() {
  local fn="$1" out rc=0
  out="$(STUBDIR="$STUB" PATH="$STUB/bin:$PATH" bash -c "
      set -uo pipefail
      . '$ROOT/scripts/lib/os.sh' >/dev/null 2>&1
      . '$ROOT/scripts/lib/istio.sh' >/dev/null 2>&1
      ISTIO_GWAPI_NAMESPACE=vks-ingress ISTIO_GATEWAY_NAME=vks-uis
      ISTIO_GATEWAY_NAMESPACE=istio-ingress ISTIO_GATEWAY_SERVICE=istio-ingressgateway
      READY_TIMEOUT_SECONDS=2 POLL_INTERVAL_SECONDS=1
      $fn" 2>"$STUB/err")" || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- the helper's three states -------------------------------------------------------------------
stub 'vks-uis-istio-abc=True'$'\n' 0
r="$(call istio_gwapi_proxy_ready)"
if [ "${r%%|*}" = 0 ]; then ok "a Ready proxy pod -> 0"; else bad "Ready -> 0" "got rc=${r%%|*}"; fi

stub 'vks-uis-istio-abc=False'$'\n' 0
r="$(call istio_gwapi_proxy_ready)"
if [ "${r%%|*}" = 1 ]; then ok "a proxy pod that is NOT Ready -> 1 (the incident)"; else bad "not-Ready -> 1" "got rc=${r%%|*}"; fi

stub '' 0
r="$(call istio_gwapi_proxy_ready)"
if [ "${r%%|*}" = 1 ]; then ok "no proxy provisioned yet -> 1"; else bad "no pods -> 1" "got rc=${r%%|*}"; fi

stub '' 1
r="$(call istio_gwapi_proxy_ready)"
if [ "${r%%|*}" = 2 ]; then ok "cannot READ the pods -> 2 (not a verdict)"; else bad "unreadable -> 2" "got rc=${r%%|*}"; fi
if grep -q 'could not read' "$STUB/err"; then ok "...and it says so on stderr"; else bad "warns on unreadable" "stderr: $(head -1 "$STUB/err")"; fi

# An EMPTY selector must be "could not ask", never Ready. `kubectl get pods -l ""` selects EVERY pod
# in the namespace, so one unrelated healthy pod would report OUR proxy Ready -- a fail-open I
# introduced when istio_wait_lb_ip started deriving the selector from the Service. Reachable when
# the Service has no selector (legal, for manually-managed Endpoints), when jq is absent, or when
# the -o json read fails. MEASURED before the fix: rc=0 over a namespace whose only pod was not ours.
stub 'some-unrelated-pod=True'$'\n' 0
r="$(call 'istio_proxy_ready istio-ingress ""')"
if [ "${r%%|*}" = 2 ]; then
  ok "an EMPTY selector -> 2 (could not ask), never Ready on an unrelated pod"
else
  bad "empty selector is not a pass" "got rc=${r%%|*} — an empty -l selects EVERY pod in the namespace, so any healthy pod there certifies our proxy"
fi

# --- the END RESULT: what the caller returns -----------------------------------------------------
stub 'vks-uis-istio-abc=True'$'\n' 0 True 10.0.0.9
r="$(call istio_wait_gwapi_address)"
if [ "${r%%|*}" = 0 ] && [ "${r#*|}" = 10.0.0.9 ]; then ok "Programmed + Ready proxy -> returns the address"; else bad "healthy path" "got '$r'"; fi

stub 'vks-uis-istio-abc=False'$'\n' 0 True 10.0.0.9
r="$(call istio_wait_gwapi_address)"
if [ "${r%%|*}" != 0 ]; then
  ok "Programmed + address + CRASHLOOPING proxy -> FAILS (B477: it used to return 0)"
else
  bad "the B477 regression" "returned rc=0 and address '${r#*|}' over a proxy that is NOT Ready — this is exactly the bug: a dead IP gets published to .env.state and nothing is red for 40 minutes"
fi
if grep -q 'not Ready' "$STUB/err"; then ok "...and the diagnosis names the data plane"; else bad "diagnoses the proxy" "stderr had no proxy diagnosis"; fi
if grep -q 'endpoints istiod' "$STUB/err"; then ok "...and points at istiod's ENDPOINTS, not just its pod"; else bad "names the endpoints check" "stderr: $(tail -3 "$STUB/err" | tr '\n' ' ')"; fi

# UNREADABLE FOR THE WHOLE BUDGET -> the tenant concession. Asserting the address ALONE was
# VACUOUS: unfixed main returns the address unconditionally, for an entirely different reason, so
# that case could not tell fixed from unfixed. The address AND the boundary warning together can.
stub '' 1 True 10.0.0.9
r="$(call istio_wait_gwapi_address)"
if [ "${r%%|*}" = 0 ] && [ "${r#*|}" = 10.0.0.9 ] && grep -q 'UNREADABLE for the entire' "$STUB/err"; then
  ok "unreadable for the WHOLE budget -> address + a boundary warning (never false-block a tenant)"
else
  bad "unknown degrades open at the boundary" "got '$r'; stderr had $(grep -c 'UNREADABLE for the entire' "$STUB/err") boundary warning(s) — a tenant who cannot read the namespace must not be blocked, but it must not read as a pass either"
fi

# THE HIGH FROM ROUND 4: ONE transient error must NOT disable the guard. Before this fix, state 2
# RETURNED immediately, so a single etcd timeout in a 60-poll budget bypassed the whole check over a
# permanently crashlooping proxy that the very next poll would have caught.
stub 'vks-uis-istio-abc=False'$'\n' 0 True 10.0.0.9 1
r="$(call istio_wait_gwapi_address)"
if [ "${r%%|*}" != 0 ]; then
  ok "ONE transient error then a crashlooping proxy -> still FAILS (round 4 HIGH)"
else
  bad "one transient error must not bypass the guard" "returned rc=0 and '${r#*|}' — a single unreadable poll disabled the guard over the exact state it exists to catch"
fi

# --- the CLASSIC / PACKAGE path, which publishes through istio_wait_lb_ip -------------------------
# Round 4: the guard closed ONE of two branches of the same case statement. The two left open were
# 47-attach-istio.sh's CLASSIC branch and 43-install-istio-package.sh -- and the package/kapp path is
# the one whose own mechanism produced B477. A copy-paste would have been worse than nothing: the
# classic proxy carries the SERVICE's selector, not the gateway-name label, so a copied selector
# matches NOTHING and the check passes vacuously (state 1 forever, or a false Ready on an empty set).
stub 'istio-ingressgateway-xyz=True'$'\n' 0 True 10.0.0.9 0 'istio=ingressgateway'
r="$(call istio_wait_lb_ip)"
if [ "${r%%|*}" = 0 ] && [ "${r#*|}" = 10.0.0.9 ]; then
  ok "CLASSIC: LB address + a Ready proxy -> returns the address"
else
  bad "classic healthy path" "got '$r' — a healthy classic install must not be blocked (and this is what a copy-pasted gateway-name selector would break)"
fi

stub 'istio-ingressgateway-xyz=False'$'\n' 0 True 10.0.0.9 0 'istio=ingressgateway'
r="$(call istio_wait_lb_ip)"
if [ "${r%%|*}" != 0 ]; then
  ok "CLASSIC: LB address + a CRASHLOOPING proxy -> FAILS (the package path's own fail-open)"
else
  bad "classic guard" "returned rc=0 and '${r#*|}' — the classic and PACKAGE paths still publish a dead address"
fi
if grep -q 'was assigned, but the gateway proxy never became Ready' "$STUB/err"; then
  ok "...and it does NOT misdiagnose an assigned address as a stuck LoadBalancer"
else
  bad "classic diagnosis names the right cause" "it fell through to the pending-LB diagnosis, which assumes the address never arrived — the mirror image of the wrong symptom guide this PR corrects"
fi

printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
