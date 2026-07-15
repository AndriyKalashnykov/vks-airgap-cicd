# Istio "prefer the Gateway API" air-gap CRITICAL — adversary-reviewed fix design (APPLIED 2026-07-15)

**Status:** ✅ **APPLIED 2026-07-15** on branch `fix/istio-gwapi-airgap-critical`. The design below was
DESIGNED + vks-adversary-reviewed (verdict **SHIP-WITH-CHANGES**) on 2026-07-15 and left unapplied when the
owner halted that session. It was then **re-reviewed by `vks-adversary` a second time before applying** (same
verdict, SHIP-WITH-CHANGES) — the second review caught **C1 (HIGH): the `scripts/lib/istio.sh` edit shifted
two `[src: code:…]` citations in `istio.md`, which the provenance gate only range-checks (so it would not
catch the rot)** — the citations were re-pointed (`:219-221`→`:222-224`, `:384-387`→`:387-390`) and verified
by opening the cited lines. C2–C5 folded (sibling `istio-on-vks.md` row, two-factor KinD rationale, placement,
gate-safety). This file remains the durable design record. Backlog: `CLAUDE.md` top handoff marks it done.

## The bug (verified against code + Broadcom Istio Package Reference)

The `docs/vks-services/istio.md` §4 ("Attach: prefer the Gateway API") comparison table + sibling surfaces
grade the **gateway-api** route path *"Air-gap: **free** — pulls proxyv2 from Harbor with no extra config"*
and *"Needs anything from the mesh admin? **No**"*. That grade is TRUE only when **WE** install the mesh
(`INGRESS_CONTROLLER=istio` → `scripts/46-install-istio.sh` sets `global.hub=<Harbor>`, classic routing
against a helm gateway; **not** in the §4 attach table). On an **attached VKS Standard-Package mesh**
(`INGRESS_CONTROLLER=istio-existing` → `scripts/47-attach-istio.sh` → `istio_apply_routes_gwapi`) it is
FALSE: the auto-provisioned `<gw>-istio` proxy (runs in `ISTIO_GWAPI_NAMESPACE`, default `vks-ingress`,
which the tenant owns) takes its `proxyv2` image from the **mesh's** istiod hub, resolved by the injection
webhook from the mesh's install values — not ours.

**Why KinD is green (the "verified" annotations all describe this case):** `HARBOR_PUBLIC_PROJECTS` defaults
`true` → anonymous pull (`scripts/lib/harbor.sh:89`), so the KinD `<gw>-istio` pulled
`<harbor>/cicd/istio/proxyv2` with no secret. Our code creates NO pull-secret in `vks-ingress` — the only
`dockerconfigjson` is `harbor-pull`, created in **app** namespaces by `scripts/70-configure-argocd.sh:386`.

## The adversary's 4 defects in the first-draft correction (fold ALL in)

1. **Do NOT over-correct to a flat "NOT free".** The mesh's proxy registry MAY be anonymous-pull (platform
   mirrored to a public-pull internal registry) → tenant needs nothing. The honest claim is **CONDITIONAL**:
   *not automatic; free iff the mesh's proxy registry is anonymous-pull.*
2. **It is a TWO-object mechanism, not "mesh-admin-owned".** Broadcom: *"a Secret with registry credential
   in the application's namespace, and its name must be specified in `istio.meshConfig.imagePullSecrets`."*
   - **(A)** the `kubernetes.io/dockerconfigjson` Secret, in the pod's ns = `vks-ingress` → **the TENANT
     creates it** (own namespace, self-serviceable).
   - **(B)** that Secret's NAME listed in `istio.meshConfig.imagePullSecrets` (mesh-global data-value) →
     **MESH-ADMIN-owned** (almost certainly already set if their mesh runs air-gapped at all).
3. **Grade `9.0-doc` and DROP "(verified)".** The quote is from the Istio Package Reference at `/9-0/`
   (the `/9-1/` path 404s). Whether `meshConfig.imagePullSecrets` propagates onto the
   **Gateway-API-controller-provisioned** Deployment specifically (vs classic sidecar/gateway injection) is
   **lab-unverified** — the doc says "sidecar **or gateway** injection"; the GW-API path is a plausible but
   unconfirmed instance. Say so.
4. **7th place missed: `k8s/istio/gateway-api.yaml:12-13`** — a manifest comment carrying the same false
   "verified" claim. (And `CLAUDE.md`'s backlog item that *diagnoses* this is not a surface to correct —
   mark it done when this lands.)

