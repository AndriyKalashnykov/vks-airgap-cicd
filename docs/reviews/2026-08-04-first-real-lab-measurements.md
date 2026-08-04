# 2026-08-04 — the first measurements against a REAL Supervisor lab

Everything in this repo about a live lab has been *reasoned* until now: `CLAUDE.md` §"Verification
honesty" says the air-gap end-to-end "runs on the live VKS cluster … do not report it 'verified'
without running it against real infrastructure", and `docs/lab-validation-plan.md` exists precisely
because no such lab was reachable.

One now is. These are its measurements. **Nothing here was run in KinD.**

## The instrument, and what it can and cannot settle

A nested VCF/vSphere **9.1** lab built by `~/projects/nested-vsphere-lab` on a local KVM host:
one nested ESXi, a nested VCSA, Supervisor RUNNING, Harbor + ArgoCD installed as **Supervisor
Services**, and a guest VKS cluster `lab/lab-gc1` (`v1.32.10+vmware.1-fips`, CP 1/1 W 1/1) with
Istio installed.

| | this lab | the other lab our docs were written from |
|---|---|---|
| storage | single-host **VMFS**, policy `wcp-vmfs` | **vSAN**, `vsan-default-storage-policy` |
| SSO domain | `vsphere.local` | `wld.sso` |
| networking | VDS + Foundation LB (`vds_foundation_lb`) | not recorded |

⚠️ **Neither column is "the truth" — that is the finding.** `vsan-default-storage-policy` and
`administrator@wld.sso` are a REAL lab's REAL values; they are not invented. They are presented in
`scenario-1.md` as though universal, and a second real lab is what proves they are **parameters**.
The doc fix is not "these are wrong", it is "here are two measured labs, therefore discover yours,
and here is the command".

**CANNOT be settled here:** anything vSAN-specific, NSX, multi-host, or real corporate DNS.

## Findings

### 1. §2's "Browser work — not scriptable" is REPO-SCOPED, not platform-scoped

Supervisor Services can be registered **and** installed entirely over the vCenter REST API. The
lab automation does exactly that, no browser:

```
POST /api/vcenter/namespace-management/supervisor-services                      # register
POST /api/vcenter/namespace-management/clusters/{moid}/supervisor-services      # install on a Supervisor
GET  /api/vcenter/namespace-management/supervisor-services/{id}/versions
GET  /api/vcenter/namespace-management/supervisors/{sup}/supervisor-services/{id}
```

MEASURED in THIS repo — the capability is absent, which is why the sentence was written:

```
"supervisor-services"   -> 6 hits, ALL in docs/, ZERO in code
"namespace-management"  -> 0 hits anywhere
install-harbor / install-argocd  -> KinD only (scripts/06-install-harbor.sh)
```

**Action:** port the capability, then rewrite §2/§3 scripted-first. **KEEP the browser flow** — it
stays the documented fallback and the web-UI path is still wanted (owner, 2026-08-04). This is a
FEATURE plus a doc rewrite, not a doc edit.

### 2. §2's `sed` warning is correct and UNDER-TREATED — there is a one-line precondition

§2 says "`sed` silently changes nothing on a non-match — re-check if your version differs". True,
and a human instruction. The lab automation records what actually happens, MEASURED:

> `yq '.k = v'` **CREATES** a missing key. Rendering a data-values file whose expose keys had been
> renamed **appended** `enableNginxLoadBalancer: true` and `enableContourHttpProxy: false` as two
> new dead top-level keys, left the real key untouched, and shipped **a Harbor with no reachable
> ingress and no error** — while every downstream assertion stayed green.

Its remedy, RED-proven both directions (shipped file → rc=0; renamed, half-renamed, EMPTY, and
bare-scalar files → rc≠0):

```bash
yq -e 'has("enableNginxLoadBalancer") and has("enableContourHttpProxy")' "$src" >/dev/null \
  || die "the shipped data-values no longer carries BOTH expose keys — the vendor changed the
          expose mechanism. Setting them now APPENDS two dead keys and leaves Harbor with no
          reachable ingress."
```

