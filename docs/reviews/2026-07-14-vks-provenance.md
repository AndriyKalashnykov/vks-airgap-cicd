# VKS-services provenance — 2026-07-14

> **`CLAUDE.md:LINE` refs below are against `CLAUDE.md@28631c5`**, before the 2026-07-16 prune removed
> its dated handoff sections. Read them with `git show 28631c5:CLAUDE.md`. They are deliberately NOT
> renumbered: this file is an archive of what was checked, when.

Owner's instruction: *"a grade cannot be that way — we need exact sources and referenceable facts."*
Every graded fact in `docs/vks-services/*.md` was handed to an agent tasked with finding a **resolvable**
source (URL + retrieval date + the quoted sentence; or a command + its real output; or `FILE:LINE`), or
declaring **NOT_ESTABLISHED** with what it tried. Load-bearing findings were then handed to a second
agent whose job was to **refute the citation**.

> **`docs/vks-services/argocd.md` IS NOT COVERED HERE** — its citation agent died on an API rate limit.
> Its 9 graded facts remain ungrounded. Re-run it.

**The Broadcom redirect trap:** 9.1 doc URLs 301 to the 9.0 tree, so `url_requested` and `url_landed`
are recorded separately. Where they differ, the fact is 9.0 content read as 9.1 — and that redirect is
itself the evidence for the grade.

| doc | facts | load-bearing |
|---|---|---|
| `/home/andriy/projects/vks-airgap-cicd/docs/vks-services/README.md` | 11 | 8 |
| `/home/andriy/projects/vks-airgap-cicd/docs/vks-services/istio.md — citation audit, 2026-07-14 (READ-ONLY; no files touched)

## Headline

Most of the doc holds up, and several facts I expected to be soft are now **primary-sourced verbatim** (package name, install command, ingress-gateway-off-by-default, PSA enforce=restricted at v1.26, the 15021 signature, the bare-name-404 mechanism, "Istio does not ship the Gateway API CRDs"). But the audit found **one CRITICAL, load-bearing contradiction** and **two grades that are claims rather than evidence**.

## 1. CRITICAL — the "Attach: prefer the Gateway API" table (istio.md:81-82) is CONTRADICTED by Broadcom for the exact mesh we attach to

The doc says the Gateway API path needs **nothing from the mesh admin** and that air-gap is **"free … pulls proxyv2 from Harbor with no extra config"**. That grade came from **our own helm-installed Istio**, where *we* set `global.hub=<harbor>` (`scripts/46-install-istio.sh:99,112`; the claim is recorded at `scripts/lib/istio.sh:206-207`). On a **VKS Standard Package** mesh — the one `istio-existing` exists for — Broadcom's own reference says the opposite:

> "Enabling Istio sidecar or **gateway injection** requires a Secret with registry credential in **the application's namespace**, and its name must be specified in **istio.meshConfig.imagePullSecrets**."
> — Istio Package Reference (landed on the **9-0** tree), retrieved 2026-07-14

`istio.meshConfig.imagePullSecrets` is a **mesh data-values** key — owned by whoever installed the package, i.e. **the mesh admin**. So on a real air-gapped VKS lab the tenant needs BOTH: (a) a pull Secret in their own app namespace (we already create `harbor-pull` there — CLAUDE.md finding #5), AND (b) **the mesh admin to have listed that Secret's name in `istio.meshConfig.imagePullSecrets`**. If (b) is missing, the auto-provisioned `<gw>-istio` proxy pod cannot pull `proxyv2` and the Gateway never programs — a failure that KinD can never show, because on KinD *we* are the mesh admin.

**Consequence on a real lab:** an operator following this table will not request (b), and the gateway will sit un-Ready with an ImagePullBackOff on a pod they did not create.
**Fix:** split the air-gap row by mesh ownership (our helm install = free; VKS package = needs the imagePullSecrets ask), flip the "needs anything from the mesh admin?" cell for the VKS-package case, and have `make istio-preflight` print the `istio.meshConfig.imagePullSecrets` ask alongside the existing ones.

## 2. The redirect is WORSE than the doc records — there is no 9.1 Istio page at all

The doc (and CLAUDE.md) say "9.1 URLs → 9.0 tree". Measured today:

- requested `.../vcf/vcf-service-administration-and-development/**9-1**/.../istio-package-reference.html` → **HTTP 404** (not a redirect).
- requested `.../vcf/vsphere-supervisor-services-and-standalone-components/**latest**/.../istio-package-reference.html` → **301 Moved Permanently** → `.../vcf-service-administration-and-development/**9-0**/...`.

So **`latest` IS `9-0`** for VKS standard packages, and the 9-1 path does not exist. Every "9.0-doc (inferred for 9.1)" grade in this file is therefore correct *and un-improvable from the web* — the 9.1 content is simply not published. Worth stating explicitly so no future session burns time hunting for it.

## 3. Two grades that are claims, not evidence

- **The RBAC table (istio.md:116-126), graded "KinD-verified"**: there is **no `--as=` anywhere in `scripts/`** (grepped). The only trace is prose in `docs/decisions/istio-on-vks.md:98`. It is an unrecorded one-off manual measurement presented as a verified table. It is load-bearing (it justifies "set `ISTIO_GATEWAY_*` in `.env` and skip discovery"). Either capture the four `kubectl auth can-i --as=…` commands + output, or wire them into `90-e2e-istio-existing.sh`.
- **The PSA quote (istio.md:135)**: the substance is *fully confirmed*, but the quoted string is not what the page says. Replace with the verbatim sentence (below).

## 4. Precision fixes (not refutations)

- **The selector is derived from the release name *with an `istio-` prefix trimmed*** — `istio: {{ (.Values.labels.istio | quote) | default (include "gateway.name" . | trimPrefix "istio-") }}`. That `trimPrefix` is precisely *why* the conventional release `istio-ingressgateway` yields the label `ingressgateway`, and why `platform-gw` yields `platform-gw`. The doc's "derives it from the helm release name" is right but omits the mechanism that makes the common case look like a constant.
- **"ambient … (needs `istioCNI.enabled: true`)"** is verbatim-supported ("It must be true if ambient mode is enabled") but the reference also indicates istioCNI is **already enabled by default**, so the parenthetical implies an action that may be a no-op.
- **"Install (VCF 9 addon CLI)"** — the *command* is exactly sourced to the VCF blog, but that blog is **VKS 3.5, 2025-03-06**; it does not establish the "VCF 9" attribution in the row's name.

## 5. What I could NOT establish

`Gateway.tls.credentialName`'s secret "must live in the gateway's namespace" — istio.io's Secure Gateways task only *demonstrates* it (`kubectl create -n istio-system secret tls …`); I found no explicit sentence stating the requirement. The advice ("request it from the mesh admin") is sound, but the grade should be COMMUNITY/inferred, not asserted.
` | 22 | 18 |
| `/home/andriy/projects/vks-airgap-cicd/docs/vks-services/harbor.md` | 15 | 13 |