**we-install stays correct** — §4 is the "Attach:" table; we-install uses classic routing against a helm
gateway with an explicit `global.hub`, genuinely air-gap-free, and isn't in this table.

## Exact drop-in corrected text (from the adversary)

### `docs/vks-services/istio.md` §4 table — replace the two gateway-api cells

Row **"Needs anything from the mesh admin?"** (gateway-api cell):
```
**For routing, no** — only rights in your own namespaces. **On an air-gapped mesh whose proxy registry needs auth, yes** — a gateway pull-secret (see the Air-gap row).
```

Row **"Air-gap"** (gateway-api cell):
```
**Free only when WE install** (`INGRESS_CONTROLLER=istio`: we set `global.hub=<Harbor>` and the infra project is anonymous-pull). **On an ATTACHED VKS-package mesh: NOT automatic** — the auto-provisioned `<gw>-istio` proxy takes its image from the *mesh's* istiod hub, so pulling depends on the mesh's registry. See the note below.
```

### NOTE to insert immediately under the §4 table

```
> **Air-gap on an ATTACHED mesh — the pull-secret you may owe (9.0-doc).**
> The `<gw>-istio` proxy Istio auto-provisions in `vks-ingress` (`ISTIO_GWAPI_NAMESPACE`)
> takes its image from the **mesh's** istiod hub — whatever the platform team set, NOT your
> Harbor. If that registry requires authentication, the proxy pod **ImagePullBackOffs** and the
> Gateway never programs, unless a `kubernetes.io/dockerconfigjson` Secret — whose name is listed
> in the mesh's `istio.meshConfig.imagePullSecrets` — exists in `vks-ingress`. That is two objects:
>
> | Object | Owner |
> |---|---|
> | the dockerconfigjson **Secret**, in `vks-ingress` (your own namespace) | **you** create it |
> | that Secret's **name** in `istio.meshConfig.imagePullSecrets` (mesh-global) | **mesh admin** (usually already set for the mesh to run air-gapped at all) |
>
> **What to do:** ask the mesh admin — (1) does the mesh pull `proxyv2` from an authenticated
> registry? If anonymous-pull, you need nothing. (2) If authenticated: the imagePullSecret **name**
> in `istio.meshConfig.imagePullSecrets`, plus credentials for that registry. Then create that Secret
> (that exact name) in `vks-ingress` yourself. KinD hides this: there we own the mesh and Harbor is
> anonymous-pull, so no secret is ever needed.
>
> **Grade: 9.0-doc** (Istio *Package Reference*, `/9-0/`; the `/9-1/` page 404s — istio.md src at the
> Air-gap/private-registry row above). Whether `meshConfig.imagePullSecrets` propagates onto the
> **Gateway-API-provisioned** Deployment specifically (vs. classic sidecar/gateway injection) is
> **lab-unverified** — the doc says "sidecar or gateway injection".
```

### `scripts/lib/istio.sh:203-207` — replace the comment block

```
#   gateway-api : needs NOTHING outside our own namespaces for ROUTING. We create a Gateway with
#                 gatewayClassName=istio and Istio AUTO-PROVISIONS the data plane + a LoadBalancer.
#                 AIR-GAP CAVEAT (attach mode): the provisioned proxy takes its image from the MESH's
#                 istiod hub — NOT ours — so on an attached VKS-package mesh with an authenticated
#                 proxy registry it needs a dockerconfigjson Secret in ISTIO_GWAPI_NAMESPACE, named in
#                 the mesh's istio.meshConfig.imagePullSecrets, or the <gw>-istio pod ImagePullBackOffs.
#                 (In our OWN install we set global.hub=<Harbor> + anonymous-pull, so it is free there —
#                 which is the only case the KinD e2e exercises.)
```

### `scripts/48-istio-preflight.sh` — replace lines 71–74 (the "needs NOTHING" block)

