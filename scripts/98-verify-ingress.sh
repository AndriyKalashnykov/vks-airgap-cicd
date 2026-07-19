#!/usr/bin/env bash
# 98-verify-ingress.sh — assert the browser UIs are reachable THROUGH the ingress
# LoadBalancer at their *.vks.local hostnames, not via `kubectl port-forward`.
#
# Why this exists: `make verify` (99-verify.sh) port-forwards svc/javawebapp + svc/gitea
# directly, so a broken Ingress / Gateway / VirtualService (wrong backend, host, or
# port) still passes the whole e2e green. This script exercises the real data path:
#   client -> INGRESS_LB_IP (Host: <host>) -> controller route -> backend Service.
#
# It is controller-agnostic: whichever ingress installed last published INGRESS_LB_IP
# to .env.state, and the route assertion (curl with a Host header) is identical for
# Istio (Gateway/VirtualService) and Traefik (Ingress).
#
# K1.5 (assigned != routable): cloud-provider-kind wires the LB data path (the
# per-Service Envoy) 5-60s AFTER the LoadBalancer IP is assigned, so a curl fired
# right after IP-assignment gets `Connection reset`. The per-host readiness poll
# below IS the data-path gate — it retries transient 000/502/503/504 until the
# route is live, then asserts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

require_cmd curl
# INGRESS_LB_IP is OUR OWN PUBLISHED STATE (each installer state_sets it: 45/46/47), read back here
# via the .env.state overlay. Reading published state back as an input is the trap that bit
# 47-attach-istio.sh (INGRESS_LB_IP_OVERRIDE exists there for exactly that) — but this script is a
# PURE CONSUMER: it never state_sets INGRESS_LB_IP/INGRESS_CONTROLLER, so it cannot poison state, and
# every caller (e2e-kind, verify-ingress-both, e2e-kind-istio-existing, the lab runbook) runs
# `install-ingress` IMMEDIATELY before `verify-ingress`, freshly publishing the value for the current
# mode. So the read is never stale in any orchestrated/documented path. A stale STANDALONE read is the
# SAFE direction: a dead/reassigned IP yields a loud route FAIL below (a false-RED, self-diagnosed at
# line ~112), never a false-green — a false-green would require the "stale" IP to actually route these
# hosts to these backends serving the right body markers, i.e. it is not stale. The real-lab standalone
# case is further guarded by state_check's cluster stamp (an explicit KUBECONFIG refuses a mismatched
# overlay → INGRESS_LB_IP unset → the :? aborts loudly). So do NOT "fix" this into a re-resolve
# dispatcher: it would duplicate installer logic and depend on INGRESS_CONTROLLER, which is published
# state with the identical read-back class — no net gain. (Verification-disproved backlog item B15.)
: "${INGRESS_LB_IP:?INGRESS_LB_IP not set — run 'make install-ingress' first (it writes the LB IP to .env.state)}"
: "${GITEA_HOST:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
# Every app's host comes from the registry — a hardcoded list would silently stop checking a new app.
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
# `|| true` + an EXPLICIT count guard, deliberately in that order. Without the `|| true` this is
# protected only BY ACCIDENT: on a comments-only registry `app_names`' grep exits 1, `pipefail` fails
# the assignment, and `set -e` kills the script -- silently, with no diagnostic naming the cause. With
# the `|| true` alone the vacuity becomes REACHABLE and still silent. The guard is what makes it neither.
APP_HOSTS="$(app_names | while read -r a; do if [ -n "$a" ]; then printf '%s ' "$(app_host "$a")"; fi; done || true)"
[ "$(printf '%s' "$APP_HOSTS" | wc -w)" -gt 0 ] \
  || die "98-verify-ingress: the registry yielded ZERO app hosts. This gate would then check only the two hardcoded infra hosts and report all UIs reachable having verified no app at all."
: "${INGRESS_CONTROLLER:=istio}"
READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-10}"