### `docs/vks-services/README.md:47,51-55`

- **fact:** "Broadcom's 9.1 documentation URLs return 301 Moved Permanently to the 9.0 tree (verified live, 2026-07-12)" — the premise of the entire `9.0-doc (inferred for 9.1)` grade.
- **was graded:** `asserted as verified-live (2026-07-12)` → **evidence says:** `REFUTED as stated — COMMAND-measured 2026-07-14. Replace with: "the`/…/latest/` tree 301s into `/9-0/`; some 9-1 paths 404 (the page does not exist in the 9.1 tree); genuine 9.1 pages serve 200 with zero redirects."`
- **evidence type:** COMMAND
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/>...  (6 URLs)
- **landed:** identical (no redirect) for the 200s; the 404s do not redirect either. Only the `/…/latest/…` URL 301s into `/9-0/`. ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""
- **command:** `curl -sS -L --max-time 30 -o /dev/null -w 'final=%{http_code} redirects=%{num_redirects} landed=%{url_effective}\n' <each URL>   # run 2026-07-14`

### `docs/vks-services/README.md:13 (table row: Harbor · Supervisor · platform team · Supervisor Service)`

- **fact:** Harbor runs on the Supervisor (in a vSphere Namespace) and is installed by the platform team as a Supervisor Service.
- **was graded:** `asserted, ungraded on this page` → **evidence says:** `9.1-doc (the page declares Product Version 9.1 and served 200 with ZERO redirects — this row does NOT need the 9.0 caveat)`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html>
- **landed:** same URL — final=200, num_redirects=0 (page declares "Product Version: VMware Cloud Foundation Service Administration and Development 9.1") ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "You can install Harbor as a Supervisor Service through the Supervisor Management option in the vSphere Client. / When deployed, the Harbor Supervisor Service creates vSphere Pods in the namespace provisioned for the service. / Verify that you have the Manage Supervisor Services privilege on the vCenter system where you add the services."

### `docs/vks-services/README.md:14 (table row: ArgoCD · Supervisor · platform team · Supervisor Service)`

- **fact:** ArgoCD runs on the Supervisor — the VMware Argo CD Operator is deployed on the Supervisor and the Argo CD instance is installed in a vSphere Namespace — installed by the platform team as a Supervisor Service.
- **was graded:** `asserted, ungraded on this page` → **evidence says:** `9.0-doc (inferred for 9.1) — but for the RIGHT REASON: no 9.1 page exists (404, not a 301). The content is reachable only in the /9-0/ tree and via the /latest/ alias that 301s into it.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html>  (the link docs/scenario-1.md:95 ships)
- **landed:** 404, no redirect. Content found instead at <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/using-argo-cd-service.html> (final=200, redirects=0, page declares "Product Version: vSphere Supervisor 9.0") ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "You can now deploy Argo CD as a Supervisor Service to provide declarative GitOps continuous delivery to your workloads running on vSphere Namespaces and VKS clusters. / You deploy the VMware Argo CD Operator on the Supervisor and then install an Argo CD instance in a vSphere Namespace so that you can use to manage workloads in vSphere Namespaces and VKS clusters."

### `docs/vks-services/README.md:15 (table row: Istio · GUEST/workload cluster · cluster owner · VKS Standard Package)`

- **fact:** Istio runs in the guest/workload (VKS/TKG-Service) cluster and is installed there by the cluster owner as a VKS Standard Package.
- **was graded:** `asserted, ungraded on this page` → **evidence says:** `9.0-doc (inferred for 9.1) — the 9-1 path 404s (not a 301); the 9.0 page is genuine and states the guest-cluster install explicitly. This is the fact a prior session WRONGLY retracted as UNVERIFIED — it is primary-sourced. Do not re-retract it.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/installing-standard-packages-on-tkg-cluster-using-tkr-for-vsphere-8-x/installaing-and-using-istio/install-istio.html>
- **landed:** 404, no redirect. Content at the /9-0/ equivalent: final=200, redirects=0, "Product Version: vSphere Supervisor 9.0" ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Follow these instructions to install the Istio carvel package on a VKS cluster that is running VKr 1.29 and later.  —  command given verbatim on the page: `vcf package install istio -p istio.kubernetes.vmware.com -v 1.25.3+vmware.1-vks.1 --values-file istio-data-values.yaml -n istio-installed`"

### `docs/vks-services/README.md:34 (Harbor / Real VKS lab cell)`

- **fact:** "already installed → discover the endpoint, request a robot account (`make harbor-robot` if you are a project admin)"
- **was graded:** `asserted` → **evidence says:** `CODE-REFUTED for the SHIPPED DEFAULTS. A Harbor project-admin CANNOT get a working robot with the default two-project layout:`make harbor-robot`detects non-sysadmin + 2 projects and REFUSES. The parenthetical must say: "…if you are a Harbor SYSTEM admin; a project-admin can only do this after collapsing to ONE project (set HARBOR_APP_PROJECT=HARBOR_INFRA_PROJECT in .env)".`
- **evidence type:** CODE
- **code:** scripts/22-harbor-robot.sh:37 (PROJECTS = HARBOR_INFRA_PROJECT + HARBOR_APP_PROJECT), :54-62 ("not sysadmin, TWO projects -> IMPOSSIBLE… Print the exact ask and stop"), :88-100 (log_error "A PROJECT-level robot (all a project-admin may create) is scoped to exactly ONE project"); .env.example:80 HARBOR_INFRA_PROJECT=cicd, .env.example:90 HARBOR_APP_PROJECT=apps  → 2 distinct projects by default

### `docs/vks-services/README.md:19-21 ("ArgoCD must be told how to reach your guest cluster") + :35 ("register the guest cluster as a destination (`make argocd-register-guest`, admin-only)")`