**On 2.14.3 the keys are still live** (guard passes; `harbor-nginx` LoadBalancer is up), so §2's
version note is currently accurate. Put the precondition in §2 in place of "re-check by hand".

### 3. `lab-validation-plan.md` STEP 13 — ANSWERED. The README's central claim HOLDS.

Step 13 is flagged "the biggest open risk in the repo". Run against `lab/lab-gc1`:

| probe | result |
|---|---|
| Gateway-API CRDs present? | **YES** — `gatewayclasses`, `gateways`, `httproutes`, `referencegrants` |
| `GatewayClass istio` Accepted | **True** (a second class `istio-remote` also exists) |
| shared gateway on 15021 — **COUNT** | **0** — really off; the 2+ ambiguity case does NOT occur |
| `istio-cni-node` | present, 2/2 ready |
| carvel packaging API | present |
| gateway-api `ValidatingAdmissionPolicy` | **none at all** ("No resources found") |
| istiod image | `projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-…` |

**So the README does NOT need rewriting** and no `ISTIO_SHARED_GATEWAY` flow is required. The plan
said "if the Gateway-API CRDs are absent, our README's central tenant claim is wrong".

**The 15021 count is the item the plan says "changes shipping-code behaviour":** it is **0**, so
`scripts/lib/istio.sh`'s refuse-to-guess branch is not reachable on this lab.

### 4. B26 — CLOSED, not deferred. The anti-injection defence WORKS.

The plan expected "most likely Istio is not installed at all". It **is**. The shipped
`istio-sidecar-injector` selectors are exactly the ones the defence targets:

```
namespace.sidecar-injector.istio.io
  namespaceSelector: istio-injection In [enabled]
  objectSelector:    sidecar.istio.io/inject NotIn [false]
```

So a namespace labelled `istio-injection=disabled` and a pod labelled
`sidecar.istio.io/inject=false` are both honoured — the defence is **not** a no-op, and
istio-init's `NET_ADMIN` (which PSA `restricted` rejects) is suppressed as designed.

### 5. B2 — the pinned `GATEWAY_API_VERSION=v1.5.1` FIGHTS kapp

```
httproutes.gateway.networking.k8s.io
  bundle-version: v1.0.0
  labels: kapp.k14s.io/app, kapp.k14s.io/association     <- owned by the CARVEL PACKAGE
```

Two problems with SSA-force-applying our pin:

1. The CRDs are **kapp-owned** — installed by the Istio package, not by a VKS add-on manager and
   not by us. `istio_ensure_gwapi_crds` would up-version a CRD it does not own.
2. Only **four** CRDs exist (no `grpcroutes`/`tlsroutes`/`tcproutes`) — the standard channel,
   narrower than a v1.5.1 pin implies.

**Do not "fix" this by widening the pin.** The reconcile-with-the-owner options the plan already
names (respect the installed version, or set the documented `unmanaged` opt-out deliberately) are
the ones to weigh, and the owner is kapp.

## What is NOT yet measured

The pipeline halves of `scenario-1.md` — §5 preflight, §6 Harbor CA, §7 robot, §8 the Supervisor
kubeconfig, §9 install/verify, §11 ingress — are **untouched**. They need the mirror (~34 images)
and a real Gitea/Tekton install into the guest cluster. That run is approved and is the next piece
of work; it is the only thing that can validate them.

Also open: `.env.example` should carry this lab's values as working defaults while the prose stays
parameterised (owner, 2026-08-04) — so a reader gets something that runs without the doc claiming
their lab looks like ours.

## Method note, because it bit twice

Two near-misses while gathering the above, both the same shape — **a narrow instrument reading as
an absence**:

* `kubectl get svc -A | grep -iE 'harbor|LoadBalancer' | head -8` truncated before `harbor-nginx`,
  and I nearly recorded "Harbor is ClusterIP-only, not exposed". It has a LoadBalancer at
  `192.168.101.130`.
* the first `supervisor-services` grep covered only `scripts/` and `Makefile` and returned nothing;
  the repo-wide grep found 6 hits (all docs). The conclusion survived, the evidence did not.

Widen the grep before believing a zero.