# HTTP codes that prove the ingress routed to a live backend. 2xx = served;
# 3xx = a backend redirect (e.g. ArgoCD /) — both mean the route works. 5xx and
# 000 (connection reset / no response) mean the data path is NOT yet ready or the
# route is broken.
route_code() { # <host> — echo the HTTP status of GET / through the ingress LB, or 000 if NOT SERVED
  # THIS FUNCTION ANSWERS "is this host SERVING?", which is NOT the same question 97 asks (see below),
  # and that difference decides the normalisation. Two bugs were here, and the second is the dangerous
  # one -- it was found only because an adversary attacked the FIX for the first.
  #
  # (1) `curl -w '%{http_code}'` ALREADY prints 000 on a connect failure AND exits non-zero, so the
  #     idiomatic `|| echo "000"` appended a SECOND one and this returned `000000` (measured, len 6).
  #     That matched no `case` arm in wait_route, so the `000|50[234]` retry arm was DEAD CODE.
  #     Cosmetic today only because that arm and `*)` are both `: ;` -- but it is one edit away from
  #     mattering, and the failure line printed a nonsense `000000`.
  #
  # (2) NORMALISING TO THE PRINTED CODE ALONE IS A FALSE GREEN, and it is worse than the bug it fixes.
  #     `--max-time` expiring MID-RESPONSE prints the REAL code and exits 28. So a backend that sends
  #     `200` headers and then hangs yields a bare `200`, which hits wait_route's `2??|3??` arm and
  #     RETURNS 0 -- the route is declared OK. Today the doubled string falls through to `*)` and the
  #     poll eventually FAILs. Measured end-to-end against a threaded stalling server: the whole gate
  #     went GREEN, body marker and all, over a backend that never completes a response.
  #     So the transport status is load-bearing and must be preserved, not just the printed digits.
  #
  # `&& r=0 || r=$?`, NOT `; r=$?`: the latter dies under `set -e` if this is ever called bare.
  local c r
  c="$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Host: $1" --max-time "$CURL_MAX_TIME_SECONDS" \
        "http://${INGRESS_LB_IP}/" 2>/dev/null)" && r=0 || r=$?
  [ "$r" -eq 0 ] || c=000          # connect refused / timeout / truncated mid-response => NOT serving
  case "$c" in ''|*[!0-9]*) c=000 ;; esac
  printf '%s' "$c"
}

# Poll a host until its route is live (K1.5 data-path readiness), then return the code.
wait_route() { # <host> — 0 + echo code when routed; 1 on timeout
  # `code=000`, not unassigned: with READY_TIMEOUT_SECONDS=0 the loop never runs and the `echo "$code"`
  # below would trip `set -u` with `code: unbound variable` instead of reporting a failed host.
  local host="$1" code=000 end=$((SECONDS + READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$end" ]; do
    code="$(route_code "$host")"
    case "$code" in
      2??|3??) echo "$code"; return 0 ;;                 # routed to a live backend
      000|50[234]) : ;;                                   # not routable yet — retry
      *) : ;;                                             # 4xx etc — keep polling briefly
    esac
    sleep "$POLL_INTERVAL_SECONDS"
  done
  echo "$code"; return 1
}

log_info "verifying ingress routing via INGRESS_CONTROLLER=${INGRESS_CONTROLLER} at ${INGRESS_LB_IP}"
rc=0
_routes_checked=0
for host in "$GITEA_HOST" "$TEKTON_DASHBOARD_HOST" $APP_HOSTS; do
  _routes_checked=$((_routes_checked + 1))
  log_info "  route-readiness poll: ${host} (timeout ${READY_TIMEOUT_SECONDS}s)"
  if code="$(wait_route "$host")"; then
    log_info "  OK    ${host} -> HTTP ${code} (routed through the ingress LB)"
  else
    log_error "  FAIL  ${host} -> HTTP ${code} (not routable through ${INGRESS_LB_IP} within ${READY_TIMEOUT_SECONDS}s)"
    rc=1
  fi
done

