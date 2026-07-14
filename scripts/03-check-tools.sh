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

# tool|requirement|what it is for
TOOLS="
kubectl|required|talk to the cluster (every step)
helm|required|install Harbor / Istio / Gitea charts
jq|required|Istio discovery, Harbor API, mirror bookkeeping
yq|required|manifest edits in the mirror//install path
envsubst|required|render the \${VAR} tokens in k8s/ manifests (package: gettext)
crane|required|the image-mirror engine (pull/push/validate)
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

printf '\n  %-12s %-10s %-28s %s\n' TOOL STATUS VERSION 'PURPOSE' >&2
printf '  %s\n' "$(printf '%0.s-' {1..100})" >&2

rc=0
missing_required=""
while IFS='|' read -r tool req purpose; do
  [ -z "$tool" ] && continue
  if have "$tool"; then
    # Version probes differ: most take --version, some only a `version` subcommand.
    v="$("$tool" --version 2>/dev/null | head -1 || true)"
    [ -z "$v" ] && v="$("$tool" version 2>/dev/null | head -1 || true)"
    [ -z "$v" ] && v="(present)"
    v="$(printf '%s' "$v" | cut -c1-27)"
    printf '  %-12s %-10s %-28s %s\n' "$tool" "OK" "$v" "$purpose" >&2
  else
    case "$req" in
      required)
        printf '  %-12s %-10s %-28s %s\n' "$tool" "MISSING" "-" "$purpose" >&2
        missing_required="${missing_required} ${tool}"; rc=1 ;;
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
  log_error "  Install the toolchain with:  make deps    (mise + scripts/00-install-prereqs.sh)"
else
  log_info "all REQUIRED tools present."
  log_info "  'absent' optional tools only degrade diagnostics — they do not block the flow."
  log_info "  NOTE: istioctl is intentionally NOT needed (Istio is driven via helm + kubectl);"
  log_info "        to inspect a mesh you did not install, use 'make istio-preflight'."
fi
exit "$rc"
