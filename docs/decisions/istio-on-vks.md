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

```text
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

## What Broadcom actually ships (researched 2026-07-12 — and it corrects an earlier correction)

**Istio IS offered on VKS, as a Standard Package installed into the GUEST cluster.** An earlier
session claimed this; a mid-session correction in this very document called it "unverified" and told
readers not to assert it. That correction was **wrong** — primary Broadcom documentation confirms
the package. Recorded plainly because a retracted retraction is exactly the kind of thing that
otherwise rots into folklore.

| Fact | Value | Provenance |
|---|---|---|
| Packaging | Carvel **Standard Package**, installed into the **guest/workload cluster** (not the Supervisor) | Broadcom TechDocs, "Istio Package Reference" |
| Package name | `istio.kubernetes.vmware.com` | Broadcom TechDocs |
| Versions | VMware-built, e.g. `1.25.3+vmware.1-vks.1`, `1.28.2+vmware.1-vks.1` | Broadcom TechDocs |
| Install (package CLI) | `vcf package install istio -p istio.kubernetes.vmware.com -v <ver> --values-file istio-data-values.yaml -n istio-installed` | Broadcom TechDocs |
| Install (VCF 9 addon CLI) | `vcf addon install create istio --cluster-name $VKS_CLUSTER -y`, then `vcf addon install update istio --cluster-name $VKS_CLUSTER -f values.yaml` | VMware VCF blog, "Istio on VKS: A Walkthrough" |
| Control-plane namespace | `istio-system` (configurable) | package reference |
| **Ingress gateway** | **DISABLED by default** (`istio.gateways.ingress.enabled: false`); namespace `istio-ingress` when enabled | package reference |
| Data plane | sidecar by default; **ambient** supported (needs `istioCNI.enabled: true`) | package reference |
| Air-gap / private registry | `meshConfig.imagePullSecrets` — "the secrets to access the private registry must be provided in the air-gapped environment" | package reference |
| **Route API Broadcom demonstrates** | the **Kubernetes Gateway API** — `gatewayClassName: istio`, which auto-provisions a gateway whose Service is `<gateway-name>-istio`, type LoadBalancer, **in the app's own namespace** | VMware VCF blog walkthrough |

**Provenance caveat (verified live, 2026-07-12):** the 9.1 techdoc URLs **301-redirect to the 9.0
tree** — confirmed by an actual `301 Moved Permanently` on fetch. The blog walkthrough targets VKS
3.5 (March 2025). So all of the above is **documented for 9.0 / VKS 3.5 and inferred for 9.1**;
re-verify against a real 9.1 lab before treating any version string as exact.

### What this means for us (two consequences, one of them a real gap)

1. **The attach mode is more relevant, not less.** A VKS operator installs Istio via the package —
   so on a real lab the mesh is emphatically *not* ours, and `INGRESS_CONTROLLER=istio-existing` is
   the correct mode. Everything above about discovery, RBAC, and "there are no credentials" still
   holds: the package installs upstream-derived Istio, so its mechanics are the mechanics we proved.
2. **We now support BOTH route APIs, and prefer the Gateway API** (this was the gap the research
   exposed; it is closed). See the next section.

## Route API: Gateway API (preferred) or classic — auto-detected

`ISTIO_ROUTE_API` = `auto` (default) | `gateway-api` | `classic`. Auto prefers the **Kubernetes
Gateway API** whenever Istio is an **Accepted GatewayClass**, else falls back to classic.

| | **gateway-api** (preferred) | **classic** |
|---|---|---|
| What we create | a `Gateway` (`gatewayClassName: istio`) in `ISTIO_GWAPI_NAMESPACE` + one `HTTPRoute` per UI in its backend's namespace | a `Gateway` bound by the discovered `istio:` selector + `VirtualService`s |
| Needs a pre-existing gateway workload? | **No** — Istio **auto-provisions** the proxy *and* its LoadBalancer | **Yes** — and its selector label must be discovered |
| Needs anything from the mesh admin? | **No** — only rights in our own namespaces | usually yes (rights in the gateway ns, or a shared Gateway to reference) |
| Air-gap | **free** — the auto-provisioned proxy inherits istiod's image hub, so it pulls `<harbor>/…/istio/proxyv2` with no extra config (verified) | the platform's gateway already pulls from wherever it was configured |

Why this matters on a real VKS cluster: the Standard Package ships its shared ingress gateway
**disabled by default**, so the classic path may have *nothing to bind to* — while the Gateway-API
path works regardless, and is what Broadcom's own walkthrough uses.

**Verified on KinD against a platform-installed mesh** (both legs, each exclusive — switching APIs
deletes the routes we created with the other one, because leftovers silently serve the same
hostnames and would fake a successful switch):

| Leg | Address | Result |
|---|---|---|
| gateway-api | **172.18.0.6** — the LB Istio auto-provisioned for our Gateway (`Programmed=True`) | all three UIs HTTP 200 + their own body markers |
| classic | **172.18.0.5** — the platform's shared gateway | all three UIs HTTP 200 + their own body markers |

### A false green this produced, and the fix

`INGRESS_LB_IP` is **our own published state** — every install/attach writes the address it resolved
into `.env.kind`, `load_env` sources it back, and `44-install-ingress.sh` *exports* it before
`exec`ing the attach script. So it is always set after any previous run, and is indistinguishable
from a deliberate operator override. Consuming it as an "override" made the Gateway-API attach report
the **previous classic gateway's IP**, and the route check then passed *through the classic routes
still left in the cluster* — a green that proved nothing. The attach path now always **resolves** the
address of the gateway it is actually attaching to; a genuine override lives in its own variable
(`INGRESS_LB_IP_OVERRIDE`) that nothing auto-publishes.

Still open for a real 9.1 lab: Pod Security Admission vs. istiod/gateway pods; what supplies the
LoadBalancer address (NSX ALB / Avi) and any IP-pool prerequisite; exact 9.1 package version strings.
