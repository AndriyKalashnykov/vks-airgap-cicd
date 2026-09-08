#!/usr/bin/env bash
# 97-verify-workload-images.sh's classifier, RED/GREEN-proven OFFLINE via pod-JSON fixtures.
#
# Without the fixture hook this gate could only ever be proven by a ~30-minute e2e against a live
# cluster, which is how gates end up shipped unproven. Every case below is a pod shape that actually
# occurs.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

T="$(mktemp -d)"
GATE=./scripts/97-verify-workload-images.sh

# run <label> <want-rc> <want-verdict-substring>; fixtures already written into $T
run() {
  local label="$1" wrc="$2" wv="$3" out rc=0
  out="$(PODIMAGES_FIXTURE="$T" HARBOR_URL=h.local SKIP_DOTENV=1 "$GATE" 2>&1)" || rc=$?
  local v; v="$(printf '%s\n' "$out" | grep -o 'workload-image-verdict: [A-Za-z:-]*' | head -1)"
  if [ "$rc" = "$wrc" ] && [ "${v#*: }" != "$v" ] && case "$v" in *"$wv"*) true ;; *) false ;; esac; then
    ok "$label"
  else
    bad "$label — rc=$rc (want $wrc), verdict=[$v] (want *$wv*)"
    printf '%s\n' "$out" | sed 's/^/          /' | head -6
  fi
}

# Exactly ONE verdict token per run: a SKIP and a PASS were both rc=0 with no token on 96 until that
# was fixed, and this gate must not repeat it.
tokens() { PODIMAGES_FIXTURE="$T" HARBOR_URL=h.local SKIP_DOTENV=1 "$GATE" 2>&1 | grep -c 'workload-image-verdict:' || true; }

mk() { printf '%s' "$2" > "$T/$1.json"; }
ALL_OURS='{"items":[{"metadata":{"name":"p"},"status":{"containerStatuses":[{"image":"h.local/a/b:1","imageID":"h.local/a/b@sha256:aa"}]}}]}'

# ── the happy path ───────────────────────────────────────────────────────────────────────────────
mk ci "$ALL_OURS"; mk tekton-pipelines "$ALL_OURS"; mk tekton-pipelines-resolvers "$ALL_OURS"
run "every container came from our registry -> ASSERTED" 0 ASSERTED
if [ "$(tokens)" = 1 ]; then ok "exactly ONE verdict token on the pass path"; else bad "token count = $(tokens), want 1"; fi

# ── THE INCIDENT SHAPE: a public image in an INIT container, which is where B567 actually hid ─────
mk tekton-pipelines '{"items":[{"metadata":{"name":"ctl"},"status":{
  "containerStatuses":[{"image":"h.local/a/b:1","imageID":"h.local/a/b@sha256:aa"}],
  "initContainerStatuses":[{"image":"cgr.dev/chainguard/busybox:latest","imageID":"cgr.dev/chainguard/busybox@sha256:bb"}]}}]}'
run "a PUBLIC image in an INIT container is caught (the B567 shape)" 1 FAILED
mk tekton-pipelines "$ALL_OURS"

# ── the CRI normalisation that a .image-only test would false-RED ─────────────────────────────────
mk ci '{"items":[{"metadata":{"name":"p"},"status":{"containerStatuses":[
  {"image":"sha256:cafe","imageID":"h.local/a/b@sha256:cafe"}]}}]}'
run "a CRI-normalised bare sha256: image is OURS via imageID, not a failure" 0 ASSERTED
mk ci "$ALL_OURS"

# ── an EPHEMERAL container counts too (a debug container is a real pull) ──────────────────────────
mk ci '{"items":[{"metadata":{"name":"p"},"status":{
  "containerStatuses":[{"image":"h.local/a/b:1","imageID":"h.local/a/b@sha256:aa"}],
  "ephemeralContainerStatuses":[{"image":"docker.io/lib/nicolaka:1","imageID":"docker.io/lib/nicolaka@sha256:dd"}]}}]}'
run "an EPHEMERAL debug container from a public registry is caught" 1 FAILED
mk ci "$ALL_OURS"

# ── THE LOOKALIKE HOST: a substring test reported these `ok` and closed ASSERTED ──────────────────
# MEASURED by an implementation round against the real gate, with this lab's own hostname shape.
# A sibling/stale registry in the same domain is exactly what an enterprise lab has.
mk ci '{"items":[{"metadata":{"name":"look"},"status":{"containerStatuses":[
  {"image":"oldharbor.h.local/infra/gitea:1","imageID":"oldharbor.h.local/infra/gitea@sha256:ee"}]}}]}'
