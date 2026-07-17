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
#   ⚠️ THE NET_ADMIN HALF IS CONDITIONAL, and this comment used to state it flatly. Rendered:
#       capabilities:
#       {{- if not .Values.pilot.cni.enabled }}
#           add: [NET_ADMIN, NET_RAW]
#       {{- end }}
#   A platform mesh running **istio-cni** injects a sidecar with NEITHER capability, and in attach
#   mode that is THEIR choice — `grep -rn cni scripts/` returns nothing; we neither set nor check it.
#   So "PSA rejects every app pod" is true for a NON-CNI mesh and UNVERIFIED-BY-US for the lab's.
#   Stated flatly it invites the wrong inference — "the platform runs CNI, so B26 is moot, delete
#   the label". It is not moot: we run no sidecars BY DESIGN, so declining injection is right either
#   way, and `failurePolicy: Fail` couples our pod creation to their istiod's health regardless.
#
# YOU CANNOT PSA YOUR WAY OUT OF THIS. `baseline` does NOT admit an injected pod either: NET_ADMIN
# and NET_RAW are both outside PSS-baseline's allowed-capability list, so only `privileged` would
# take it. Relaxing PSA_LEVEL_APP is the instinctive fix and it does not work.
#
# WHY A LABEL AND NOT THE ANNOTATION: a MutatingWebhookConfiguration's `objectSelector`/
# `namespaceSelector` are LabelSelectors — they match `metadata.labels` and NEVER annotations. So
# the decision happens AT THE API SERVER and the webhook is never called, which matters because
# every rule ships `failurePolicy: Fail`: a rule that MATCHES couples our pod creation to the
# platform istiod's health. Upstream agrees — istiod's own gateway template
# (istiod/files/kube-gateway.yaml) sets inject=false as a LABEL, not an annotation.
#
# THE MECHANISM — RENDERED from the PINNED chart, not recalled. This comment has been wrong TWICE,
# in OPPOSITE directions, which is why the full table is here now:
#   #290 claimed "each rule requires one of `NotIn [disabled]`, `In [enabled]`, or `DoesNotExist`".
#   Its correction over-shot to "There is NO `NotIn` rule" — ALSO false. There is no
#   `NotIn [disabled]`; there IS `NotIn ['false']`, on the objectSelector, in three rules. The
#   correction omitted every objectSelector row — exactly the half where the POD label works.
#
# Rendered under `sidecarInjectorWebhook.enableNamespacesByDefault=true`, DELIBERATELY: that is the
# HAZARD config this comment exists to explain. The base chart renders only FOUR rules, under which
# nothing matches an unlabelled pod at all — so a table rendered from the base cannot show how the
# hazard fires, and a GATE built by rendering the base is vacuous over the exact case it is for.
#
#   rev.namespace  ns  istio.io/rev                In           ['default']
#                  ns  istio-injection             DoesNotExist
#                  obj sidecar.istio.io/inject     NotIn        ['false']
#   rev.object     ns  istio.io/rev                DoesNotExist
#                  ns  istio-injection             DoesNotExist
#                  obj sidecar.istio.io/inject     NotIn        ['false']
#                  obj istio.io/rev                In           ['default']
#   namespace      ns  istio-injection             In           ['enabled']
#                  obj sidecar.istio.io/inject     NotIn        ['false']
#   object         ns  istio-injection             DoesNotExist
#                  ns  istio.io/rev                DoesNotExist
#                  obj sidecar.istio.io/inject     In           ['true']
#                  obj istio.io/rev                DoesNotExist
#   auto           ns  istio-injection             DoesNotExist         <-- ONLY under the knob.
#                  ns  istio.io/rev                DoesNotExist             THIS IS THE HAZARD.
#                  ns  kubernetes.io/metadata.name NotIn ['kube-system','kube-public',
#                                                         'kube-node-lease','local-path-storage']
#                  obj sidecar.istio.io/inject     DoesNotExist
#                  obj istio.io/rev                DoesNotExist
#
# TWO INDEPENDENT DEFEATS — the redundancy IS the design:
#   - NAMESPACE label (this file): four rules need `istio-injection` ABSENT, so ANY value defeats
#     them — `disabled` is not magic; `namespace` needs exactly `enabled`, so any other value
#     defeats it too.
#   - POD label `sidecar.istio.io/inject: "false"` (k8s/*, deploy/*, enforced by
#     check-pod-inject-label.sh): fails `NotIn['false']` for three, `In['true']` for `object`,
#     `DoesNotExist` for `auto` — all five defeated on the OBJECT alone, whatever the namespace
#     says, with no window for ArgoCD's CreateNamespace=true to sync a pod before its ns is labelled.
#
# NotIn MATCHES AN ABSENT KEY — the false-green trap in any hand-rolled evaluator.
# apimachinery/pkg/labels/selector.go:
#     case selection.NotIn, selection.NotEquals:
#         val, exists := ls.Lookup(r.key); if !exists { return true }   // ABSENT => MATCH
#     case selection.In, selection.Equals:  if !exists { return false }
# So for an UNLABELLED pod `NotIn['false']` PASSES, and only the namespaceSelector saves us. Read
# "the pod label defeats three via NotIn" as true FOR A LABELLED POD — never as "that row protects
# us generally". And an `Exists` rule would NOT be safe: our label makes the key exist, and MATCH.
# A gate here must check the OPERATOR, not merely that a rule mentions `istio-injection`.
#
# A SECOND GATE EXISTS AND IS NOT A SUBSTITUTE. `global.proxy.autoInject` sets `policy:` in the
# istio-sidecar-injector ConfigMap, evaluated INSIDE istiod's /inject AFTER the selector matched
# (rendered: knob-only -> auto-rule=1/policy=enabled; BOTH -> 1/disabled — the webhook FIRES and
# istiod DECLINES). In attach mode it is the PLATFORM's knob, not ours — and even at `disabled` the
# `auto` rule still MATCHES, so `failurePolicy: Fail` still couples our pod creation to the platform
# istiod's health. The label is what stops the match. The 4-cell matrix lives in
# 90-e2e-istio-existing.sh, where it is the fixture's rationale.
#
# Grade: upstream-1.30.3-rendered (the pin, .env.example). This previously self-graded 1.30.2 while
# the repo pinned 1.30.3 — a rendered claim citing a version we do not install. The lab runs
# VMware's `1.28.2+vmware.1-vks.1`, which we cannot render — whether it ships these selectors AND
# this `policy` field is UNVERIFIED-BY-US (docs/lab-validation-plan.md). One lab visit settles both:
#   kubectl get mutatingwebhookconfiguration -o yaml | grep -A8 namespaceSelector
#   kubectl -n istio-system get cm istio-sidecar-injector -o jsonpath='{.data.config}' | grep policy
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
