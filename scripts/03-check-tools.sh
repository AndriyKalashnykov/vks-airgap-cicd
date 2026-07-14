#!/usr/bin/env bash
# 03-check-tools.sh — is this jump box actually able to run the flow?
#
# Read-only. Reports every CLI the flow uses, its version, and whether it is REQUIRED or
# OPTIONAL. Fails only when a REQUIRED tool is missing, so `make check-tools` answers
# "can I run this?" in one shot instead of discovering a missing binary halfway through
# a 20-minute mirror.
#
# Two things this deliberately does NOT require, because the repo genuinely does not need them
# (stated here so nobody "helpfully" adds them):
#
#   * istioctl — Istio is driven entirely through `helm` + `kubectl`. We never shell out to
#     istioctl, in either ingress mode. What matters for a mesh we did not install is the MESH,
#     not a local CLI: that is `make istio-preflight`.
#   * argocd (the CLI) — the bcrypt hash for the admin password is generated INSIDE the pod
#     (`kubectl exec … argocd account bcrypt`), and guest-cluster registration is done with
#     plain `kubectl`. The local CLI is used only to REPORT a version in `make argocd-preflight`,
#     so it is OPTIONAL: its absence degrades a diagnostic, it does not break the flow.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
load_env

# PHASE — WHICH BOX, AND WHERE IN THE RUNBOOK. Default: every tool is needed HERE, NOW.
#
#   CHECK_TOOLS_PHASE=pre-carry   the sneakernet AIR-GAPPED jump box, BEFORE `make bundle-load`.
#                                 The five CARRIED tools (crane/kubectl/helm/jq/yq) legitimately do not
#                                 exist yet — the bundle brings them — so their absence is NOT a failure.
#                                 The OS packages the tarball CANNOT carry still are.
#
# WHY AN EXPLICIT FLAG AND NOT A CLEVER PROBE. The obvious design is "detect no internet ⇒ this must be
# the air-gapped box". Two adversaries killed it, and they were right:
#   * IT FAILS OPEN ON EXACTLY THE BOX IT IS FOR. Corporate egress allowlists routinely permit
#     github.com / *.googleapis.com (OS + dev traffic) while blocking container registries. The probe
#     answers "has internet" on a jump box that cannot pull a single image — so we would print
#     "run make deps" to the very operator the flag exists to help. And the mirror case is worse: a proxy
#     that 407s on a genuinely DUAL-HOMED box reads as "air-gapped", and we would silently excuse five
#     missing tools as "pending from a bundle" that nobody is cutting.
#   * A PROBE CANNOT KNOW *WHEN*, AND *WHEN* IS THE QUESTION. Pre-carry vs post-bundle-load is a fact
#     about the operator's position in the RUNBOOK, not about this box's routing table.
#   * FAILURE POLARITY DECIDES IT. Forgetting the flag ⇒ a false RED: loud, safe, and the doc passes the
#     flag for you. A wrong probe ⇒ a false GREEN: silent, on the one box that cannot recover.
# The flag also keeps this script genuinely OFFLINE, which `test-airgap-toolchain.sh` needs (it runs
# `make check-tools` under `--network none` and REQUIRES rc=0 after bundle-load — that RED is a contract,
# and a "pending" excuse would have turned it into decoration).
CHECK_TOOLS_PHASE="${CHECK_TOOLS_PHASE:-full}"
case "$CHECK_TOOLS_PHASE" in
  full|pre-carry) : ;;
  *) die "CHECK_TOOLS_PHASE='${CHECK_TOOLS_PHASE}' is not one of: full (default) | pre-carry" ;;
esac

