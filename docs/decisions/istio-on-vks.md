# Istio on VKS: how it is meant to be used, how we use it, and the two scenarios

Status: **ACCEPTED & LANDED** (attach mode shipped; the Broadcom-packaging question is
still open — see "Unverified" below).
Date: 2026-07-12

## The question this answers

> If Istio is already installed on the cluster and we do **not** install it, how do we get
> its credentials, and how do we configure it? And how does that differ from installing it
> ourselves?

Short answers, both proven on a KinD spike against Istio 1.30.2:

1. **There are no Istio credentials.** Istio has no login, no token, no admin API, no UI.
   Access to the mesh is *plain kubectl RBAC*. The only credential-shaped object in the
   picture is a TLS `Secret` referenced by `Gateway.tls.credentialName`, which must live in
   the **gateway's** namespace — so it is something you *request from the mesh admin*, never
   something you "fetch". This is the opposite of Harbor and ArgoCD, which do have real admin
   passwords (`make creds`, `make argocd-password`).
2. **Configuring a mesh you did not install = discovery + RBAC + attaching routes.** You must
   read the gateway's identity off the *live cluster* — above all the `istio:` selector label,
   which is **not** a constant — and then create only your own route objects.

## Scenario 1 — WE install Istio (`INGRESS_CONTROLLER=istio`, the default)

`scripts/46-install-istio.sh`. We own the mesh, so we pin its identity instead of discovering it:

| Piece | Value | Note |
|---|---|---|
| CRDs | helm `istio/base` → `istio-system` | |
| Control plane | helm `istio/istiod` | images from Harbor via `--set global.hub=<harbor>/<project>/istio` |
| Ingress gateway | helm `istio/gateway`, release **`istio-ingressgateway`**, ns `istio-ingress` | `service.type=LoadBalancer` |
| Gateway selector | `istio: ingressgateway` | **only** because we force `--set labels.istio=ingressgateway` |
| Sidecars | none (`global.proxy.autoInject=disabled`) | the gateway proxies straight to each backend's ClusterIP |

Air-gap: `istio/pilot` + `istio/proxyv2` are mirrored into Harbor (`images/images.txt`), and
`ISTIO_VERSION` is kept in lockstep with those tags by Renovate + `make check-image-alignment`.

## Scenario 2 — the platform team ALREADY installed Istio (`INGRESS_CONTROLLER=istio-existing`)

`scripts/47-attach-istio.sh`. We install **nothing**. We discover the mesh and attach only our
routes. Start with `make istio-preflight` — it is read-only and tells you exactly what you have
and what you must ask the mesh admin for.

### What must be discovered (and why assuming is fatal)

**The load-bearing fact:** the `istio/gateway` helm chart derives the gateway workload's
`istio:` label **from the helm release name**. Installing it as release `platform-gw` produces:

```
svc/platform-gw  spec.selector = {"app":"platform-gw","istio":"platform-gw"}
```

So a mesh someone else installed is very unlikely to be labelled `istio: ingressgateway`, and
our old hardcoded `Gateway.spec.selector: {istio: ingressgateway}` **binds nothing** on it.

| What | How (kubectl only) |
|---|---|
| istiod namespace | `kubectl get deploy -A -l app=istiod` |
| Istio version | the running `istiod` image tag — ground truth, never a doc |
| Ingress-gateway Service | a Service exposing port **15021** (the istio-proxy status-port) **and** carrying a `spec.selector.istio` key |
| **Gateway selector label** | `kubectl -n <ns> get svc <svc> -o jsonpath='{.spec.selector.istio}'` |
| Route API flavour | classic `networking.istio.io` vs Kubernetes Gateway API CRDs |
| External address | the gateway Service's LoadBalancer ingress |

The **15021** signature matters: istiod does *not* expose 15021 (it serves 15010/15012/443/15014),
so it cleanly excludes the control plane. A naive `app.kubernetes.io/part-of=istio` label match
picks **istiod** instead — which is exactly the bug the spike's first discovery attempt shipped,
and every route then silently failed to bind.

### Two silent failure modes, with distinct symptoms

Both were reproduced and are now covered by the diagnostics in `98-verify-ingress.sh`:

| Mistake | What the API server does | What the user sees |
|---|---|---|
| `Gateway.spec.selector` matches no workload | **accepts it without any error** | Envoy never gets a `:80` listener → **connection refused** (no HTTP at all) |
| VirtualService names the Gateway by **bare name** from another namespace | accepts it | the name resolves **namespace-locally**, so no route matches → **404** |

Nothing validates that a Gateway's selector matches a real workload. That is why discovery —
not documentation — is the mechanism.

### The three attach shapes (in decreasing order of what you're allowed to do)

