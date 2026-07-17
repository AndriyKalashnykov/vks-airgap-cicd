#!/usr/bin/env bash
# check-pod-inject-label.sh — every workload WE ship must decline sidecar injection in its own POD
# TEMPLATE, unless the line carries a reasoned `# inject-ok: <why>` marker.
#
# WHY THIS IS A GATE AND NOT A RULE:
#   In ATTACH mode (INGRESS_CONTROLLER=istio-existing) injection is the PLATFORM's policy, not ours:
#   46-install-istio.sh's `global.proxy.autoInject=disabled` never runs. A platform mesh with
#   `sidecarInjectorWebhook.enableNamespacesByDefault=true` injects into our namespaces, the sidecar's
#   istio-init initContainer requests NET_ADMIN + NET_RAW, and PSA REJECTS the pod on a real VKS
#   guest (which enforces `restricted` by default). We run no sidecars by design.
#
#   YOU CANNOT PSA YOUR WAY OUT: `baseline` does not admit it either — NET_ADMIN and NET_RAW are both
#   outside PSS-baseline's allowed capabilities. Only `privileged` would take it.
#
# WHY THE POD LABEL AND NOT JUST THE NAMESPACE ONE:
#   The pod label is INDEPENDENTLY SUFFICIENT and RACE-FREE, and the namespace label is neither.
#   Rendered from the PINNED chart (ISTIO_VERSION=1.30.3), the injector's four rules carry these
#   objectSelectors:
#       rev.namespace.sidecar-injector   obj: sidecar.istio.io/inject NotIn ['false']
#       rev.object.sidecar-injector      obj: sidecar.istio.io/inject NotIn ['false']
#       namespace.sidecar-injector       obj: sidecar.istio.io/inject NotIn ['false']
#       object.sidecar-injector          obj: sidecar.istio.io/inject In    ['true']
#   `inject: "false"` fails NotIn['false'] for the first three and In['true'] for the fourth — all
#   four defeated on the OBJECT alone, whatever the namespace says. That matters because ArgoCD's
#   `CreateNamespace=true` (k8s/argocd/application.yaml:32) can create a namespace and sync pods into
#   it before any installer labels it; the pod label has no such window.
#
#   GRADE: upstream-1.30.3-rendered. This header ONCE claimed the selectors were "identical on
#   1.28.2, the VKS line". That was a FALSE FACT — `bundle/charts/` holds no 1.28.2 chart, so it
#   cannot have been rendered, and lib/psa.sh:95 grades that exact question UNVERIFIED-BY-US
#   ("The lab runs VMware's 1.28.2+vmware.1-vks.1, which we cannot render"). It also conflated
#   upstream 1.28.2 with VMware's +vmware.1-vks.1 build, which is a different artifact again.
#   Whether Broadcom patched the injector is settled by ONE command on a lab:
#       kubectl get mutatingwebhookconfiguration -o yaml | grep -A8 namespaceSelector
#   Note also that `bundle/charts/` is gitignored, so "rendered from the pinned chart" is not
#   reproducible by CI or another operator — it is an operator-local measurement, graded as such.
#
#   It must be a LABEL, not an annotation: objectSelector is a LabelSelector and never matches
#   annotations. Upstream agrees — istiod's own gateway template (istiod/files/kube-gateway.yaml:62)
#   sets inject=false as a label on the gateway pod it generates.
#
# EXEMPTION: `# inject-ok: <why>` on the pod-template line. A reasoned per-line marker, never a
# filename allowlist — an allowlist hides the NEXT workload added to an already-listed file.
#
# SCOPE, stated so a green is not over-read: this sees only IN-TREE templates. Harbor / ArgoCD /
# Tekton / istiod pods come from upstream manifests and charts and are outside it — they are covered
# by their namespace's label instead (check-namespace-labelled.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/os.sh
. "${SCRIPT_DIR}/lib/os.sh"
cd "$REPO_ROOT" || die "cannot cd to repo root"

command -v python3 >/dev/null 2>&1 || die "check-pod-inject-label: python3 is required (YAML parsing)."

