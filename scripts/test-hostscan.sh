#!/usr/bin/env bash
# test-hostscan.sh — the unhandled-registry-host scanner (B568).
#
# ⚠️ THE FIXTURES ARE THE POINT. A naive host-shaped scan is ~97% NOISE on real Kubernetes
# manifests -- MEASURED on the carried Tekton manifests: 32 "hosts", of which 31 were API groups,
# label keys, doc URLs and examples, and ONE was a real image. A gate at that false-RED rate is one
# people delete. Every negative case below is a shape that actually appears in those manifests.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=scripts/lib/os.sh
. scripts/lib/os.sh 2>/dev/null
# shellcheck source=scripts/lib/mirror.sh
. scripts/lib/mirror.sh 2>/dev/null
# shellcheck source=scripts/lib/hostscan.sh
. scripts/lib/hostscan.sh 2>/dev/null

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

REPO_SCRIPTS="$PWD/scripts"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
case_is() {  # <label> <fixture-line> <want: FLAG|quiet>
  printf '%s\n' "$2" > "$T/m.yaml"
  local got; got="$(hostscan_unhandled "$T" | wc -l | tr -d ' ')"
  local want=1; [ "$3" = quiet ] && want=0
  if [ "$got" = "$want" ]; then ok "$1"; else bad "$1 — got $got unhandled, want $want"; fi
}

# ── MUST FLAG: a real image ref on a host nothing covers ────────────────────────────────────────
# The INCIDENT SHAPE: a digest-pinned ref inside a flag string, on a host nothing covers.
case_is "an unmirrored host with a digest, in a flag string" \
  '            "-shell-image", "notmirrored.example.io/chainguard/busybox@sha256:19f02276bf8dbdd62f069b922f10c65262cc34b710eea26ff928129a736be791"' FLAG
case_is "an unmirrored host with a tag" \
  '        image: registry.example.io/team/app:1.2.3' FLAG
case_is "...even inside a flag string, not an image: field" \
  '            "-some-flag", "evil.example.io/x/y:v1"' FLAG

# ── MUST NOT FLAG: the 31 shapes that made the naive version unusable ───────────────────────────
case_is "a Kubernetes API group"        'apiVersion: rbac.authorization.k8s.io/v1'                    quiet
case_is "a label key"                   '    app.kubernetes.io/name: tekton-pipelines'               quiet
case_is "a doc URL in a comment"        '# see https://www.apache.org/licenses/LICENSE-2.0'          quiet
case_is "an RFC link"                   '# per https://tools.ietf.org/html/rfc7230'                  quiet
case_is "an example hostname"           '  issuer: foo.example.com/CamelCase.'                       quiet
case_is "an in-cluster svc with a port" '  endpoint: jaeger-collector.jaeger.svc.cluster.local:4318/v1/traces' quiet
case_is "a host we DO mirror"           '        image: gcr.io/tekton-releases/controller:v1.15.0'   quiet
# REGRESSION GUARD for the incident itself: cgr.dev must STAY in MIRROR_REGISTRY_HOSTS. Removing it
# is what caused a public pull on every build; this case goes RED if anyone takes it back out.
case_is "cgr.dev is covered (the incident's own fix)" \
  '            "-shell-image", "cgr.dev/chainguard/busybox@sha256:19f02276bf8dbdd62f069b922f10c65262cc34b710eea26ff928129a736be791"' quiet
case_is "the documented allowlist entry" \
  '            "-shell-image-win", "mcr.microsoft.com/powershell:nanoserver@sha256:b6d5ff841b78bdf2dfed7550000fd4f3437385b8fa686ec0f010be24777654d6"' quiet

# ── The allowlist must be NARROW: another unmirrored host is still flagged alongside it ──────────
printf '%s\n%s\n' \
  '  "-shell-image-win", "mcr.microsoft.com/powershell:nanoserver@sha256:b6d5ff841b78bdf2dfed7550000fd4f3437385b8fa686ec0f010be24777654d6"' \
  '  image: sneaky.example.io/x:v1' > "$T/m.yaml"
if [ "$(hostscan_unhandled "$T" | wc -l | tr -d ' ')" = 1 ]; then
  ok "the allowlist exempts ONLY its own host"
else
  bad "the allowlist is too broad or too narrow"
fi

# ── VACUITY: an empty corpus must not read as clean ──────────────────────────────────────────────
# The scanner returns nothing for an empty dir, which is correct in ISOLATION but is exactly how a
# gate passes by not looking -- so the CALLER must guarantee the manifests exist. 10-mirror-pull.sh
# does (assert_k8s_manifest runs first); this pins that the scanner itself is honest about it.
rm -f "$T"/*.yaml
if [ -z "$(hostscan_unhandled "$T")" ] && [ -z "$(hostscan_unhandled "$T/nonexistent")" ]; then
  ok "an empty or absent corpus yields nothing (the CALLER must assert the manifests exist)"
else
  bad "the scanner invented findings from an empty corpus"
fi

# ── THE CALLER'S SET FLAGS: the one failure the cases above CANNOT see ───────────────────────────
# Every caller runs `set -euo pipefail`, and this harness does not -- so a pipefail trap inside the
# function is invisible to every case above, all of which passed while `make mirror-pull` would have
# died on a CLEAN tree. The exclusion greps exit 1 when they filter everything away, which is the
# NORMAL state, so the guard failed exactly when it should have passed.
# RED-proof: delete the `|| true` from the pipeline in lib/hostscan.sh and this case goes red.
_setflags() {   # prints SURVIVED:<first host> or DIED
  # shellcheck disable=SC2016  # single quotes are REQUIRED: the body must be expanded by the
  # child bash under ITS set flags, not interpolated by this harness. "$1"/"$2" are its positionals.
  env -u BASH_ENV bash --noprofile --norc -c '
    set -euo pipefail
    . "$1/lib/mirror.sh" 2>/dev/null || true
    . "$1/lib/hostscan.sh"
    # ⚠️ AN ASSIGNMENT, exactly as 10-mirror-pull.sh writes it. `printf "%s" "$(...)"` would put the
    # substitution in ARGUMENT position, where `set -e` does NOT fire -- the first version of this
    # probe did that and passed 15/15 with the fix deliberately removed. The instrument was the bug.
    out="$(hostscan_unhandled "$2")"
    printf "SURVIVED:%s" "$(printf "%s" "$out" | cut -f1 | tr -d "\n")"
  ' _ "$REPO_SCRIPTS" "$T" 2>/dev/null || printf 'DIED'
}
printf '%s\n' '        image: gcr.io/tekton-releases/controller:v1.15.0' > "$T/m.yaml"
_clean="$(_setflags)"
printf '%s\n' '  "-shell-image", "notmirrored.example.io/x/y@sha256:abc123"' > "$T/m.yaml"
_dirty="$(_setflags)"
if [ "$_clean" = "SURVIVED:" ] && [ "$_dirty" = "SURVIVED:notmirrored.example.io" ]; then
  ok "survives the caller's set -euo pipefail on BOTH a clean and a dirty corpus"
else
  bad "set -euo pipefail: clean=[$_clean] dirty=[$_dirty] (want SURVIVED: / SURVIVED:notmirrored.example.io)"
fi

printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