# tool|requirement|what it is for
#
# `carried` = REQUIRED, but the sneakernet bundle brings it (bundle-load installs it to ~/.local/bin).
# Treated exactly like `required` — EXCEPT in CHECK_TOOLS_PHASE=pre-carry, where its absence is expected.
TOOLS="
kubectl|carried|talk to the cluster (every step)
helm|carried|install Harbor / Istio / Gitea charts
jq|carried|Istio discovery, Harbor API, mirror bookkeeping
yq|carried|manifest edits in the mirror//install path
envsubst|required|render the \${VAR} tokens in k8s/ manifests (package: gettext)
awk|required|read apps/registry.tsv — EVERY per-app loop (lib/apps.sh) — and the images.lock digest lookup in mirror-verify. NOT on a bare photon:5.0 (package: gawk), so this box can pass every other check and still die at mirror-verify
tar|required|unpack the carried sneakernet bundle (bundle-load)
crane|carried|the image-mirror engine (pull/push/validate)
curl|required|Harbor + UI readiness probes
git|required|seed the Gitea repos, tag write-back
openssl|required|mint the self-signed Harbor/ArgoCD certs
argocd|optional|REPORT the client version in argocd-preflight. NOT needed to install or register: bcrypt runs in-pod, registration uses kubectl
vcf|lab-only|Supervisor login + workload-cluster kubeconfig (VKS_AUTH_METHOD=vcf). Installed by 'make install-vcf-clis' from operator-supplied licensed archives; the KinD stand-in does not need it
tkn|optional|inspect PipelineRuns by hand; the flow uses kubectl
docker|kind-only|the KinD stand-in (cloud-provider-kind + node exec) requires docker specifically
kind|kind-only|create the local stand-in cluster
podman|optional|the DEFAULT container engine for builds/mirroring (docker is only a fallback)
trivy|ci-only|make sec / static-check
gitleaks|ci-only|make sec / static-check
shellcheck|ci-only|make lint
kubeconform|ci-only|make validate (manifest schema)
hadolint|ci-only|make lint (Dockerfiles)
yamllint|ci-only|make lint (YAML)
"

# tool_version <tool> — print a version string WITHOUT touching the network or a cluster.
#
# THIS SCRIPT WAS NOT OFFLINE, AND IT COULD HANG FOR ~2 MINUTES. The old probe was generic: try
# `<tool> --version`, and if that produced nothing, fall back to `<tool> version`. For kubectl,
# `kubectl --version` FAILS (`Error: unknown flag: --version`, stdout empty), so it ALWAYS fell through
# to `kubectl version` — which CONTACTS THE API SERVER. load_env has already set KUBECONFIG, so on a box
# whose kubeconfig points at a Supervisor VIP behind a DROP firewall (the norm on a VCF management
# network) that call blocks on TCP connect with no client-side timeout: ~130 s of silence, inside the
# gate we advertise as "the cheapest failure available", and it runs BEFORE the 20-minute mirror.
#
# So: probe each tool the way THAT tool wants, never with a cluster-contacting form, and put a hard
# timeout on all of it. (`timeout` is coreutils; if it is somehow absent, run bare rather than skip.)
tool_version() {
  local t="$1" cmd
  case "$t" in
    kubectl) cmd=(kubectl version --client) ;;   # --client: NEVER dial the API server
    helm)    cmd=(helm version --short) ;;
    crane|kind|tkn|argocd|vcf) cmd=("$t" version) ;;
    *)       cmd=("$t" --version) ;;
  esac
  if have timeout; then
    timeout "${TOOL_VERSION_TIMEOUT_SECONDS:-5}" "${cmd[@]}" 2>/dev/null | head -1 || true
  else
    "${cmd[@]}" 2>/dev/null | head -1 || true
  fi
}

if [ "$CHECK_TOOLS_PHASE" = "pre-carry" ]; then
  log_info "PHASE=pre-carry — the AIR-GAPPED jump box, before 'make bundle-load'."
  log_info "  The 5 CARRIED tools (crane kubectl helm jq yq) are EXPECTED to be missing: the bundle brings them."
  log_info "  What must be right HERE is everything the tarball CANNOT carry (the OS packages)."
fi