run "a LOOKALIKE registry in the same domain is FOREIGN, not a substring match" 1 FAILED
mk ci "$ALL_OURS"

# ── the three HARBOR_URL spellings lib/harbor.sh documents as real .env inputs ────────────────────
# Each of these reported 3/3 FOREIGN before the fix and died accusing the operator of an air-gap
# breach. A gate that is always red for a benign reason gets loosened or deleted.
for _spell in 'https://h.local' 'h.local/' 'h.local:443'; do
  _o="$(PODIMAGES_FIXTURE="$T" HARBOR_URL="$_spell" SKIP_DOTENV=1 "$GATE" 2>&1)"; _rc=$?
  if [ "$_rc" = 0 ] && printf '%s' "$_o" | grep -q 'workload-image-verdict: ASSERTED'; then
    ok "HARBOR_URL spelled '${_spell}' still recognises our own images"
  else
    bad "HARBOR_URL='${_spell}' false-RED: rc=$_rc"
  fi
done

# ── VACUITY: a namespace we OWN with no pods must NOT pass ────────────────────────────────────────
mk tekton-pipelines-resolvers '{"items":[]}'
run "a namespace we OWN that EXISTS but has no containers is INCOMPLETE, never a pass" 1 INCOMPLETE
mk tekton-pipelines-resolvers "$ALL_OURS"

# ...and an ABSENT namespace is a clean skip, not a gap. The two must not be conflated: on a real
# lab we do not install traefik when istio is the ingress, and that is not a hole.
rm -f "$T/tekton-pipelines-resolvers.json"
run "an ABSENT namespace is skipped cleanly, not reported as a gap" 0 ASSERTED
mk tekton-pipelines-resolvers "$ALL_OURS"

rm -f "$T"/*.json
run "no pods anywhere -> SKIPPED, and it says so rather than passing" 0 SKIPPED
mk ci "$ALL_OURS"; mk tekton-pipelines "$ALL_OURS"; mk tekton-pipelines-resolvers "$ALL_OURS"

# ── no registry to compare against is a SKIP, not a pass ──────────────────────────────────────────
_out="$(PODIMAGES_FIXTURE="$T" HARBOR_URL='' SKIP_DOTENV=1 "$GATE" 2>&1)"; _rc=$?
if [ "$_rc" = 0 ] && printf '%s' "$_out" | grep -q 'SKIPPED:no-registry'; then
  ok "an unset HARBOR_URL SKIPS loudly instead of comparing against an empty prefix"
else
  bad "empty-registry: rc=$_rc out=[$(printf '%s' "$_out" | head -2)]"
fi

# ── the ownership typo guard (mirrors 49-psa-check.sh) ────────────────────────────────────────────
# ⚠️ THE MUTATED COPY MUST LIVE IN scripts/, and the first version of this case did not -- which made
# it 100% VACUOUS. The gate resolves SCRIPT_DIR from BASH_SOURCE, so a copy in $T sourced
# "$T/lib/os.sh", which does not exist: it died rc=1 at line 27 and NEVER REACHED the NS_SPEC loop.
# An implementation round proved it discriminates nothing by running an UNMUTATED copy in the same
# place -- identical error, identical rc. The case passed with the mutation entirely removed.
# So: copy beside the real one, assert the gate's own DIE TEXT (not merely rc!=0), and RED-prove by
# confirming an UNMUTATED copy in the same location PASSES.
_g="./scripts/.typo-probe-$$.sh"
trap 'rm -f "$_g"; rm -rf "$T"' EXIT
sed 's/^tekton-pipelines-resolvers|ours$/tekton-pipelines-resolvers|OURS/' "$GATE" > "$_g"; chmod +x "$_g"
_o="$(PODIMAGES_FIXTURE="$T" HARBOR_URL=h.local SKIP_DOTENV=1 "$_g" 2>&1)" || true
if printf '%s' "$_o" | grep -q 'expected ours|not-ours'; then
  ok "an unrecognised ownership value DIES, naming the expected values"
else
  bad "ownership typo not caught — got: $(printf '%s' "$_o" | tail -1)"
fi
# THE POSITIVE CONTROL for the case above: the same copy, UNMUTATED, must pass. Without this the
# case cannot tell "the guard fired" from "the copy is broken" -- which is exactly what happened.
cp "$GATE" "$_g"; chmod +x "$_g"
if PODIMAGES_FIXTURE="$T" HARBOR_URL=h.local SKIP_DOTENV=1 "$_g" >/dev/null 2>&1; then
  ok "control: an UNMUTATED copy in the same location PASSES (so the case above measured the guard)"
else
  bad "control FAILED — the typo case cannot discriminate; it is measuring a broken copy"
fi
rm -f "$_g"

printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
