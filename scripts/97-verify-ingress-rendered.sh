#!/usr/bin/env bash
# 97-verify-ingress-rendered.sh — assert the ingress ROUTES WERE RENDERED, in a scope where the app
# backends deliberately do not exist.
#
# WHY THIS IS SEPARATE FROM 98-verify-ingress.sh, WHICH IT DOES NOT TOUCH.
# 98 asserts the full user-facing contract: every host routes to a LIVE backend serving its own body
# marker. That is the right gate for a complete stack, and it correctly FAILS in the air-gap
# sneakernet leg, where `gitops` is out of scope so javawebapp/gowebapp have no pods at all. Narrowing
# 98 with a host-subset knob to make it pass there is exactly the "loosen a verification gate to
# obtain green" anti-pattern this repo exists to prevent (B50 refuted that design in full).
#
# So this is an ADDITIVE check with its own fixed scope. It cannot shrink 98, because it is not 98.
#
# WHAT IT PROVES THAT NOTHING ELSE DOES. In the air-gap leg the CARRIED toolchain renders the routes:
# the carried `yq` appends each app host to the Gateway (lib/istio.sh) and the carried
# `envsubst`+`kubectl` render the per-app VirtualServices. Nothing verifies that rendering path. A
# 503 is the evidence: Envoy matched a route and resolved a cluster with no healthy endpoints. A 404
# means the route was never configured at all.
#
# THE 404-vs-503 SPLIT IS MEASURED, NOT INFERRED (2026-07-19, KinD + istio, backends absent):
#     nosuch.vks.local      -> 404   (no VirtualService: the route was never configured)
#     javawebapp.vks.local  -> 503   (VirtualService rendered, zero endpoints)
#     gowebapp.vks.local    -> 503   (same)
#     gitea.vks.local       -> 200   (rendered AND backed)
#     tekton.vks.local      -> 200   (same)
# That split is the whole basis of this gate. If a future controller collapses 404 into 503, the app
# assertion weakens to "not 000" and this file must say so rather than keep implying the stronger
# claim — re-measure with a host that has no VirtualService before trusting it on a new controller.
#
# shellcheck shell=bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
# shellcheck source=scripts/lib/apps.sh
. "${SCRIPT_DIR}/lib/apps.sh"
load_env

: "${INGRESS_LB_IP:?INGRESS_LB_IP not set — run 'make install-ingress' first (it publishes the LB IP to .env.state)}"
: "${GITEA_HOST:?}"; : "${TEKTON_DASHBOARD_HOST:?}"
: "${INGRESS_CONTROLLER:=istio}"
require_cmd curl "this gate probes the ingress over HTTP"

# THE SPLIT IS MEASURED ON ISTIO ONLY, so refuse to assert it elsewhere rather than assert it
# blindly. Traefik DOES render a per-app route (45-install-traefik.sh:107), but a plain k8s Ingress
# whose backend Service is absent makes Traefik not expose the router at all -> 404, which would
# invert this gate's meaning and fail every app host with a diagnosis blaming the carried toolchain
# for a bug it does not have. A header sentence saying "re-measure on a new controller" is not a
# control; this is. Widen the case ONLY after measuring a no-route host on that controller.
case "${INGRESS_CONTROLLER}" in
  istio|istio-existing) : ;;
  *) die "97-verify-ingress-rendered: the 404-vs-503 split is MEASURED only on istio; INGRESS_CONTROLLER='${INGRESS_CONTROLLER}' is unmeasured. Re-measure with a host that has NO route on that controller, then widen this guard — do not assume the split holds." ;;