```bash
  log_info "  -> INGRESS_CONTROLLER=istio-existing installs nothing and needs no GATEWAY from the mesh admin:"
  log_info "     we create a Gateway in '${ISTIO_GWAPI_NAMESPACE:-vks-ingress}' and HTTPRoutes in our own"
  log_info "     namespaces; Istio auto-provisions the proxy + its LoadBalancer."
  log_warn "  AIR-GAP CAVEAT: the '${ISTIO_GATEWAY_NAME:-vks-uis}-istio' proxy takes its image from the MESH's"
  log_warn "     istiod hub (whatever the platform set), NOT your Harbor. If that registry needs auth it"
  log_warn "     ImagePullBackOffs unless a dockerconfigjson Secret — named in the mesh's"
  log_warn "     istio.meshConfig.imagePullSecrets — exists in '${ISTIO_GWAPI_NAMESPACE:-vks-ingress}'."
  log_warn "     ASK THE MESH ADMIN: (1) is proxyv2 pulled from an authenticated registry? If not, nothing to do."
  log_warn "     (2) if so: the imagePullSecret NAME in istio.meshConfig.imagePullSecrets + its credentials —"
  log_warn "     then create that Secret in '${ISTIO_GWAPI_NAMESPACE:-vks-ingress}' yourself (your own namespace)."
```
Also soften the line-49 comment `"needs NOTHING from the mesh admin"` →
`"needs no gateway from the mesh admin (air-gap pull-secret aside — see the gateway-api branch below)"`.

### `docs/decisions/istio-on-vks.md:196` — replace the Air-gap gateway-api cell, **and delete "(verified)"**
Same content as the istio.md Air-gap cell above; drop the trailing `(verified)`; grade 9.0-doc.
Rewrite **in place** — this `:191-196` block is a **live-state reference table** (describes current routing
behaviour), not a historical decision record, so the live-state rule applies (rewrite, don't append-a-note).

### `k8s/istio/gateway-api.yaml:12-13` (the 7th place) — replace
```
#   * Air-gap: free ONLY when WE install the mesh (we set global.hub=<Harbor>, anonymous-pull). On an
#     ATTACHED VKS-package mesh the proxy inherits the MESH's hub, and if that registry needs auth it
#     needs a dockerconfigjson Secret in this namespace named in the mesh's istio.meshConfig.imagePullSecrets
#     (9.0-doc; see docs/vks-services/istio.md §4). KinD is the free case: we own the mesh + Harbor is public.
```

### `README.md:131-133` — soften, don't duplicate the mechanism (it's an ArgoCD-tenant-request table)
Keep the hostname sentence; change the last clause only:
```
list is ours. The AppProject destination is the only **always-required** tenant request; on an
attached **air-gapped** VKS-package mesh whose proxy registry needs auth, a gateway pull-secret is an
additional one (see [Istio on VKS](docs/vks-services/istio.md#4-attach-prefer-the-gateway-api)).
```

### `docs/diagrams/istio-ingress.puml:38,41` — edit then `make diagrams` + commit the PNG
- Line 38 box: *"Pulls proxyv2 from HARBOR (inherits istiod's hub) → air-gap safe with no extra config"* →
  *"Pulls proxyv2 from the MESH's hub (attach) / our Harbor (we-install). Attached + authed registry → needs a pull-secret in this ns (meshConfig.imagePullSecrets)"*.
- Line 41: drop *"The proxy inherits istiod's hub (pulls from Harbor)"* →
  *"Attach: proxy image comes from the mesh's hub; authed registry needs a pull-secret (see istio.md §4)."*
- Then `make diagrams` (the `diagrams-check` drift gate reds CI otherwise).

## What the adversary did NOT verify (state it, don't paper over)

- **Lab-unverified:** that `istio.meshConfig.imagePullSecrets` actually lands on the
  **Gateway-API-controller-provisioned** Deployment on the VMware-built package (the doc says "gateway
  injection"; the GW-API path is a plausible but unconfirmed instance). Grade the cells accordingly.
- **Not re-fetched:** whether the Istio Package Reference `/9-1/` page still 404s (asserted 2026-07-15). If a
  `/9-1/` version now resolves, re-grade to 9.1-doc.
- **Not run:** any real VKS lab — so how often an attached mesh uses an authenticated proxy registry (i.e.
  how often this caveat bites) is unknown. The correction is written to be true in both branches.

## Apply checklist (next session)
1. Branch from synced `origin/main`.
2. Apply all **7** places above.
3. `make diagrams` + commit the PNG.
4. `make docs-lint && make static-check` green (check-doc-novels + check-vks-provenance; note the new note is
   under the §4 table, not a re-litigation blockquote — but confirm check-doc-novels tolerates the `>`-block).
5. Mark the `CLAUDE.md` backlog item done.
