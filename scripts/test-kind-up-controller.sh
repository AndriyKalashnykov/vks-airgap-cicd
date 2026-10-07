#!/usr/bin/env bash
# test-kind-up-controller.sh — `make kind-up` must not silently replace ANOTHER project's
# cloud-provider-kind controller (B741).
#
# One controller serves every kind cluster on a host, and 05-kind-up.sh removes whatever controller
# is running and starts this project's. With another project's cluster on the box (golang-web's, say)
# that swapped the other project's controller without a word. The script now decides BEFORE it
# creates anything: another cluster + a controller whose image or arguments are not ours -> stop,
# name the cluster, change nothing.
#
# The decision was settled by measurement on 2026-10-06 with two real clusters (see the comment in
# 05-kind-up.sh, step 0). This test pins the decision itself, offline, with stateful fakes: every
# arm asserts on the fakes' call log, because the property is about what was NOT created or removed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1" >&2; fail=1; }

KU="${SCRIPT_DIR}/05-kind-up.sh"
OURS_ARGS='["--gateway-channel=disabled"]'

# SELF-CANARY (same reason as test-kind-down-safety.sh): lib/os.sh exports REPO_ROOT, so a sandboxed
# run that forgot to pin it would write the REAL repo's state overlay and kubeconfig.
_canary=""
for _cf in "${REPO_ROOT}/.env.state" "${REPO_ROOT}/secrets/kind.kubeconfig"; do
  [ -f "$_cf" ] && _canary="${_canary}$(md5sum "$_cf" 2>/dev/null || true)"
done

_sandbox() {                      # -> echoes the sandbox dir; state in $sb/st
  local sb; sb="$(mktemp -d)"
  cp -a "$SCRIPT_DIR" "$sb/scripts"
  [ -f "${SCRIPT_DIR}/../.env.example" ] && cp "${SCRIPT_DIR}/../.env.example" "$sb/"
  mkdir -p "$sb/kind" "$sb/fakebin" "$sb/st"
  : > "$sb/kind/kind-config.yaml"; : > "$sb/st/clusters"; : > "$sb/st/calls"
  cat > "$sb/fakebin/kind" <<'STUB'
#!/usr/bin/env bash
st="$(cd "$(dirname "$0")/.." && pwd)/st"
printf 'kind %s\n' "$*" >> "$st/calls"
case "$1 ${2:-}" in
  "get clusters")   [ -f "$st/kind_get_fails" ] && { echo "ERROR: failed to list clusters" >&2; exit 1; }
                    cat "$st/clusters" ;;
  "get kubeconfig") echo "apiVersion: v1" ;;
  "create cluster") name=""; while [ $# -gt 0 ]; do [ "$1" = --name ] && name="$2"; shift; done
                    echo "$name" >> "$st/clusters" ;;
esac
exit 0
STUB
  cat > "$sb/fakebin/docker" <<'STUB'
#!/usr/bin/env bash
# The controller exists iff st/cpk_image exists; its arguments are in st/cpk_args (JSON).
st="$(cd "$(dirname "$0")/.." && pwd)/st"
printf 'docker %s\n' "$*" >> "$st/calls"
case "$1" in
  ps)      [ -f "$st/cpk_image" ] && echo cloud-provider-kind ;;
  inspect) case "$*" in
             *Config.Image*) cat "$st/cpk_image" 2>/dev/null ;;
             *.Args*)        cat "$st/cpk_args" 2>/dev/null ;;
           esac ;;
  rm)      rm -f "$st/cpk_image" "$st/cpk_args" ;;
  # Without st/run_ok the walk ends here on purpose: starting the controller "fails", so
  # 05-kind-up.sh stops under set -e instead of going on to the readiness and log checks.
  run)     [ -f "$st/run_ok" ] || { echo "fake docker: not starting a container" >&2; exit 1; }
           echo started > "$st/cpk_image" ;;
  logs)    cat "$st/logs" 2>/dev/null ;;