esac
# RED-PROOF for the guard above, and note WHICH form works. `INGRESS_CONTROLLER=traefik ./97...` does
# NOT fire it: load_env sources .env.state AFTER the environment, so the PUBLISHED value wins (the
# state-overlay clobber this repo documents). That is correct for this gate — it must check what was
# actually installed, not what the caller claims — but it means the proof has to change the PUBLISHED
# value:
#   T=$(mktemp -d); git archive HEAD | tar -x -C "$T"; cp -a scripts/. "$T/scripts/"; cp .env.state "$T/"
#   sed -i 's/^INGRESS_CONTROLLER=.*/INGRESS_CONTROLLER=traefik/' "$T/.env.state"
#   ( cd "$T" && ./scripts/97-verify-ingress-rendered.sh ); echo "rc=$?"   # -> rc=1, FATAL ... unmeasured
# Verified 2026-07-19. The env-var form was tried first and silently PASSED — a recorded RED-proof
# that cannot fire is worse than none.

READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-10}"

# `curl -w '%{http_code}'` already PRINTS 000 on a connect failure AND exits non-zero, so the
# idiomatic `|| echo "000"` appends a SECOND one and yields `000000` (measured, len 6) — which no
# `case` arm matches, making the most diagnostic branch dead code. Normalise instead.
# NOTE ON 98-verify-ingress.sh, CORRECTED: an earlier version of this comment said the doubled string
# "degrades its `000|50[234]` retry arm" there. That was WRONG -- in 98 that arm and its `*)` are both
# `: ;`, so nothing was degraded and the harm was a nonsense `000000` in the failure line. Here the
# arms ARE materially distinct (000 / 404 / 2??-3?? / 5??), which is why the fix was load-bearing in
# THIS file. 98 is now fixed for a DIFFERENT and larger reason -- see its route_code header.
#
# WE DELIBERATELY DO NOT COPY 98'S TRANSPORT-STATUS NORMALISATION, because the two files ask different
# questions. 98 asks "is this host SERVING?", so a response truncated by --max-time is NOT a success
# and must collapse to 000. THIS file asks "is the route RENDERED?", and a backend that answered at all
# -- even partially -- has already proven the route exists. Collapsing that to 000 here would report
# "nothing answered at the LB; the gateway itself is not serving", which is the opposite of what
# happened. Same primitive, opposite correct normalisation.
#
# `|| true` below is REDUNDANT, kept deliberately: `set -e` is not inherited into a command
# substitution unless `shopt -s inherit_errexit` is set, and this repo sets it nowhere (verified).
# It is defence if that ever changes, not a live requirement -- an earlier comment claimed it was.
route_code() {
  local c
  c="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" \
        --max-time "$CURL_MAX_TIME_SECONDS" "http://${INGRESS_LB_IP}/" 2>/dev/null)" || true
  case "$c" in ''|*[!0-9]*) c=000 ;; esac
  printf '%s' "$c"
}

rc=0
infra_checked=0   # reported, not guarded — see the note at the bottom
app_checked=0

# --- the infra hosts DO have backends here: they must route AND serve their own marker -----------
for pair in "${GITEA_HOST}|gitea|Gitea UI" "${TEKTON_DASHBOARD_HOST}|tekton|Tekton Dashboard UI"; do
  host="${pair%%|*}"; rest="${pair#*|}"; marker="${rest%%|*}"; label="${rest#*|}"
  code=""; end=$((SECONDS + READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$end" ]; do
    code="$(route_code "$host")"
    case "$code" in 2??|3??) break ;; esac
    sleep "$POLL_INTERVAL_SECONDS"
  done
  infra_checked=$((infra_checked + 1))
  case "$code" in
    2??|3??)
      body="$(curl -sL -H "Host: $host" --max-time "$CURL_MAX_TIME_SECONDS" "http://${INGRESS_LB_IP}/" 2>/dev/null || true)"
      # Drain grep (no -q): on a page larger than the pipe buffer, -q SIGPIPEs the writer and
      # pipefail misreads that as "marker absent". Same trap 98-verify-ingress.sh documents.
      if printf '%s' "$body" | grep -iE "$marker" >/dev/null; then
        log_info "  OK    ${host} -> ${code} and served the ${label}"
      else
        log_error "  FAIL  ${host} -> ${code} but did NOT serve the ${label} (wrong backend?)"; rc=1
      fi ;;
    *) log_error "  FAIL  ${host} -> ${code} (the ingress did not route it within ${READY_TIMEOUT_SECONDS}s)"; rc=1 ;;
  esac