- **fact:** A Supervisor-hosted ArgoCD deploys into the guest cluster only if the guest is REGISTERED as an ArgoCD destination, and registration is an ArgoCD-ADMIN operation (not tenant-self-serviceable).
- **was graded:** `asserted` → **evidence says:** `primary-sourced (upstream ArgoCD) + CODE. The admin-only half rests on`clusters`being absent from the resources an AppProject role may grant.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/>
- **landed:** same (200) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""Some policy only have meaning within an application" — the page enumerates applications, applicationsets, logs and exec as the policies that "can also be configured in [AppProject's] roles". `clusters` is NOT among them, i.e. it exists only in the global RBAC policy → cluster registration cannot be delegated to a tenant AppProject role."
- **code:** Makefile:328 (`argocd-register-guest … ADMIN-only; needs ARGOCD_KUBECONFIG + KUBECONFIG`); k8s/argocd/*.yaml:20-24 (destination is a variable, with the comment "on a real lab the guest must be a REGISTERED destination or ArgoCD would deploy onto the Supervisor"); scripts/70-configure-argocd.sh:237-253 (a tenant may be Forbidden from LISTING registered clusters — handled, not assumed)

> **SUPERSEDED 2026-07-15.** The **quote** above reads the WRONG upstream page (`operator-manual/rbac/`, which lists the *Application-Specific* policy set), not `user-guide/projects.md`. `user-guide/projects.md` (Note 2) lists `clusters` among the resources an AppProject role MAY grant (verified by WebFetch 2026-07-15: *"other types of resources can also be used: applicationsets, repositories, clusters, logs and exec"*). So the "`clusters` is global-only → registration cannot be delegated" reasoning is wrong; the admin-only conclusion survives on the **`projects, update`** requirement instead. Current fact: [`docs/vks-services/argocd.md`](../vks-services/argocd.md) (the "clusters/UPDATE the AppProject" row).

### `docs/vks-services/README.md:22-24`

- **fact:** "there are no 'Istio credentials' to fetch" — mesh access is Kubernetes RBAC; Istio exposes no login/token/admin API.
- **was graded:** `asserted (KinD-verified in istio.md)` → **evidence says:** `KinD-verified + CODE. I found NO vendor sentence asserting this negative (a negative of this shape is rarely stated in vendor docs); it is established by the repo's own preflight, which interrogates only kubectl RBAC and a TLS Secret.`
- **evidence type:** CODE
- **code:** scripts/48-istio-preflight.sh (reports what THIS kubeconfig may do and what the mesh admin must grant — no credential fetch anywhere); scripts/lib/istio.sh (discovery is by Service port 15021 + spec.selector.istio, no auth); Makefile:377 (`istio-preflight … what must the mesh admin grant?`)
- **NOT ESTABLISHED — tried:** WebSearch of Broadcom techdocs for an Istio-package credentials/auth statement; the Install Istio + Istio Package Reference pages document values-file config only, no auth surface.
- **would settle it:** Nothing further is needed for the negative; a lab run of `make istio-preflight` against the platform mesh would upgrade it to lab-verified.

### `docs/vks-services/README.md:34-36 (the KinD stand-in column)`

- **fact:** KinD stand-in: `make install-harbor` (self-signed TLS on an LB IP), `make install-argocd` (same cluster; registration skipped), `INGRESS_CONTROLLER=istio` helm-installs the mesh / `istio-existing` attaches.
- **was graded:** `asserted` → **evidence says:** `CODE-verified — every named target and value exists.`
- **evidence type:** CODE
- **code:** Makefile:357 install-harbor · :361 install-argocd · :365 install-ingress · :373 attach-istio · :284 harbor-robot · :328 argocd-register-guest; scripts/44-install-ingress.sh:29-38 (dispatch on istio | istio-existing | traefik, dies on anything else); scripts/70-configure-argocd.sh:17 ("Where they are the same cluster (KinD, ArgoCD-in-guest) both kubeconfigs are the same file")

### `docs/vks-services/README.md:28 (topology diagram embed)`

- **fact:** ![VKS topology](../diagrams/out/vks-topology.png) resolves.
- **was graded:** `asserted` → **evidence says:** `CODE-verified`
- **evidence type:** COMMAND
- **command:** `ls -la docs/diagrams/out/vks-topology.png`

### `docs/vks-services/README.md:46 (grade definition: "9.1-doc | stated by a Broadcom page that genuinely served 9.1 content")`

- **fact:** The `9.1-doc` grade is currently used by NO row on any of the four pages — because the (false) blanket-redirect claim made it look unreachable.
- **was graded:** `n/a (grade definition)` → **evidence says:** `Now reachable: the Harbor Supervisor-Service pages ARE genuine 9.1 (200, 0 redirects, Product Version 9.1). Every Harbor row sourced from them should be regraded 9.1-doc.`
- **evidence type:** COMMAND
- **command:** `grep -rnoE 'https?://[^ )>`"]+' docs/vks-services/*.md`

### `docs/scenario-1.md:95 (adjacent, found while sourcing README:14 — flagging because an operator follows it)`

- **fact:** scenario-1.md links Broadcom's "Install Argo CD Service" at a /9-1/ URL.
- **was graded:** `asserted link` → **evidence says:** `BROKEN — 404. The page exists only in the /9-0/ tree (or via the /latest/ alias, which 301s into /9-0/).`
- **evidence type:** COMMAND
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html>
- **landed:** 404 (no redirect) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""
- **command:** `curl -sS -L -o /dev/null -w '%{http_code} %{num_redirects}\n' 'https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html'`

### `docs/vks-services/istio.md:18-19`

- **fact:** Istio on VKS is a Carvel Standard Package installed into the GUEST cluster; package name `istio.kubernetes.vmware.com`.
- **was graded:** `9.0-doc (inferred for 9.1)` → **evidence says:** `9.0-doc (inferred for 9.1) — CONFIRMED verbatim; no 9.1 page exists`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/istio-package-reference.html> (301 Moved Permanently — 'latest' IS the 9-0 tree) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "The package identifier is `istio.kubernetes.vmware.com`, referenced throughout the Istio Package Reference; the install page uses `vcf package available get istio.kubernetes.vmware.com -n tkg-system`."

### `docs/vks-services/istio.md:161, 170`

- **fact:** The Broadcom 9.1 VKS doc URLs 301-redirect to the 9.0 tree, so the exact 9.1 Istio package version strings are unobtainable.
- **was graded:** `stated as '9.1 URLs → 9.0 tree'` → **evidence says:** `CORRECT IN SPIRIT, IMPRECISE IN FACT — the 9-1 path 404s; it is`latest`that 301s to 9-0`
- **evidence type:** COMMAND
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/.../istio-package-reference.html>
- **landed:** HTTP 404 Not Found (no redirect). Separately: .../vsphere-supervisor-services-and-standalone-components/latest/.../istio-package-reference.html -> 301 -> .../vcf-service-administration-and-development/9-0/.../istio-package-reference.html ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""
- **command:** `WebFetch of both the 9-1 path and the 'latest' path`

### `docs/vks-services/istio.md:20`

- **fact:** VMware-built Istio versions, e.g. `1.25.3+vmware.1-vks.1`, `1.28.2+vmware.1-vks.1`.
- **was graded:** `9.0-doc — re-check the exact strings on a lab` → **evidence says:** `9.0-doc — CONFIRMED (both strings appear); keep the 're-check on a lab' caveat, since no 9.1 page exists to confirm the 9.1 set`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../standard-package-reference/istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../vcf-service-administration-and-development/9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Supported since 1.25.3+vmware.1-vks.1 (with later features in 1.27.1, 1.28.2+vmware.1-vks.1)"

### `docs/vks-services/istio.md:21`