# Assert each host's body actually comes from ITS backend, not just a 200 from some
# proxy — a wrong Ingress/VirtualService backend still returns 2xx. Markers are the
# apps' own branding: Gitea always emits "gitea" (title/footer/asset paths), the app
# renders class="message", Tekton emits "tekton". curl -L follows any login/dashboard
# redirect to the real page. (ArgoCD is NOT fronted by the ingress — it has its own
# LoadBalancer IP, like real VKS; see scripts/07-install-argocd.sh + make creds.)
if [ "$rc" -eq 0 ]; then
  assert_body() { # <host> <grep-ERE> <label>
    local b
    b="$(curl -sL -H "Host: $1" --max-time "$CURL_MAX_TIME_SECONDS" "http://${INGRESS_LB_IP}/" 2>/dev/null || true)"
    # Drop `-q` so grep DRAINS all of printf's output: on a page larger than the 64KB pipe
    # buffer, `grep -q` exits on its first match and SIGPIPEs `printf` (exit 141), which under
    # `set -o pipefail` misreads as "marker absent" → a false "wrong backend" on a page that WAS
    # served. Draining grep never SIGPIPEs the writer; redirect its own stdout to keep it quiet.
    if printf '%s' "$b" | grep -iE "$2" >/dev/null; then
      log_info "  OK    $1 served the $3 through the ingress"
    else
      log_error "  FAIL  $1 returned 2xx/3xx but not the $3 (wrong backend?)"
      rc=1
    fi
  }
  assert_body "$GITEA_HOST"             'gitea'           "Gitea UI"
  # EACH app must serve ITS OWN greeting page through the ingress — checking one app would let a
  # broken second app pass. Both the Java (Thymeleaf) and the Go (html/template) pages render the
  # greeting inside class="message", so the same assertion is meaningful for every app.
  while read -r _a; do
    [ -n "$_a" ] || continue
    assert_body "$(app_host "$_a")" 'class="message"' "${_a} greeting page"
  done <<EOF
$(app_names)
EOF
  assert_body "$TEKTON_DASHBOARD_HOST"  'tekton'          "Tekton Dashboard UI"
fi

if [ "$rc" -ne 0 ]; then
  log_error "ingress verification FAILED — diagnostics:"
  log_error "  INGRESS_LB_IP=${INGRESS_LB_IP} (PUBLISHED state from .env.state, not resolved live)."
  log_error "  If you rebuilt the cluster (or switched controllers) without re-running install-ingress,"
  log_error "  this IP is stale — re-run 'make install-ingress' to re-resolve + republish it. Otherwise,"
  log_error "  check the controller + its route objects:"
  case "${INGRESS_CONTROLLER}" in
    istio|istio-existing)
      log_error "    kubectl get gateway,virtualservice -A          # our routes (VSes live in the BACKEND namespaces)"
      log_error "    kubectl -n ${ISTIO_GATEWAY_NAMESPACE:-istio-ingress} get svc,pods"
      log_error "    kubectl -n ${ISTIO_NAMESPACE:-istio-system} get pods"
      log_error "  SYMPTOM GUIDE (istio):"
      log_error "    connection refused / no HTTP at all -> the Gateway's selector matches NO gateway workload."
      log_error "      The Gateway object is accepted without error, so nothing flags it. Compare:"
      log_error "        kubectl get gateway -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} selector={.spec.selector}{\"\\n\"}{end}'"
      log_error "        kubectl -n ${ISTIO_GATEWAY_NAMESPACE:-istio-ingress} get svc -o jsonpath='{.items[*].spec.selector}'"
      log_error "      Run 'make istio-preflight' — it reports the selector the mesh actually requires."
      log_error "    HTTP 404 -> Envoy is listening but no route matched: usually a VirtualService referencing"
      log_error "      the Gateway by BARE name from another namespace (a bare name resolves namespace-locally)."
      log_error "      It must be '<gateway-namespace>/<gateway-name>'."
      ;;
    traefik) log_error "    kubectl -n ${TRAEFIK_NAMESPACE:-traefik} get ingress,svc,pods" ;;
  esac
  die "ingress routing not verified"
fi
# State the DENOMINATOR: "all UIs reachable" over an unstated count is the shape that lets a
# shrunken host list read as a full pass. Reconcile it against the registry, not against memory.
log_info "SUCCESS — all ${_routes_checked} UI(s) reachable through the ${INGRESS_CONTROLLER} ingress at ${INGRESS_LB_IP} (*.vks.local)"