# Parse rather than grep: a grep for the label cannot tell a POD-TEMPLATE label from a top-level
# metadata label (the wrong one is a no-op — objectSelector matches the POD), and cannot tell a
# label from an annotation (an annotation is silently useless here). Both mistakes look identical
# to a grep and neither is caught by a green build.
# shellcheck disable=SC2016  # single quotes are REQUIRED: this is a python program, not shell — the
# $ and % must reach python unexpanded. (An apostrophe inside would terminate the string; there is
# deliberately none, and that is noted at the one comment that wanted one.)
out="$(git ls-files 'k8s/*.yaml' 'k8s/**/*.yaml' 'k8s/*.yml' 'k8s/**/*.yml' 'deploy/*.yaml' 'deploy/**/*.yaml' 'deploy/*.yml' 'deploy/**/*.yml' 2>/dev/null | sort -u | python3 -c '
import sys, yaml
KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}
checked = 0
bad = []
for path in (l.strip() for l in sys.stdin if l.strip()):
    raw = open(path).read()
    try:
        docs = list(yaml.safe_load_all(raw))
    except Exception as e:
        print("PARSE\t%s\t%s" % (path, e)); continue
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") not in KINDS:
            continue
        name = (d.get("metadata") or {}).get("name", "?")
        # The pod template lives at .spec.template for everything except CronJob.
        spec = d.get("spec") or {}
        tmpl = spec.get("template")
        if d.get("kind") == "CronJob":
            tmpl = ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template")
        tmpl = tmpl or {}
        labels = ((tmpl.get("metadata") or {}).get("labels") or {})
        annos  = ((tmpl.get("metadata") or {}).get("annotations") or {})
        checked += 1
        val = labels.get("sidecar.istio.io/inject")
        # The line the workload is declared on, so the `# inject-ok:` marker can be LINE-scoped
        # rather than file-scoped (a file-scoped marker IS the filename allowlist this gate rejects:
        # one marker would exempt every workload in the file, including the next one added).
        lineno = 0
        for i, ln in enumerate(raw.splitlines(), 1):
            if ln.strip() in ("kind: %s" % d.get("kind"),):
                lineno = i
        # A k8s label value is a STRING. `inject: false` (unquoted) parses to a Python bool and is
        # INVALID to the apiserver. Accepting it would repeat the rationale-failure of this very
        # gate one level down: we parse instead of grep because a grep cannot tell a label from an
        # annotation, so a parse that cannot tell a string from a bool is the same blindness.
        # (No apostrophes in this block: it lives inside a single-quoted python3 -c string, and one
        # apostrophe terminates it. That broke the gate once already.)
        if val is False:
            bad.append("%s\t%s/%s\t%d\tsidecar.istio.io/inject is the YAML BOOL false, not the STRING \"false\" — a k8s label value must be a string, so the apiserver rejects this and the control silently does not exist" % (path, d.get("kind"), name, lineno))
            continue
        if isinstance(val, str) and val.lower() == "false":
            continue
        # An ANNOTATION is a silent no-op — objectSelector is a LabelSelector. Name it explicitly.
        if str(annos.get("sidecar.istio.io/inject")).lower() == "false":
            bad.append("%s\t%s/%s\t%d\tinject=false is an ANNOTATION, not a LABEL — objectSelector never matches annotations, so it is a NO-OP" % (path, d.get("kind"), name, lineno))
        else:
            bad.append("%s\t%s/%s\t%d\tno sidecar.istio.io/inject=\"false\" in the pod template" % (path, d.get("kind"), name, lineno))
print("CHECKED\t%d" % checked)
for b in bad: print("BAD\t%s" % b)
')"
rc=$?
[ "$rc" -eq 0 ] || die "check-pod-inject-label: the YAML parser failed (rc=$rc) — a green here would mean nothing."

if grep -q '^PARSE' <<<"$out"; then
  log_error "check-pod-inject-label: a manifest failed to parse — the gate cannot see it, so it cannot pass:"
  grep '^PARSE' <<<"$out" | sed 's/^PARSE\t/  - /'
  exit 1
fi

checked="$(grep '^CHECKED' <<<"$out" | cut -f2)"
# A gate that scanned nothing is BROKEN, not green — k8s/gitea/gitea.yaml always carries a Deployment.
[ "${checked:-0}" -gt 0 ] || die "check-pod-inject-label: parsed 0 workloads — git ls-files/pathspec is broken (k8s/gitea/gitea.yaml must always match)."

# Apply the `# inject-ok:` exemption by re-reading the offending file for a marker.
HITS=(); exempt=0
# The marker must sit on (or within 2 lines of) the WORKLOAD'S OWN `kind:` line — never merely
# somewhere in the file. A file-scoped grep is the filename allowlist this gate's header rejects:
# proven by an adversary, one legitimate marker + an unrelated Deployment appended => RC=0, "1
# exempt", the second workload silently unguarded.
while IFS=$'\t' read -r _ path obj lineno why; do
  [ -n "${path:-}" ] || continue
  window=""
  if [ "${lineno:-0}" -gt 0 ]; then
    window="$(sed -n "$((lineno > 2 ? lineno - 2 : 1)),$((lineno + 2))p" "$path" 2>/dev/null)"
  fi
  if grep -q '# inject-ok:' <<<"$window"; then exempt=$((exempt+1)); continue; fi
  HITS+=("$path:${lineno}: $obj — $why")
done < <(grep '^BAD' <<<"$out")

if [ "${#HITS[@]}" -gt 0 ]; then
  log_error "check-pod-inject-label: ${#HITS[@]} workload(s) do not decline sidecar injection (checked ${checked}; ${exempt} exempt):"
  for h in "${HITS[@]}"; do printf '  - %s\n' "$h"; done
  echo
  echo "  Add to the POD TEMPLATE's labels (spec.template.metadata.labels):"
  echo "      sidecar.istio.io/inject: \"false\""
  echo "  A LABEL, not an annotation — the injector's objectSelector is a LabelSelector and never"
  echo "  matches annotations. This repo runs no sidecars by design; in attach mode an injected pod"
  echo "  gets istio-init (NET_ADMIN + NET_RAW) and PSA rejects it on a real VKS guest — and neither"
  echo "  'restricted' nor 'baseline' will admit it."
  echo "  If a workload genuinely must be injected, mark it: '# inject-ok: <why>'."
  exit 1
fi

log_info "check-pod-inject-label: OK — ${checked} workload(s) decline sidecar injection in their pod template (${exempt} exempt)."