- **fact:** Install (package CLI): `vcf package install istio -p istio.kubernetes.vmware.com -v <ver> --values-file istio-data-values.yaml -n istio-installed`
- **was graded:** `9.0-doc` → **evidence says:** `9.0-doc — CONFIRMED verbatim, character-for-character`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/installing-standard-packages-on-tkg-service-clusters/installing-standard-packages-on-tkg-cluster-using-tkr-for-vsphere-8-x/installaing-and-using-istio/install-istio.html>
- **landed:** same (no redirect; the 9-0 URL is canonical) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "vcf package install istio -p istio.kubernetes.vmware.com -v 1.25.3+vmware.1-vks.1 --values-file istio-data-values.yaml -n istio-installed"

### `docs/vks-services/istio.md:21`

- **fact:** The package-CLI install sequence is complete as documented in istio.md (one `vcf package install` line).
- **was graded:** `9.0-doc` → **evidence says:** `INCOMPLETE — two prior commands are required and are not shown`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/.../installaing-and-using-istio/install-istio.html>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "vcf package available get istio.kubernetes.vmware.com -n tkg-system  /  vcf package available get istio.kubernetes.vmware.com/1.25.3+vmware.1-vks.1 --default-values-file-output istio-data-values.yaml -n tkg-system"

### `docs/vks-services/istio.md:22`

- **fact:** Install (VCF 9 addon CLI): `vcf addon install create istio --cluster-name $VKS_CLUSTER -y`
- **was graded:** `community (VMware VCF blog, 2025-03, VKS 3.5)` → **evidence says:** `community — COMMAND CONFIRMED; but the row's NAME ('VCF 9 addon CLI') is an inference the cited blog does not support (it is VKS 3.5, 2025-03)`
- **evidence type:** COMMUNITY
- **requested:** <https://blogs.vmware.com/cloud-foundation/2025/03/06/istio-on-vsphere-kubernetes-service-vks-a-walkthrough/>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "vcf addon install create istio –cluster-name $VKS_CLUSTER -y"

### `docs/vks-services/istio.md:24`

- **fact:** The Istio ingress gateway is DISABLED by default (`istio.gateways.ingress.enabled: false`); its namespace is `istio-ingress` when enabled.
- **was graded:** `9.0-doc` → **evidence says:** `9.0-doc — CONFIRMED. This is the load-bearing fact behind 'classic may have nothing to bind to'.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../standard-package-reference/istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../vcf-service-administration-and-development/9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "istio.gateways.ingress.enabled is true in the data values, the default value is false  [and] Ingress gateway namespace: "istio-ingress"; control plane: "istio-system""

### `docs/vks-services/istio.md:23`

- **fact:** Control-plane namespace is `istio-system` (configurable).
- **was graded:** `9.0-doc` → **evidence says:** `9.0-doc — CONFIRMED`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Namespace Defaults — Control plane: "istio-system""

### `docs/vks-services/istio.md:25`

- **fact:** Data plane: sidecar by default; ambient supported (needs `istioCNI.enabled: true`).
- **was graded:** `9.0-doc` → **evidence says:** `9.0-doc — the ambient prerequisite is CONFIRMED verbatim, but the parenthetical is misleading: istioCNI is already enabled by DEFAULT, so it implies an action that is usually a no-op`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "enabled | The flag to install istio-cni or not. DaemonSet istio-cni-node is deployed if it is true. It must be true if ambient mode is enabled. | boolean | 1.25.3+vmware.1-vks.1  — and the page states istioCNI is enabled (true) by default."

### `docs/vks-services/istio.md:26`

- **fact:** Air-gap / private registry: `meshConfig.imagePullSecrets` — "the secrets to access the private registry must be provided in the air-gapped environment"
- **was graded:** `9.0-doc` → **evidence says:** `9.0-doc — QUOTE CONFIRMED VERBATIM, but the doc omits the adjacent sentence that changes what an operator must DO (see the next fact). Key path is`istio.meshConfig.imagePullSecrets`, not`meshConfig.imagePullSecrets`.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "imagePullSecrets | Specifies a list of Secrets in the same Namespace to pull images from the private docker registry for Istio injected resources. Note, the secrets to access the private registry must be provided in the air-gapped environment"

### `docs/vks-services/istio.md:82`

- **fact:** Gateway API attach, air-gap: "free — the auto-provisioned proxy inherits istiod's image hub, so it pulls `proxyv2` from Harbor with no extra config".
- **was graded:** `implied KinD-verified (asserted in scripts/lib/istio.sh:206-207)` → **evidence says:** `REFUTED for a VKS Standard Package mesh — TRUE ONLY for the mesh WE install with`--set global.hub`. Broadcom requires a pull Secret in the APPLICATION'S namespace whose name the MESH ADMIN must list in`istio.meshConfig.imagePullSecrets`.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Enabling Istio sidecar or gateway injection requires a Secret with registry credential in the application's namespace, and its name must be specified in istio.meshConfig.imagePullSecrets."
- **code:** scripts/lib/istio.sh:206-207 ('the provisioned proxy inherits istiod's image hub ... verified: the auto-created pod ran <harbor>/cicd/istio/proxyv2') — verified against scripts/46-install-istio.sh:99,112, i.e. against OUR OWN helm install where WE set global.hub. That condition does not hold on a package mesh we did not install.

### `docs/vks-services/istio.md:81`

- **fact:** Gateway API attach needs nothing from the mesh admin — "only rights in your own namespaces".
- **was graded:** `asserted (table, no explicit grade)` → **evidence says:** `REFUTED for a VKS Standard Package mesh in an air-gap — the tenant additionally needs the mesh admin to add their pull-Secret name to`istio.meshConfig.imagePullSecrets` (a mesh data-values key the tenant cannot set). `make istio-preflight`should print this ask.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/.../istio-package-reference.html>
- **landed:** <http://techdocs.broadcom.com/.../9-0/.../istio-package-reference.html> (301) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Enabling Istio sidecar or gateway injection requires a Secret with registry credential in the application's namespace, and its name must be specified in istio.meshConfig.imagePullSecrets."

### `docs/vks-services/istio.md:27`

- **fact:** Broadcom demonstrates routing with the Kubernetes Gateway API (`gatewayClassName: istio`) → auto-provisioned Service `<gateway-name>-istio`, type LoadBalancer, in the app's own namespace.
- **was graded:** `community (VMware VCF blog)` → **evidence says:** `community — CONFIRMED, and independently corroborated by istio.io (primary) for the naming/namespace mechanism`
- **evidence type:** COMMUNITY
- **requested:** <https://blogs.vmware.com/cloud-foundation/2025/03/06/istio-on-vsphere-kubernetes-service-vks-a-walkthrough/>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "The blog uses `gatewayClassName: istio` and an `HTTPRoute` (apiVersion: gateway.networking.k8s.io/v1) in namespace `bookinfo`; the gateway auto-provisions a LoadBalancer Service named "bookinfo-gateway-istio" with an external IP (10.163.44.40)."