esac
exit 0
STUB
  cat > "$sb/fakebin/kubectl" <<'STUB'
#!/usr/bin/env bash
st="$(cd "$(dirname "$0")/.." && pwd)/st"
[ -f "$st/run_ok" ] || exit 1
case "$*" in *"get namespace"*) exit 1 ;; esac
exit 0
STUB
  chmod +x "$sb/fakebin"/*
  printf '%s' "$sb"
}
# The cluster name and controller version 05-kind-up.sh resolves come from .env.example (it outranks
# the environment), so the fixtures derive them the same way.
_own_name()  { sed -n 's/^KIND_CLUSTER_NAME=//p' "$1/.env.example" | head -1; }
_our_image() { printf 'registry.k8s.io/cloud-provider-kind/cloud-controller-manager:%s' "$(sed -n 's/^CLOUD_PROVIDER_KIND_VERSION=//p' "$1/.env.example" | head -1)"; }
# The run may die AFTER the decision (the fakes do not carry it to a ready cluster); only the call
# log and the output are asserted. REPO_ROOT is pinned to the sandbox on EVERY invocation.
_run_ku() {
  KU_RC=0
  KU_OUT="$(cd "$1" && timeout 60 env PATH="$1/fakebin:$PATH" REPO_ROOT="$1" VKS_STATE_FILE="$1/.env.state" \
            SKIP_DOTENV=1 bash "$1/scripts/05-kind-up.sh" 2>&1)" || KU_RC=$?
}
_created() { grep '^kind create cluster' "$1/st/calls" >/dev/null; }
_started() { grep '^docker run ' "$1/st/calls" >/dev/null; }
_removed() { grep '^docker rm ' "$1/st/calls" >/dev/null; }

# 0. The fixture must be what the arms assume.
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; IMG="$(_our_image "$sb")"
if [ -n "$OWN" ] && [ "$OWN" != other-project ] && [ "${IMG##*:}" != "" ]; then
  ok "fixture: the sandbox .env.example names the cluster '$OWN' and the controller image tag '${IMG##*:}'"
else
  bad "fixture: could not derive the cluster name or controller version from .env.example — every arm below would be vacuous"
fi
rm -rf "$sb"

# 1. Another project's cluster + a controller that is NOT ours (golang-web's shape: no arguments):
#    stop before anything is created or removed, and name the other cluster.
sb="$(_sandbox)"; IMG="$(_our_image "$sb")"
printf 'other-project\n' > "$sb/st/clusters"; printf '%s\n' "$IMG" > "$sb/st/cpk_image"; printf '[]\n' > "$sb/st/cpk_args"
_run_ku "$sb"
if [ "$KU_RC" -ne 0 ] && ! _created "$sb" && ! _removed "$sb" && [ -f "$sb/st/cpk_image" ]; then
  ok "another cluster + a foreign controller: kind-up stops, creates no cluster, removes nothing"
else
  bad "another cluster + a foreign controller: kind-up went ahead (rc=$KU_RC) — calls: $(tr '\n' ';' < "$sb/st/calls" | cut -c1-200)"
fi
_way='docker rm -f cloud-provider-kind'; [ "$(uname -s)" = Darwin ] && _way="Delete the other project's cluster"
if grep -F 'other-project' <<< "$KU_OUT" >/dev/null && grep -F "$_way" <<< "$KU_OUT" >/dev/null; then
  ok "the refusal names the other cluster and says what to do next ($_way)"
else
  bad "the refusal does not name the other cluster or the way forward — output tail: $(tail -3 <<< "$KU_OUT" | tr '\n' ' ' | cut -c1-200)"
fi
rm -rf "$sb"

# 2. Same, but only the IMAGE differs (an older controller with our argument): still not ours.
sb="$(_sandbox)"
printf 'other-project\n' > "$sb/st/clusters"; printf 'registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.0.1\n' > "$sb/st/cpk_image"
printf '%s\n' "$OURS_ARGS" > "$sb/st/cpk_args"
_run_ku "$sb"
if [ "$KU_RC" -ne 0 ] && ! _created "$sb" && ! _removed "$sb"; then
  ok "another cluster + a controller on a different image: kind-up stops"
else
  bad "another cluster + a controller on a different image: kind-up went ahead (rc=$KU_RC)"
fi
rm -rf "$sb"

# 3. CONTROL: another cluster + OUR controller (same image, same argument): go ahead. Measured: a
#    remove-and-start with the same settings keeps the other cluster's LoadBalancer addresses.
sb="$(_sandbox)"; IMG="$(_our_image "$sb")"
printf 'other-project\n' > "$sb/st/clusters"; printf '%s\n' "$IMG" > "$sb/st/cpk_image"; printf '%s\n' "$OURS_ARGS" > "$sb/st/cpk_args"
_run_ku "$sb"
if _created "$sb" && _removed "$sb" && _started "$sb" && ! grep -F 'Nothing was created' <<< "$KU_OUT" >/dev/null; then
  ok "CONTROL: another cluster + this project's own controller: kind-up creates the cluster, then removes and starts the controller"
else
  bad "CONTROL: another cluster + our own controller: kind-up refused — it over-refuses (rc=$KU_RC)"
fi
rm -rf "$sb"

# 4. CONTROL: NO other cluster + a foreign controller left behind: go ahead (it serves nobody).
sb="$(_sandbox)"; IMG="$(_our_image "$sb")"
printf '%s\n' "$IMG" > "$sb/st/cpk_image"; printf '[]\n' > "$sb/st/cpk_args"
_run_ku "$sb"
if _created "$sb" && _removed "$sb" && _started "$sb" && ! grep -F 'Nothing was created' <<< "$KU_OUT" >/dev/null; then
  ok "CONTROL: no other cluster + a leftover foreign controller: kind-up replaces it"
else
  bad "CONTROL: no other cluster, yet kind-up refused over a leftover controller (rc=$KU_RC)"
fi
rm -rf "$sb"

# 5. CONTROL: another cluster and NO controller at all: go ahead.
sb="$(_sandbox)"
printf 'other-project\n' > "$sb/st/clusters"
_run_ku "$sb"
if _created "$sb" && _started "$sb" && ! _removed "$sb" && ! grep -F 'Nothing was created' <<< "$KU_OUT" >/dev/null; then
  ok "CONTROL: another cluster and no controller running: kind-up creates the cluster and starts the controller"
else
  bad "CONTROL: another cluster, no controller, yet kind-up refused (rc=$KU_RC)"
fi
rm -rf "$sb"

# 6. The cluster listing cannot be answered: die before creating anything (no decision is possible).
sb="$(_sandbox)"; : > "$sb/st/kind_get_fails"
_run_ku "$sb"
if [ "$KU_RC" -ne 0 ] && ! _created "$sb" && grep -F 'cannot list kind clusters' <<< "$KU_OUT" >/dev/null; then
  ok "kind cannot list clusters: kind-up stops before creating anything and says why"
else
  bad "kind could not list clusters, yet kind-up went ahead or gave no reason (rc=$KU_RC)"
fi
rm -rf "$sb"

# 7. The decision sits BEFORE the create in the source too (a refusal must leave nothing half-built).
_guard_line="$(grep -n 'Nothing was created' "$KU" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # a literal source line is being searched for; nothing may expand here
_create_line="$(grep -n 'run kind "\${create_args\[@\]}"' "$KU" | head -1 | cut -d: -f1)"
if [ -n "$_guard_line" ] && [ -n "$_create_line" ] && [ "$_guard_line" -lt "$_create_line" ]; then
  ok "the refusal (line $_guard_line) comes before the cluster create (line $_create_line)"
else
  bad "the refusal (line ${_guard_line:-none}) does not precede the cluster create (line ${_create_line:-none})"
fi

# 8. Never a graceful stop or restart of the controller: on SIGTERM it deletes the sidecars of EVERY
#    cluster it serves. Comments stripped first.
if sed -E 's@^[[:space:]]*#.*@@' "$KU" | grep -E '(^|[;&|[:space:]])docker[[:space:]]+(stop|restart)([[:space:]]|$)' >/dev/null; then
  bad "05-kind-up.sh uses docker stop/restart — a graceful stop makes cloud-provider-kind delete every cluster's sidecars"
else
  ok "05-kind-up.sh never stops the controller gracefully (docker rm -f only)"
fi

# 9. CONTROL: OUR cluster is the only one listed (a warm re-run) + a leftover foreign controller.
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; IMG="$(_our_image "$sb")"
printf '%s\n' "$OWN" > "$sb/st/clusters"; printf '%s\n' "$IMG" > "$sb/st/cpk_image"; printf '[]\n' > "$sb/st/cpk_args"
_run_ku "$sb"
if _removed "$sb" && _started "$sb" && ! grep -F 'Nothing was created' <<< "$KU_OUT" >/dev/null; then
  ok "CONTROL: only our own cluster is listed + a leftover foreign controller: kind-up replaces it"
else
  bad "our own cluster was counted as another project's: kind-up refused on a warm re-run (rc=$KU_RC)"
fi
rm -rf "$sb"

# 10. A cluster whose name only CONTAINS ours is still another cluster (whole-line match).
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; IMG="$(_our_image "$sb")"
printf '%s-2\n' "$OWN" > "$sb/st/clusters"; printf '%s\n' "$IMG" > "$sb/st/cpk_image"; printf '[]\n' > "$sb/st/cpk_args"
_run_ku "$sb"
if [ "$KU_RC" -ne 0 ] && ! _created "$sb" && ! _removed "$sb" && grep -F "(${OWN}-2)" <<< "$KU_OUT" >/dev/null; then
  ok "a cluster named '<ours>-2' is another cluster: kind-up stops and names it"
else
  bad "a cluster named '<ours>-2' was taken for our own: kind-up went ahead (rc=$KU_RC)"
fi
rm -rf "$sb"

# 11. The controller is STARTED with the same argument step 0 compares against (one source).
sb="$(_sandbox)"
_run_ku "$sb"
if grep -E "^docker run .* ${OURS_ARGS:2:${#OURS_ARGS}-4}\$" "$sb/st/calls" >/dev/null; then
  ok "the controller is started with the argument the guard calls ours"
else
  bad "the controller start does not end in the argument the guard compares: $(grep '^docker run' "$sb/st/calls" | cut -c1-200)"
fi
rm -rf "$sb"

# 12. The log check wants OUR cluster's line. Only another cluster's line -> it waits, then fails.
sb="$(_sandbox)"; : > "$sb/st/run_ok"
printf 'other-project\n' > "$sb/st/clusters"
printf '"Gateway API CRDs installation skipped (disabled)" cluster="other-project"\n' > "$sb/st/logs"
READY_TIMEOUT_SECONDS=2 POLL_INTERVAL_SECONDS=1 _run_ku "$sb"
if [ "$KU_RC" -ne 0 ] && grep -F 'still managing the Gateway API CRDs' <<< "$KU_OUT" >/dev/null; then
  ok "only the OTHER cluster's skip line in the controller log: kind-up fails after the bounded wait"
else
  bad "another cluster's skip line was accepted as ours, or the wait never ended (rc=$KU_RC)"
fi
rm -rf "$sb"
# ... and with our line as well, it passes (a fresh sandbox: the first run left a fake controller).
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; : > "$sb/st/run_ok"; printf 'other-project\n' > "$sb/st/clusters"
printf '"Gateway API CRDs installation skipped (disabled)" cluster="other-project"\n' > "$sb/st/logs"
printf '"Gateway API CRDs installation skipped (disabled)" cluster="%s"\n' "$OWN" >> "$sb/st/logs"
READY_TIMEOUT_SECONDS=2 POLL_INTERVAL_SECONDS=1 _run_ku "$sb"
if [ "$KU_RC" -eq 0 ]; then
  ok "CONTROL: our cluster's skip line in the controller log: kind-up finishes"
else
  bad "CONTROL: our own skip line was not accepted (rc=$KU_RC) — tail: $(tail -2 <<< "$KU_OUT" | tr '\n' ' ' | cut -c1-200)"
fi
rm -rf "$sb"

# 13. ANOTHER cluster's failed start must not be read as OUR controller crash-looping.
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; : > "$sb/st/run_ok"; printf 'other-project\n' > "$sb/st/clusters"
printf '"Failed to start cloud controller" err="timed out" cluster="other-project"\n' > "$sb/st/logs"
printf '"Gateway API CRDs installation skipped (disabled)" cluster="%s"\n' "$OWN" >> "$sb/st/logs"
READY_TIMEOUT_SECONDS=2 POLL_INTERVAL_SECONDS=1 _run_ku "$sb"
if [ "$KU_RC" -eq 0 ]; then
  ok "another cluster's 'Failed to start' line does not fail our kind-up"
else
  bad "another cluster's failure line was counted against ours (rc=$KU_RC) — tail: $(tail -2 <<< "$KU_OUT" | tr '\n' ' ' | cut -c1-200)"
fi
rm -rf "$sb"
# ... and OUR OWN failure line still does (the crash check did not degenerate into always-pass).
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; : > "$sb/st/run_ok"
printf '"Gateway API CRDs installation skipped (disabled)" cluster="%s"\n' "$OWN" > "$sb/st/logs"
printf '"Failed to start cloud controller" err="timed out" cluster="%s"\n' "$OWN" >> "$sb/st/logs"
READY_TIMEOUT_SECONDS=2 POLL_INTERVAL_SECONDS=1 _run_ku "$sb"
if [ "$KU_RC" -ne 0 ] && grep -F 'crash-looping' <<< "$KU_OUT" >/dev/null; then
  ok "CONTROL: our own cluster's 'Failed to start' line still fails kind-up as crash-looping"
else
  bad "CONTROL: our own failure line no longer fails kind-up (rc=$KU_RC)"
fi
rm -rf "$sb"

# 14. The controller reached our cluster ("Starting cloud controller") WITHOUT logging the skip: the
#     answer is final, so fail at once — not after READY_TIMEOUT (300 s by default).
sb="$(_sandbox)"; OWN="$(_own_name "$sb")"; : > "$sb/st/run_ok"
printf '"Starting cloud controller" cluster="%s"\n' "$OWN" > "$sb/st/logs"
_t0=$SECONDS
READY_TIMEOUT_SECONDS=40 POLL_INTERVAL_SECONDS=1 _run_ku "$sb"
_dt=$((SECONDS - _t0))
if [ "$KU_RC" -ne 0 ] && [ "$_dt" -lt 20 ] && grep -F 'still managing the Gateway API CRDs' <<< "$KU_OUT" >/dev/null; then
  ok "skip line missing but the controller already started for our cluster: fails in ${_dt}s, not after the timeout"
else
  bad "a controller that started for our cluster without the skip line took ${_dt}s or did not fail (rc=$KU_RC)"
fi
rm -rf "$sb"

_canary_after=""
for _cf in "${REPO_ROOT}/.env.state" "${REPO_ROOT}/secrets/kind.kubeconfig"; do
  [ -f "$_cf" ] && _canary_after="${_canary_after}$(md5sum "$_cf" 2>/dev/null || true)"
done
if [ "$_canary" = "$_canary_after" ]; then
  ok "SELF-CANARY: this test did not touch the REAL repo's state overlay or kubeconfig"
else
  bad "SELF-CANARY: the REAL repo's .env.state or secrets/kind.kubeconfig changed during this test"
fi

[ "$fail" = 0 ] && { echo "test-kind-up-controller: OK"; exit 0; }
echo "test-kind-up-controller: FAILED" >&2; exit 1