1. **You may create a Gateway in the gateway namespace** → default; leave `ISTIO_SHARED_GATEWAY` unset.
2. **The platform owns a shared Gateway you may only reference** → set
   `ISTIO_SHARED_GATEWAY=<ns>/<name>`. We create only VirtualServices. Proven to work against a
   platform-owned wildcard (`hosts: ["*.vks.local"]`) Gateway. `make istio-preflight` asserts the
   shared Gateway actually **admits our three hostnames** — otherwise the VirtualServices are
   accepted and simply never match.
3. **You may not even read the gateway namespace** → ask the mesh admin for
   `ISTIO_GATEWAY_NAMESPACE` / `ISTIO_GATEWAY_SERVICE` / `ISTIO_GATEWAY_LABEL`, set them in `.env`,
   and discovery is skipped entirely.

### The RBAC boundary (this *is* the access model — there is no credential)

Measured with `kubectl auth can-i --as=system:serviceaccount:...` against a namespace-scoped
tenant holding only `virtualservices` rights in its own namespace:

| Action | Allowed? |
|---|---|
| create VirtualServices in its own namespaces | **yes** |
| create a Gateway in the gateway namespace | **no** |
| create a VirtualService in the gateway namespace | **no** |
| **read the gateway Service** (i.e. run discovery at all) | **no** |

So a locked-down tenant cannot even *discover* the mesh — the values must be handed over. That is
the same "the tenant REQUESTS it from the platform admin" shape as ArgoCD cluster registration
(`make argocd-register-guest`).

## Why the VirtualServices moved into the backend namespaces

Previously all VirtualServices lived in the gateway namespace. They now live in **their backend's**
namespace and reference the Gateway as `<gateway-ns>/<gateway-name>`. One layout, both scenarios:

* it is the **only** layout a locked-down tenant can use (they have no rights in the gateway ns);
* it is proven to route correctly (200 + body marker) in every attach shape above;
* backends still need **no sidecar** — istiod knows every k8s Service, so the gateway proxies
  straight to the ClusterIP.

## How this was verified

A KinD spike installed Istio 1.30.2 the way a *platform team* would (ns `platform-ingress`, release
`platform-gw`, no forced labels) and then attached to it as a tenant. Six cases, all landing on
their expected verdict, including two demonstrated REDs:

| Case | Result |
|---|---|
| no routes at all | connection refused |
| **hardcoded `istio: ingressgateway`** against the foreign gateway | **BROKEN** (connection refused; Gateway accepted with no error) |
| discovered selector, Gateway + VS in the gateway ns | **200 + marker** |
| platform owns the Gateway, VS in the app's ns (`<ns>/<name>`) | **200 + marker** |
| VS refs the Gateway by bare name from another ns | **BROKEN** (404) |
| VS-only tenant on a platform-owned wildcard Gateway | **200 + marker** |

`make e2e-kind-istio-existing` is the standing regression test: it installs Istio into KinD under
*foreign* naming, asserts discovery reads it correctly, re-demonstrates both REDs, then runs the
real attach path and the full route verification. (A test that installed Istio *our* way and then
"attached" would prove nothing — our install forces the very label under test.)

### Instrument warning

`kubectl port-forward` to the gateway **dies** when the last Gateway is deleted (Envoy drops its
`:80` listener), so a probe loop that resets routes between cases reads HTTP 000 for everything
afterwards — it "disproved" designs that in fact returned 200. Probe from an **in-cluster curl pod**
against the gateway's ClusterIP: more robust, and the faithful data path.

## Unverified — the Broadcom packaging question (do NOT assert this)

Whether VCF/VKS 9.1 *ships* Istio (as a Supervisor Service, a "VKS Standard Package", or a
`vcf package install`-able add-on) is **not established**. A previous session's note claimed
`vcf package install istio` installs it as a Standard Package on the guest cluster; that claim
traces only to Broadcom 9.1 doc pages which **301-redirect to the 9.0 tree**, and it has not been
confirmed against a real lab or a primary source. It had been baked into
`docs/diagrams/vks-topology.puml` as a node label, where it read as settled fact — that label has
been corrected to describe what the repo actually does.

What this decision does **not** depend on: the attach mode above is generic Istio mechanics and
works regardless of *how* the mesh got there — which is precisely why it was built and validated
without waiting for the Broadcom answer.

Open items for a real VKS 9.1 lab:

* Is Istio offered by Broadcom at all, and if so under what packaging/CLI?
* Pod Security Admission on VKS guest clusters vs. istiod / the gateway pod.
* What supplies `Service type: LoadBalancer` addresses (NSX ALB / Avi), and any IP-pool prerequisite.
* Whether a platform-supplied mesh would use the classic API or the Kubernetes Gateway API.