### `docs/vks-services/istio.md:88-98, 110-114`

- **fact:** Istio does NOT ship the Gateway API CRDs; on KinD they existed only because cloud-provider-kind force-installed them. Whether a real VKS guest cluster ships them is UNVERIFIED.
- **was graded:** `mechanism KinD-verified; 'CRDs present on a VKS guest cluster' UNVERIFIED` → **evidence says:** `UPGRADE the first half to PRIMARY-SOURCED (istio.io states it outright). The VKS half remains genuinely NOT_ESTABLISHED — and correctly so.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "The Gateway APIs do not come installed by default on most Kubernetes clusters."
- **code:** scripts/05-kind-up.sh:156,200 (CPK run with --gateway-channel=disabled, 'IS LOAD-BEARING'); scripts/lib/istio.sh:133 istio_ensure_gwapi_crds; scripts/lib/istio.sh:174-182 (asserts a server-side-apply `Apply` managedFields manager — proof our code path ran, which mere presence never was)
- **NOT ESTABLISHED — tried:** istio.io gateway-api task page (primary) — settles 'Istio does not ship them'. No Broadcom page found stating whether a VKS guest cluster pre-installs the Gateway API CRDs; the 9-1 tree does not exist and the 9-0 Istio pages do not mention CRD prerequisites.
- **would settle it:** On a real VKS guest cluster: `kubectl get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'` (already named at istio.md:111 — keep it).

### `docs/vks-services/istio.md:43-49`

- **fact:** The ingress-gateway Service is identified by exposing port 15021 (the proxy status port) plus a `spec.selector.istio` key; istiod does NOT expose 15021 (it serves 15010/15012/443/15014), so this cleanly excludes the control plane.
- **was graded:** `KinD-verified` → **evidence says:** `KinD-verified + PRIMARY-SOURCED — istio.io's port table confirms 15021 is a proxy port and is absent from the istiod list`
- **evidence type:** VENDOR_DOC
- **requested:** <https://istio.io/latest/docs/ops/deployment/application-requirements/>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Sidecar proxy: 15021 | HTTP | Health checks. Control plane (istiod) ports: 443 (webhooks), 8080 (debug), 15010 (XDS/CA plaintext), 15012 (XDS/CA TLS), 15014 (control plane monitoring), 15017 (webhook container port). 15021 is NOT among them."
- **code:** scripts/lib/istio.sh:61-79 (selects a Service with `.port == 15021` AND `.spec.selector.istio != null`)

### `docs/vks-services/istio.md:53-64`

- **fact:** The `istio/gateway` helm chart derives the gateway's `istio:` label FROM THE HELM RELEASE NAME (release `platform-gw` → `istio: platform-gw`, not `ingressgateway`).
- **was graded:** `KinD-verified` → **evidence says:** `KinD-verified + PRIMARY-SOURCED, but IMPRECISE: the label is the release name with an`istio-` PREFIX TRIMMED. That trimPrefix is exactly why the conventional release `istio-ingressgateway` yields the label `ingressgateway`— the detail that makes the constant look like a constant.`
- **evidence type:** CODE
- **requested:** <https://raw.githubusercontent.com/istio/istio/master/manifests/charts/gateway/templates/_helpers.tpl>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "istio: {{ (.Values.labels.istio | quote) | default (include "gateway.name" . | trimPrefix "istio-") }}   — inside the `gateway.selectorLabels` template; `gateway.name` falls back to `.Release.Name`."
- **code:** scripts/90-e2e-istio-existing.sh:49 (PLATFORM_RELEASE=platform-gw), :103 (helm upgrade --install "$PLATFORM_RELEASE" istio/gateway), :112-113 (reads back svc .spec.selector.istio and logs it) — the KinD observation; scripts/lib/istio.sh:14

### `docs/vks-services/istio.md:70`

- **fact:** A `Gateway.spec.selector` matching no workload → Envoy never gets a listener → connection refused (no HTTP at all); the API server accepts it with no error.
- **was graded:** `KinD-verified` → **evidence says:** `KinD-verified — CONFIRMED, and it is an ASSERTED RED in the e2e (not a comment)`
- **evidence type:** CODE
- **code:** scripts/90-e2e-istio-existing.sh:152-180 — applies a Gateway with `selector: {istio: ingressgateway}` against a mesh labelled istio=platform-gw and DEMANDS HTTP 000: die "RED 2 FAILED: expected HTTP 000 (no listener bound — connection refused) ... got '$RED2_CODE'. 200 => the selector wrongly SERVED traffic"
- **command:** `make e2e-kind-istio-existing (not run in this READ-ONLY review; the assertion is in-tree and is claimed green in CLAUDE.md's e2e table)`

### `docs/vks-services/istio.md:71`

