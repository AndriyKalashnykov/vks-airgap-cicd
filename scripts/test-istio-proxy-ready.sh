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
  printf '%s' "${3:-True}" > "$STUB/prog";  printf '%s' "${4:-10.0.0.9}" > "$STUB/addr"
  cat > "$STUB/bin/kubectl" <<'K'
#!/usr/bin/env bash
case "$*" in
  *'get pods'*jsonpath*) rc=$(cat "$STUBDIR/pods.rc")
     [ "$rc" -ne 0 ] && { echo 'Error from server (Forbidden): pods is forbidden' >&2; exit "$rc"; }
     cat "$STUBDIR/pods.out"; exit 0 ;;
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
      set +u
      . '$ROOT/scripts/lib/os.sh' >/dev/null 2>&1
      . '$ROOT/scripts/lib/istio.sh' >/dev/null 2>&1
      ISTIO_GWAPI_NAMESPACE=vks-ingress ISTIO_GATEWAY_NAME=vks-uis
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

stub '' 1 True 10.0.0.9
r="$(call istio_wait_gwapi_address)"
if [ "${r%%|*}" = 0 ] && [ "${r#*|}" = 10.0.0.9 ]; then
  ok "UNKNOWN readiness -> returns the address (never false-block a tenant) "
else
  bad "unknown degrades open" "got '$r' — a tenant who cannot read the namespace must not be blocked"
fi
if grep -q 'UNKNOWN' "$STUB/err"; then ok "...loudly"; else bad "unknown is loud" "no UNKNOWN on stderr"; fi

printf '\n  %d passed, %d FAILED\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