printf '\n  %-12s %-10s %-28s %s\n' TOOL STATUS VERSION 'PURPOSE' >&2
printf '  %s\n' "$(printf '%0.s-' {1..100})" >&2

rc=0
missing_required=""
pending_carried=""
while IFS='|' read -r tool req purpose; do
  [ -z "$tool" ] && continue
  if have "$tool"; then
    v="$(tool_version "$tool")"
    [ -z "$v" ] && v="(present)"
    v="$(printf '%s' "$v" | cut -c1-27)"
    printf '  %-12s %-10s %-28s %s\n' "$tool" "OK" "$v" "$purpose" >&2
  else
    case "$req" in
      required)
        printf '  %-12s %-10s %-28s %s\n' "$tool" "MISSING" "-" "$purpose" >&2
        missing_required="${missing_required} ${tool}"; rc=1 ;;
      carried)
        if [ "$CHECK_TOOLS_PHASE" = "pre-carry" ]; then
          # Expected. The bundle brings it. NOT a failure — but say so loudly enough that nobody reads
          # this as "installed".
          printf '  %-12s %-10s %-28s %s\n' "$tool" "CARRIED" "(in the bundle)" "$purpose" >&2
          pending_carried="${pending_carried} ${tool}"
        else
          printf '  %-12s %-10s %-28s %s\n' "$tool" "MISSING" "-" "$purpose" >&2
          missing_required="${missing_required} ${tool}"; rc=1
        fi ;;
      *)
        printf '  %-12s %-10s %-28s %s\n' "$tool" "absent" "-" "(${req}) $purpose" >&2 ;;
    esac
  fi
done <<EOF
$(printf '%s' "$TOOLS")
EOF

echo >&2
if [ "$rc" -ne 0 ]; then
  log_error "MISSING REQUIRED:${missing_required}"
  if [ "$CHECK_TOOLS_PHASE" = "pre-carry" ]; then
    # NEVER say "make deps" here. This box HAS NO INTERNET — that is the entire premise of the phase —
    # and `make deps` downloads. Sending an air-gapped operator to it is the dead end we removed from
    # 10-mirror-pull.sh (require_internet); this is the same dead end, one script over.
    log_error "  These are OS PACKAGES. The bundle CANNOT carry them, and this box cannot download them."
    log_error "  Install them from your lab's INTERNAL package mirror, then re-run:"
    log_error "      apt-get install -y git openssl gettext-base make gawk tar curl   # Debian/Ubuntu"
    log_error "      tdnf install -y git openssl gettext make gawk tar curl           # Photon"
    log_error "  (Do NOT run 'make deps' — it downloads from the internet.)"
  else
    log_error "  Install the toolchain with:  make deps    (mise + scripts/00-install-prereqs.sh)"
    log_error "  Is this the AIR-GAPPED sneakernet jump box, BEFORE 'make bundle-load'? Then crane/kubectl/"
    log_error "  helm/jq/yq are supposed to be absent — the bundle brings them. Re-run as:"
    log_error "      make check-tools CHECK_TOOLS_PHASE=pre-carry"
  fi
else
  if [ -n "$pending_carried" ]; then
    log_info "PRE-CARRY OK — everything the bundle CANNOT bring is present on this box."
    log_info "  Still to arrive from the bundle:${pending_carried}"
    log_info "  Next: carry the tarball + its .sha256 + this repo, then 'make bundle-load'."
    log_info "  AFTER bundle-load, run a plain 'make check-tools' — THAT run must be fully clean, and it"
    log_info "  is what proves this box can actually run the install."
  else
    log_info "all REQUIRED tools present."
    log_info "  'absent' optional tools only degrade diagnostics — they do not block the flow."
    log_info "  NOTE: istioctl is intentionally NOT needed (Istio is driven via helm + kubectl);"
    log_info "        to inspect a mesh you did not install, use 'make istio-preflight'."
  fi
fi
exit "$rc"