- **fact:** A VirtualService naming the Gateway by BARE NAME from another namespace resolves namespace-locally → 404.
- **was graded:** `KinD-verified` → **evidence says:** `PRIMARY-SOURCED (istio.io states the resolution rule verbatim). The '404' symptom is KinD-asserted in code comments only — no automated test.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://istio.io/latest/docs/reference/config/networking/virtual-service/>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Gateways in other namespaces may be referred to by `<gateway namespace>/<gateway name>`; specifying a gateway with no namespace qualifier is the same as specifying the VirtualService's namespace."
- **code:** scripts/lib/istio.sh:387 ('nothing — Envoy listens but returns 404. (KinD-proven.)'), :518; scripts/46-install-istio.sh:34; scripts/98-verify-ingress.sh:123 (the operator-facing 404 diagnostic)

### `docs/vks-services/istio.md:134-136`

- **fact:** A VKS guest cluster ENFORCES the `restricted` Pod Security Standard by default from VKr v1.26 — quoted as "pods violating security are rejected unless namespace configuration is changed". Exempt: kube-system, tkg-system, vmware-system-cloud-provider.
- **was graded:** `9.0-doc` → **evidence says:** `9.0-doc — SUBSTANCE FULLY CONFIRMED (this is the strongest vendor fact in the file). But the QUOTED STRING is not on the page — replace it with the verbatim sentences.`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/configure-psa-for-tkr-1-25-and-later.html>
- **landed:** <http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/managing-security-for-tkg-service-clusters/configure-psa-for-tkr-1-25-and-later.html> (301 Moved Permanently) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "By default, VKS clusters provisioned with VKS releases v1.26 and later have the PSA mode enforce set to restricted for non-system namespaces. [and] If a pod violates security, it is rejected. [and] Some system pods running in the kube-system, tkg-system, and vmware-system-cloud-provider namespaces require elevated privileges. These namespaces are excluded from pod security."
- **code:** scripts/lib/psa.sh:7 (carries the same non-verbatim quote — fix both); scripts/49-psa-check.sh:63,102,112,147

### `docs/vks-services/istio.md:139-145`

- **fact:** Measured PSA minimums (KinD-verified via a server-side dry-run label): gitea/tekton-pipelines/javawebapp = restricted; `ci` = baseline (Kaniko runs as root); the Gateway's namespace = baseline (the auto-provisioned proxy sets no seccompProfile and is created by the platform's istiod, not by us).
- **was graded:** `KinD-verified` → **evidence says:** `KinD-verified — SOUND: the measurement is reproducible in-tree (`make psa-check`performs a server-side dry-run label and prints WHY, rather than guessing)`
- **evidence type:** CODE
- **code:** scripts/49-psa-check.sh:50 (loops restricted|baseline|privileged via server-side dry-run), :102 (`eff="${cur:-restricted}"` — an UNLABELLED ns falls back to VKS's default), :126-129 (prints the API server's own 'why not restricted' warnings); scripts/lib/istio.sh:273 (the gateway-proxy-is-not-ours rationale)
- **command:** `make psa-check (read-only; not executed in this review — no cluster)`

### `docs/vks-services/istio.md:116-126`

- **fact:** RBAC table 'Measured with `kubectl auth can-i --as=system:serviceaccount:…`' — a namespace-scoped tenant may create VirtualServices/HTTPRoutes in its own namespaces but may NOT create a Gateway in the gateway ns, NOT create a VS there, and may NOT even read the gateway Service (so it cannot run discovery).
- **was graded:** `KinD-verified` → **evidence says:** `NOT_ESTABLISHED as cited — there is NO`--as=`anywhere in scripts/; the only trace is prose in docs/decisions/istio-on-vks.md:98. This is a claim ABOUT a measurement, not a reproducible measurement. It is load-bearing: it justifies the 'hand the values over via ISTIO_GATEWAY_* in .env' escape hatch.`
- **evidence type:** NOT_ESTABLISHED
- **command:** `grep -rn -- '--as=' scripts/ docs/decisions/istio-on-vks.md`
- **NOT ESTABLISHED — tried:** Grepped the whole scripts/ tree for `--as=` (0 hits) and for `can-i` (hits exist, but only in 23-argocd-preflight.sh / 48-istio-preflight.sh / 70-configure-argocd.sh / 71 / 91 / 24 — all measuring the CURRENT kubeconfig, none impersonating a scoped tenant SA). No captured command output exists in the repo or the decision doc.
- **would settle it:** Capture the four impersonated probes and their output, e.g. `kubectl auth can-i create virtualservices.networking.istio.io -n <app-ns> --as=system:serviceaccount:<app-ns>:<sa>`, `... create gateways.networking.istio.io -n istio-ingress --as=...`, `... get services -n istio-ingress --as=...` — and wire them as an asserted step in scripts/90-e2e-istio-existing.sh so the table's grade is regenerated, not remembered.

### `docs/vks-services/istio.md:7-12 (and 145)`

- **fact:** Istio has NO credentials — no login, no bearer token, no admin API, no UI; access is plain kubectl RBAC. The only credential-shaped object is the TLS Secret named by `Gateway.tls.credentialName`, which must live in the GATEWAY's namespace, so you request it from the mesh admin.
- **was graded:** `asserted (headline claim)` → **evidence says:** `'No credentials / access is kubectl RBAC' SURVIVES (nothing in Istio's docs or our code exposes an auth surface; it is enforced by k8s RBAC). The 'credentialName Secret must live in the gateway's namespace' half is NOT_ESTABLISHED as an explicit vendor sentence — only demonstrated by example. Downgrade that clause to community/inferred rather than asserting it.`
- **evidence type:** NOT_ESTABLISHED
- **requested:** <https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/>
- **landed:** same ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "No explicit sentence found. The page only DEMONSTRATES it: `kubectl create -n istio-system secret tls httpbin-credential ...` — i.e. the secret is created in the ingress gateway's own namespace, never the application's."
- **NOT ESTABLISHED — tried:** Fetched istio.io Secure Gateways task and searched for an explicit namespace requirement for `credentialName`; the page shows the behaviour by example only. Also read the VirtualService reference (which settles the separate bare-name-gateway question, but says nothing about TLS secrets).
- **would settle it:** istio.io's Gateway API reference for `tls.certificateRefs` / the classic `ServerTLSSettings.credentialName` field reference — or, decisively, a lab check: create the TLS Secret in the app namespace only, and confirm the gateway does not serve it (SDS reads secrets from the proxy's own namespace).

### `docs/vks-services/harbor.md:83-88`

- **fact:** "Never run two registry-mutating operations at once. Concurrent pushes corrupt Harbor's blob store: tags/manifests end up referencing blobs that HEAD-200 but are not stored ... recoverable only by rebuilding the registry. (Learned the hard way: a second e2e-kind started while the first was finishing corrupted all 34 images.)"
- **was graded:** `asserted (ungraded)` → **evidence says:** `REFUTED — root cause was OUR installer, not concurrency`
- **evidence type:** CODE
- **code:** CLAUDE.md:874-910 ("SETTLED 2026-07-13 — Harbor's 'blob-store corruption' was NEVER concurrency — it was US"); scripts/06-install-harbor.sh:79-80,109,158-159,186-198; Makefile:234
- **command:** `grep -n 'SETTLED 2026-07-13|NEVER concurrency|persistence.enabled|emptyDir|descriptor' CLAUDE.md`

### `docs/vks-services/harbor.md:86`

- **fact:** "This is now enforced mechanically (a `flock` guard on the mirror/builder pushes), not just documented."
- **was graded:** `asserted (ungraded)` → **evidence says:** `CODE-verified (the MECHANISM is real; only its stated RATIONALE is false)`
- **evidence type:** CODE
- **code:** scripts/lib/os.sh:50-72 (with_registry_lock); scripts/21-mirror-push.sh:20; scripts/22-builder-push.sh:36; scripts/16-engine-trust-check.sh:36
- **command:** `grep -rn 'with_registry_lock' scripts/ | head`

### `docs/vks-services/harbor.md:35,37-40`

- **fact:** "A Harbor **project-admin** (granted directly, not via an SSO group) can self-service a robot with push+pull on the two mirror projects — that is what `make harbor-robot` does" / table row: "`make harbor-robot` creates one **if you are a Harbor project-admin**"
- **was graded:** `KinD-verified` → **evidence says:** `REFUTED by our own code — the two-project robot requires Harbor SYSTEM-ADMIN`
- **evidence type:** CODE
- **code:** scripts/22-harbor-robot.sh:46-62,84-90; scripts/lib/harbor.sh:77-85 (harbor_is_sysadmin)
- **command:** `sed -n '46,62p' scripts/22-harbor-robot.sh`

### `docs/vks-services/harbor.md:22`

- **fact:** "Ordering | configure Harbor's cert + credentials **BEFORE** creating guest clusters | community"
- **was graded:** `community` → **evidence says:** `REFUTED by vendor doc — you may also update an EXISTING cluster`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html>
- **landed:** <http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html> (301 Moved Permanently — 'latest' resolves to the 9-0 tree) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""You can configure the private registry certificate when you initially create the cluster, or you can update an existing cluster and provide the private registry certificate." (page title: 'Integrate VKS Clusters with a Private Container Registry'; product version: vSphere Supervisor 9.0)"

### `docs/vks-services/harbor.md:17`

- **fact:** "Ingress prereq | **Contour** is the paired ingress for the Harbor Supervisor Service (`enableContourHttpProxy: true`) — *not* Istio | 9.0-doc"
- **was graded:** `9.0-doc` → **evidence says:** `PARTLY REFUTED — Contour is ONE of two options; an NGINX LoadBalancer is the other, and the two are MUTUALLY EXCLUSIVE`
- **evidence type:** VENDOR_DOC
- **requested:** <https://raw.githubusercontent.com/vsphere-tmm/Supervisor-Services/main/harbor/README-v2.13.1.md> (VMware's own Supervisor-Services repo) + <https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/installing-and-configuring-harbor-and-contour.html>
- **landed:** same (raw.githubusercontent 200; the 8-0 techdocs page served directly) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Supervisor-Services README-v2.13.1.md: 'enableNginxLoadBalancer | true or false | Use a K8s Service of type LoadBalancer to expose Harbor's endpoints when it's set to true. This requires a Supervisor to be configured with a load balancer. **enableNginxLoadBalancer and enableContourHttpProxy can't be true at the same time.** When they are both set to false, an Ingress will be created...' — and TechDocs ('Using Harbor as a Supervisor Service', vSphere Supervisor 8.0): 'Harbor requires a load balancer or an Ingress controller. **You can use either an NGINX-based load balancer or Contour.**' / '**If you use Contour** as an Ingress controller, install it before installing Harbor on the same Supervisor where you want to install Harbor.' ⇒ the Contour prereq is CONDITIONAL, and our LB-based model maps to enableNginxLoadBalancer, not enableContourHttpProxy."
- **command:** `curl -sS https://raw.githubusercontent.com/vsphere-tmm/Supervisor-Services/main/harbor/README-v2.13.1.md`

### `docs/vks-services/harbor.md:54`

- **fact:** "in-cluster **Kaniko** | the CA mounted at `/kaniko/ssl/certs/additional-ca-cert-bundle.crt`"
- **was graded:** `KinD-verified` → **evidence says:** `REFUTED — the repo uses`--registry-certificate=<host>=<ca>` from a `ca`workspace; that path is never mounted`
- **evidence type:** CODE
- **code:** k8s/tekton/tasks/kaniko-build.yaml:42-48,77-82; k8s/tekton/trigger-app.yaml:75-79; scripts/60-configure-tekton.sh:103-104
- **command:** `grep -rn 'additional-ca-cert-bundle' . --exclude-dir=.git`

### `docs/vks-services/harbor.md:18`

- **fact:** "`secretKey` | must be **exactly 16 chars** | community (Broadcom + William Lam)"
- **was graded:** `community` → **evidence says:** `VENDOR_DOC (upgrade) — Broadcom Harbor Package Reference states it verbatim`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/harbor-components--configuration--data-values/harbor.html>
- **landed:** same (served directly, no redirect) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""The secret key used for encryption. Must be a string of 16 chars." (page title: 'Harbor 2.13.5 Package Reference'). NOTE: this page is the Harbor *Standard Package* reference (TKG-cluster tree), not the Supervisor-Service page — the constraint is a property of the Harbor chart's data-values, so it carries across, but grade it 'vendor-doc (Harbor package reference), inferred for the 9.1 Supervisor Service'."

### `docs/vks-services/harbor.md:19`

- **fact:** "`core.xsrfKey` | must be **exactly 32 chars** | community"
- **was graded:** `community` → **evidence says:** `VENDOR_DOC (upgrade)`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/harbor-components--configuration--data-values/harbor.html>
- **landed:** same (served directly, no redirect) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""The XSRF key. Must be a string of 32 chars." (page title: 'Harbor 2.13.5 Package Reference'). Same caveat as secretKey: it is the Harbor package data-values reference, not the Supervisor-Service install page."

### `docs/vks-services/harbor.md:20`

- **fact:** "`tlsSecretLabels` | `{managed-by: vmware-vRegistry}` is **REQUIRED** for VKS to trust it | community"
- **was graded:** `community` → **evidence says:** `PRIMARY-SOURCE (upgrade) — VMware's own Supervisor-Services repo lists it in the REQUIRED-fields table, and states its purpose`
- **evidence type:** VENDOR_DOC
- **requested:** <https://raw.githubusercontent.com/vsphere-tmm/Supervisor-Services/main/harbor/README-v2.13.1.md>
- **landed:** same (HTTP 200, 6006 bytes) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "Header: "The table below highlights the **required fields** for the Harbor data values file." Row: "tlsCertificate.tlsSecretLabels | {\"managed-by\": \"vmware-vRegistry\"} | The certificate that vSphere Kubernetes Service uses to install the Harbor CA as a trusted root on vSphere Kubernetes Service clusters." — this is BOTH the confirmation of the REQUIRED label AND the actual mechanism behind what our doc separately calls 'same-Supervisor auto-trust'."
- **command:** `grep -niE 'vRegistry|tlsSecretLabels' /tmp/harbor-readme.md`

### `docs/vks-services/harbor.md:21`

- **fact:** "CA trust for guest clusters | the Cluster spec's `trust.additionalTrustedCAs` — the cert must be **DOUBLE-base64** (`base64 -w0 ca.crt | base64 -w0`) | community"
- **was graded:** `community` → **evidence says:** `VENDOR_DOC (upgrade) — 9.0-doc, inferred for 9.1`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/managing-vsphere-kuberenetes-service-clusters-and-workloads/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html>
- **landed:** <http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/>... (301 — 'latest' → the 9-0 tree) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""you include a trust field with the additionalTrustedCAs value." and "**The v1beta1 API requires the certificate contents to be double base64-encoded.**" with the example command "base64 -w 0 ca.crt | base64 -w 0" (page title: 'Integrate VKS Clusters with a Private Container Registry'; product version: vSphere Supervisor 9.0). Corroborated by williamlam.com (2025-08-12, William Lam), which shows the same `base64 -w 0 ca.crt | base64 -w 0` — though NOTE he wires it via the `osConfiguration` variable, not `trust.additionalTrustedCAs`, so two mechanisms may exist and our doc names only one."

### `docs/vks-services/harbor.md:24-27`

- **fact:** "**Same-Supervisor auto-trust.** A guest cluster created under the same Supervisor as the Harbor Supervisor Service is reported to trust its CA automatically. *Confidence: community — verify on a lab.*"
- **was graded:** `community` → **evidence says:** `SUPERSEDED — it is not 'same-Supervisor magic'; it is CONDITIONAL on the tlsSecretLabels`managed-by: vmware-vRegistry`label`
- **evidence type:** VENDOR_DOC
- **requested:** <https://raw.githubusercontent.com/vsphere-tmm/Supervisor-Services/main/harbor/README-v2.13.1.md>
- **landed:** same (HTTP 200) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""The certificate that vSphere Kubernetes Service uses to install the Harbor CA as a trusted root on vSphere Kubernetes Service clusters." — the trust is performed BY VKS, keyed on the labelled harbor-tls secret. So the auto-trust is real but has a PRECONDITION our doc lists as an unrelated row. The Broadcom private-registry page (fetched 2026-07-14, 9.0 tree) does NOT mention same-Supervisor auto-trust at all; and williamlam.com 2025-08-12 does not either (checked). Do NOT downgrade the claim to doubt — it has a documented mechanism; it needs the LABEL, and a lab run to confirm end-to-end."

### `docs/vks-services/harbor.md:15`

- **fact:** "Packaging | **Supervisor Service**, installed on the **Supervisor** into its own vSphere Namespace | 9.0-doc (inferred for 9.1)"
- **was graded:** `9.0-doc (inferred for 9.1)` → **evidence says:** `CONFIRMED — grade stands; the namespace name is community-sourced (`svc-harbor-<id>`)`
- **evidence type:** COMMUNITY
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html>
- **landed:** <http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html> (301 → 9-0 tree; that redirect target then returned HTTP 404 on direct fetch, so the install page itself could NOT be read) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "The Supervisor-Service packaging is confirmed by the page titles themselves ('Install Harbor as a Supervisor Service', 'Using Harbor as a Supervisor Service', vSphere Supervisor 8.0/9.0 trees). The *own vSphere Namespace* detail is COMMUNITY-only: search-surfaced sources state 'Harbor deployed as a supervisor service runs as a set of Kubernetes pods within the svc-harbor-{vsphere-cluster-moref} namespace' (e.g. virtualhippy.com 'Deploy Harbor as a Supervisor Service in VCF 9 for VKS Clusters'; worker-node.com 2025-10-04). I did not obtain a Broadcom page stating the namespace name verbatim."

### `docs/vks-services/harbor.md:16`

- **fact:** "Exposure | LoadBalancer, **self-signed TLS** by default (an internal CA) | 9.0-doc + community"
- **was graded:** `9.0-doc + community` → **evidence says:** `SPLIT — 'LoadBalancer' is CONDITIONAL (enableNginxLoadBalancer=true); 'self-signed TLS by default' is NOT_ESTABLISHED`
- **evidence type:** NOT_ESTABLISHED
- **NOT ESTABLISHED — tried:** Fetched the vsphere-tmm Supervisor-Services Harbor README (2026-07-14) — it documents enableNginxLoadBalancer / enableContourHttpProxy / neither→Ingress, but says NOTHING about a default self-signed certificate. Requested <https://techdocs.broadcom.com/.../latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html> (301→9-0, then 404) and .../installing-and-configuring-harbor-and-contour.html (404). Searched 'Harbor Supervisor Service self-signed TLS default certificate'. The 'Install Harbor with a Customized Certificate' page exists (301→9-0), which IMPLIES a non-custom default exists, but I did not read a sentence stating it is self-signed.
- **would settle it:** Fetch the (currently 404ing) Broadcom page 'Install Harbor as a Supervisor Service' 9.0/9.1 and quote its certificate section; OR on a lab: `kubectl -n svc-harbor-<id> get secret harbor-tls -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -issuer -subject` (issuer==subject ⇒ self-signed) and `kubectl -n svc-harbor-<id> get svc -o wide` (is there a type=LoadBalancer service, or an Envoy/Contour HTTPProxy?).

### `docs/vks-services/harbor.md:33 and 102-104`

- **fact:** "`HARBOR_URL` | the FQDN you set, or `kubectl get svc -n <harbor-ns> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` | 9.0-doc" — and the Open item "Whether the lab's Harbor is addressed by **FQDN**"
- **was graded:** `9.0-doc` → **evidence says:** `The FQDN question is ANSWERED by the vendor: Harbor's`hostname`is an FQDN resolved by external DNS — so the LB-IP alternative in this row is a TLS trap on a real lab`
- **evidence type:** VENDOR_DOC
- **requested:** <https://raw.githubusercontent.com/vsphere-tmm/Supervisor-Services/main/harbor/README-v2.13.1.md>
- **landed:** same (HTTP 200) ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** ""hostname | FQDN | The FQDN that you have designated to access the Harbor UI and for referencing the registry in client applications. **The domain should be configured in an external DNS server such that it resolves to the Envoy Service IP created by Contour or the External IP of the LoadBalancer Service**, depending on the 'enableNginxLoadBalancer' and 'enableContourHttpProxy' settings." ⇒ On a real lab the Harbor cert's SAN is the FQDN, so pulling the LB IP out of the Service and using it as HARBOR_URL will fail TLS verification (x509 SAN mismatch). Our KinD stand-in mints SAN=IP (scripts/06-install-harbor.sh:118 per CLAUDE.md), which is exactly why this never bites locally."

### `docs/vks-services/harbor.md:106-111 (Sources) and the whole grading scheme`

- **fact:** "Broadcom TechDocs — Harbor Supervisor Service install / Integrate VKS with a Private Registry (9.1 URLs → 9.0 tree)"
- **was graded:** `asserted` → **evidence says:** `CONFIRMED, and STRONGER than stated — even the`latest`URL 301-redirects to the 9-0 tree`
- **evidence type:** VENDOR_DOC
- **requested:** <https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vsphere-supervisor-services-and-standalone-components/latest/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html>
- **landed:** <http://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-0/using-supervisor-services/installing-and-configuring-harbor-and-contour/install-harbor-as-a-supervisor-service.html> ⚠️ **REDIRECTED — 9.0 content read as 9.1**
- **retrieved:** 2026-07-14
- **quote:** "HTTP 301 Moved Permanently. Reproduced on THREE separate Broadcom URLs today (install-harbor-as-a-supervisor-service, install-the-harbor-supervisor-service, install-harbor-with-a-customized-certificate) — every `/latest/` path redirects into `/vcf-service-administration-and-development/9-0/`. So it is not only the 9.1 URLs: there is no 9.1 Harbor content reachable at all, and EVERY Broadcom Harbor fact in this doc is 9.0 content. The Sources section should say '9.1 AND latest URLs → 9.0 tree (verified 2026-07-14)'."