done

# --- the app hosts have NO backend here: a 5xx is the PROOF the route was rendered ---------------
while read -r a; do
  [ -n "$a" ] || continue
  host="$(app_host "$a")"
  # POLL. The infra poll above does NOT cover these: lib/istio.sh applies the shared-UI
  # VirtualServices (:599) BEFORE the per-app ones (:604), so the infra hosts can be routing while an
  # app's VS has not yet been programmed into Envoy. A single shot here would make this gate flaky-RED
  # in the air-gap leg (it runs immediately after install-ingress) with a diagnosis blaming the
  # carried toolchain — the K1.5 reconcile-race class 98-verify-ingress.sh already documents.
  # 5xx/2xx/3xx are TERMINAL (route programmed); 404/000 mean "not programmed yet" — keep waiting and
  # only emit the "never rendered" verdict at timeout.
  code=""; _end=$((SECONDS + READY_TIMEOUT_SECONDS))
  while [ "$SECONDS" -lt "$_end" ]; do
    code="$(route_code "$host")"
    case "$code" in 5??|2??|3??) break ;; esac
    sleep "$POLL_INTERVAL_SECONDS"
  done
  app_checked=$((app_checked + 1))
  case "$code" in
    000) log_error "  FAIL  ${host} -> 000: nothing answered at ${INGRESS_LB_IP}. The gateway itself is not serving."; rc=1 ;;
    404) log_error "  FAIL  ${host} -> 404: the ingress is up but has NO ROUTE for this host — the carried yq/envsubst/kubectl did NOT render its Gateway host + VirtualService."; rc=1 ;;
    2??|3??) log_error "  FAIL  ${host} -> ${code}: a backend ANSWERED. This check asserts the rendered-but-unbacked state; a live backend means the scope is wrong (did 'gitops' run?), so it proves nothing about rendering."; rc=1 ;;
    5??) log_info "  OK    ${host} -> ${code} (route RENDERED, backend absent as expected in this scope)" ;;
    *) log_error "  FAIL  ${host} -> ${code}: unexpected status; expected 5xx (rendered, unbacked)."; rc=1 ;;
  esac
done <<EOF
$(app_names)
EOF

# KNOWN LIMIT, stated rather than implied: istio returns 503 for a missing Service, for zero
# endpoints, AND for all-endpoints-unhealthy, and curl cannot separate them (the response carries no
# x-envoy-response-flags). So if `gitops` HAD run and an app were crash-looping, this gate would
# report "backend absent as expected" over a deployed-and-broken app. It is green for a reason it
# does not claim. Narrow in practice — the wiring is a scope where gitops never runs — and closing it
# would need kubectl, re-importing the very dependency B50 refused. Do not widen the claim.
#
# ITEM count, guarded. `app_checked` is the real denominator: it goes to zero when apps/registry.tsv
# empties or app_names breaks. There is deliberately NO infra_checked guard — the infra list is two
# hardcoded entries, so that count is structurally always 2 and a guard on it COULD NEVER FIRE. A
# guard that cannot fire is worse than none: it reads as a guarantee it does not give.
[ "$app_checked" -gt 0 ] || die "97-verify-ingress-rendered: checked 0 app host(s) — apps/registry.tsv is empty or app_names is broken. The gate has gone BLIND."

if [ "$rc" -ne 0 ]; then
  log_error "ingress RENDERING verification FAILED at ${INGRESS_LB_IP} (controller=${INGRESS_CONTROLLER})"
  exit 1
fi
log_info "97-verify-ingress-rendered: OK — ${infra_checked} infra host(s) routed and served their marker; ${app_checked} app host(s) RENDERED (5xx, unbacked) by the carried toolchain"
