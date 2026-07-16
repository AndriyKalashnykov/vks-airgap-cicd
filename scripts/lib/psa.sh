#!/usr/bin/env bash
# scripts/lib/psa.sh — Pod Security Admission levels for the namespaces WE create.
#
# WHY THIS EXISTS (and why KinD will never tell you):
#
# A VKS guest cluster runs the Pod Security Admission controller and, from VKS/TKr **v1.26**,
# **ENFORCES the `restricted` Pod Security Standard by default** — "pods violating security are
# rejected unless namespace configuration is changed" (Broadcom, "Configure PSA for VKr 1.25 and
# Later"). Only `kube-system`, `tkg-system` and `vmware-system-cloud-provider` are exempt; every
# namespace WE create is not. KinD enforces nothing by default, so a stack that installs cleanly
# locally can have its pods REJECTED outright on a real lab — the classic
# "works-on-KinD / fails-on-the-cluster" class.
#
# So each namespace we create is labelled with the MINIMUM Pod Security Standard its workloads
# actually need. The levels are `.env`-overridable and default to values MEASURED on a live
# cluster (`make psa-check` re-derives them with a server-side dry-run, so they can be checked
# rather than trusted).
#
# `restricted` needs no label on VKS (it is the default) — but we label explicitly anyway, so the
# manifest states its own requirement and does not depend on a cluster-wide default that a
# platform team may have changed (a guest cluster can also set the `podSecurityStandard`
# ClusterClass variable, vSphere 8u3+).
#
# shellcheck shell=bash

[ -n "${__VKS_PSA_SH_LOADED:-}" ] && return 0
__VKS_PSA_SH_LOADED=1

# Per-namespace-role levels. Override any of them in .env.
#   restricted  — the k8s default on VKS; non-root, no caps, seccomp RuntimeDefault
#   baseline    — permits running as root and common non-hostile settings
#   privileged  — unrestricted
: "${PSA_LEVEL_GITEA:=}"
: "${PSA_LEVEL_TEKTON:=}"
: "${PSA_LEVEL_CI:=}"
: "${PSA_LEVEL_APP:=}"
: "${PSA_LEVEL_INGRESS:=}"
: "${PSA_LEVEL_ISTIO_SYSTEM:=}"

# psa_label_namespace <ns> <level>
# Sets enforce + audit + warn to the same level. A missing/empty level is a no-op (so an
# operator can opt out entirely with PSA_LEVEL_X=none on a cluster that manages this centrally).
psa_label_namespace() {
  local ns="$1" level="${2:-}"
  [ -z "$level" ] && return 0
  [ "$level" = "none" ] && { log_info "PSA: leaving namespace '${ns}' unlabelled (level=none)"; return 0; }
  case "$level" in
    restricted|baseline|privileged) ;;
    *) die "PSA level for '${ns}' must be restricted|baseline|privileged|none (got '${level}')" ;;
  esac
  log_info "PSA: labelling namespace '${ns}' enforce=${level}"
  run kubectl label --overwrite namespace "$ns" \
    "pod-security.kubernetes.io/enforce=${level}" \
    "pod-security.kubernetes.io/audit=${level}" \
    "pod-security.kubernetes.io/warn=${level}"
}

# istio_no_inject_label <ns>
# Stamp `istio-injection=disabled` on a namespace WE own, so a platform mesh's sidecar injector
# cannot inject into it.
#
# WHY (the failure it prevents — Backlog B26):
#   `global.proxy.autoInject=disabled` lives in 46-install-istio.sh, which does NOT run when
#   INGRESS_CONTROLLER=istio-existing. So in ATTACH mode injection is the PLATFORM's policy, not
#   ours. A mesh with `sidecarInjectorWebhook.enableNamespacesByDefault=true` injects into our
#   namespaces with no label at all -> the sidecar's `istio-init` initContainer requests NET_ADMIN
#   + NET_RAW -> PSA REJECTS every app pod on a real VKS guest (which enforces `restricted` by
#   default). We run no sidecars by design, so declining injection is not a workaround.
#
# YOU CANNOT PSA YOUR WAY OUT OF THIS. `baseline` does NOT admit an injected pod either: NET_ADMIN
# and NET_RAW are both outside PSS-baseline's allowed-capability list, so only `privileged` would
# take it. Relaxing PSA_LEVEL_APP is the instinctive fix and it does not work.
#
# WHY A LABEL AND NOT THE ANNOTATION: a MutatingWebhookConfiguration's `objectSelector`/
# `namespaceSelector` are LabelSelectors — they match `metadata.labels` and NEVER annotations. The
# label defeats all of istiod's injector rules AT THE API SERVER (each rule requires one of
# `istio-injection NotIn [disabled]`, `In [enabled]`, or `DoesNotExist`), so the webhook is never
# called. That also matters because every rule ships `failurePolicy: Fail`: a rule that MATCHES
# couples our pod creation to the platform istiod's health. Upstream agrees — istiod's own
# gateway template (istiod/files/kube-gateway.yaml) sets inject=false as a LABEL, not an annotation.
istio_no_inject_label() {
  local ns="$1"
  run kubectl label --overwrite namespace "$ns" istio-injection=disabled
}

# ensure_namespace <ns> [psa-level]
# Idempotently create the namespace and apply its PSA level + our no-inject label. Use this
# everywhere instead of a bare `kubectl create namespace`, so no namespace we own can ship without
# a declared level — or be silently injected into by a platform mesh (B26).
#
# The boundary is deliberate: this runs ONLY on namespaces we own and create. `istio-system` is
# never passed here, so attach mode cannot touch the platform's own namespace.
ensure_namespace() {
  local ns="$1" level="${2:-}"
  run bash -c "kubectl create namespace \"$ns\" --dry-run=client -o yaml | kubectl apply -f -"
  psa_label_namespace "$ns" "$level"
  istio_no_inject_label "$ns"
}
