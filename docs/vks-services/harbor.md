# Harbor on VKS

**Where it runs:** the **Supervisor** — in its own vSphere Namespace.
**Who installs it:** the platform team, as a **Supervisor Service**.
**What we do:** **discover** its endpoint, **request** a robot account, and mirror every image into it.

Harbor is the one service in this demo that is *load-bearing for the air gap*: it is the only
registry the workload cluster can pull from, so every image — Tekton, Kaniko, Gitea, the JDK/JRE,
Istio's `pilot`/`proxyv2`, and the app itself — must be mirrored into it first.

## What Broadcom ships

| Fact | Value | Confidence |
|---|---|---|
| Packaging | **Supervisor Service**, installed on the **Supervisor** into its own vSphere Namespace | 9.1-doc [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html date=2026-07-15 quote="You can deploy Harbor as a Supervisor Service in your Supervisor environment."] |
| Exposure | LoadBalancer, **self-signed TLS** by default (an internal CA) | 8.0-doc (LB) + community (TLS) [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/vsphere-supervisor-services-and-workloads-8-0/installing-and-configuring-harbor-and-contour.html date=2026-07-15 quote="Harbor requires a load balancer or an Ingress controller. You can use either an NGINX-based load balancer or Contour."] |
| Ingress / LB | **either** an NGINX-based load balancer **or** Contour (Contour is itself a Supervisor Service; toggle `enableNginxLoadBalancer` vs `enableContourHttpProxy`) — Contour is **NOT required**, and it is **not** Istio. If you choose Contour, install it before Harbor. | 9.1-doc [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html date=2026-07-16 quote="you can expose Harbor through either an NGINX-based load balancer or by using Contour"] |
| `secretKey` | must be **exactly 16 chars** | 8.0-doc (inferred for 9.1) [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/harbor-components--configuration--data-values/harbor.html date=2026-07-15 quote="The secret key used for encryption. Must be a string of 16 chars."] |
| `core.xsrfKey` | must be **exactly 32 chars** | 8.0-doc (inferred for 9.1) [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/installing-standard-packages-on-tkg-service-clusters/standard-package-reference/harbor-components--configuration--data-values/harbor.html date=2026-07-15 quote="The XSRF key. Must be a string of 32 chars."] |
| `tlsSecretLabels` | the Supervisor-Service page carries `{managed-by: vmware-vRegistry}` with **"keep as is"** guidance (VKS trust is the inferred reason, not stated) | community [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/using-private-registries-with-tkg-service-clusters/install-the-harbor-supervisor-service.html date=2026-07-15 quote="managed-by: vmware-vRegistry (verify this value but keep as is)"] |
| CA trust for guest clusters | the Cluster spec's `trust.additionalTrustedCAs` — the cert must be **DOUBLE-base64** (`base64 -w0 ca.crt \| base64 -w0`) | 8.0-doc (inferred for 9.1) [src: url=https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere-supervisor/8-0/using-tkg-service-with-vsphere-supervisor/using-private-registries-with-tkg-service-clusters/integrate-tkg-service-clusters-with-a-private-container-registry.html date=2026-07-15 quote="The v1beta1 API requires the certificate contents to be double base64-encoded."] |
| Ordering | trusting the CA can happen **at cluster creation or later** (`kubectl edit cluster`); configuring Harbor before creating guest clusters is operational convenience, **not a documented prerequisite** | community [src: NOT-ESTABLISHED tried="WebFetched williamlam 2025-08 + Broadcom 8-0 integrate-private-registry + install-the-harbor-supervisor-service — none states a hard BEFORE ordering; the integrate page allows adding CAs at creation or via kubectl edit later"] |

> **Same-Supervisor auto-trust.** A guest cluster created under the **same Supervisor** as the
> Harbor Supervisor Service is reported to trust its CA automatically — simpler than the KinD
> stand-in, which must wire the CA into each node's containerd (`certs.d/<host>/ca.crt`).
> *Confidence: community — verify on a lab.*

## What you must obtain, and how

| Value | How | Confidence |
|---|---|---|
| `HARBOR_URL` | the FQDN you set, or `kubectl get svc -n <harbor-ns> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` | code [src: code:scripts/02-env.sh:75] |
| `HARBOR_CA_FILE` | `make fetch-harbor-ca` (pulls the self-signed CA off the endpoint) | KinD-verified [src: code:Makefile:273-274] |
| `HARBOR_USERNAME` / `HARBOR_PASSWORD` | a **robot account**. `make harbor-robot` creates one **only if you are a Harbor SYSTEM-admin**; otherwise **request** it from the platform team | code [src: code:scripts/22-harbor-robot.sh:62-107] |

**Robot accounts are the tenant path — and a project-admin CANNOT self-service one in the default
config.** The default flow uses **two** projects (`HARBOR_INFRA_PROJECT=cicd` + `HARBOR_APP_PROJECT=apps`,
`.env.example:80,90`); one credential spanning two projects can only be a `level: "system"` robot, and
**Harbor gates that on system-admin** — so `make harbor-robot` as a two-project project-admin falls into
the `else` branch and **`die`s** (`scripts/22-harbor-robot.sh:76,86`) before the mirror starts. Two robots
cannot substitute: Kaniko carries a **single** host-keyed docker auth and must PULL from the infra project
and PUSH to the app project with it (`scripts/22-harbor-robot.sh:57-61`). The table below is the who →
what. (An earlier `KinD-verified` note claimed a project-admin *could* self-service; arc in
[`docs/reviews/2026-07-14-vks-provenance.md`](../reviews/2026-07-14-vks-provenance.md).)

| you are | what works |
|---|---|
| Harbor **system-admin** | `make harbor-robot` — creates the two-project system robot |
| Harbor **project-admin**, and you collapse to ONE project (`HARBOR_APP_PROJECT=$HARBOR_INFRA_PROJECT`) | `make harbor-robot` — creates a project-level robot |
| Harbor **project-admin**, two projects (the default) | **impossible.** The command prints the exact ask and stops — take it to your platform team |
| no admin at all | **request** the robot; `.env.example:83-88` states the ask |

## Trusting a self-signed Harbor — sudo-free, per consumer

Every consumer needs the CA, and the obvious `update-ca-certificates` route needs **root**. This
repo trusts it **per consumer** instead (all KinD-verified, and the same mechanics apply on a lab):

| Consumer | Mechanism |
|---|---|
| `crane` (the mirror engine) | `SSL_CERT_FILE=<bundle>` — build the bundle as **system CAs + the Harbor CA** (`ca_bundle_with_system`). **Corrected 2026-07-16:** this said Go *"replaces"* its trust pool. It **augments** — `SSL_CERT_FILE` overrides only Go's default *file* list; `certDirectories` (`/etc/ssl/certs`, `/etc/pki/tls/certs`) are still appended unless `SSL_CERT_DIR` is **also** set. Measured (Go 1.26.5, `x509.SystemCertPool()`): none → **122** roots · `SSL_CERT_FILE=<one-ca>` → **123** · `+ SSL_CERT_DIR=/nonexistent` → **1**. Bundle anyway — it is the form that survives `SSL_CERT_DIR` being set or a non-standard layout. **`SSL_CERT_FILE` is NOT a way to trust only our CA.** |
| `podman` (builder push, the DEFAULT) | `--cert-dir <dir>` containing **only** `ca.crt` — per command, **no sudo, ever** |
| `docker` **rootless** | the daemon reads `~/.config/docker/certs.d/<host>/ca.crt` — **no sudo** |
| `docker` **rootful** | the daemon reads `/etc/docker/certs.d/<host>/ca.crt` — **root-owned, so ONE SUDO PER REGISTRY.** The `docker` group grants socket access, not write access to `/etc`; this cannot be engineered away, only disclosed |
| each node's **containerd** | `/etc/containerd/certs.d/<host>/hosts.toml` with an explicit `ca = …` line |
| in-cluster **Kaniko** | the CA mounted at `/kaniko/ssl/certs/additional-ca-cert-bundle.crt` |

> **`make trust-harbor` does whichever of these applies to your engine — and PROVES it with a real login
> handshake** rather than placing a file and hoping. Do not gate on the file's existence: docker **merges**
> `certs.d` with the host system store, so a *missing* `ca.crt` does **not** mean docker will fail (an
> operator who ran `update-ca-certificates` already works). The only honest test of trust is a trust
> operation. `make engine-check` tells you which mode you are in before you start.

On a real lab the guest cluster's trust comes from the Cluster spec (`trust.additionalTrustedCAs`,
double-base64) or same-Supervisor auto-trust — the containerd wiring above is the KinD stand-in's
substitute for that.

## Public vs private projects

| | Effect |
|---|---|
| `HARBOR_PUBLIC_PROJECTS=true` (default) | anonymous pull → the app namespace needs **no** `imagePullSecret` |
| `HARBOR_PUBLIC_PROJECTS=false` | you must supply an app-namespace `imagePullSecret` from the robot credentials |

## What we run

| Command | Does |
|---|---|
| `make fetch-harbor-ca` | fetch the self-signed CA → `HARBOR_CA_FILE` |
| `make harbor-robot` | create the least-privilege CI robot (needs Harbor project-admin) |
| `make mirror` | pull every image in `images/images.txt` → push to Harbor (**resumable**: a re-run cache-skips images already pulled) |
| `make mirror-verify` | prove every mirrored image is **intact** in Harbor (`crane validate` + digest match against `images.lock`) |
| `make install-harbor` | KinD stand-in only — installs Harbor with self-signed TLS on an LB IP |

> **Run registry-mutating operations SERIALLY** — because they mutate a **shared cluster and registry**,
> so parallel runs make any failure **unattributable**. The `flock` guard on the mirror/builder pushes
> (`scripts/lib/os.sh:54-71`) stands on that reasoning. An earlier claim that *"concurrent pushes corrupt
> Harbor's blob store"* was a misdiagnosis, root-caused and fixed 2026-07-13 (the real cause was our own
> installer wiping an `emptyDir` registry while a stale Redis descriptor cache still HEAD-200'd the
> missing blobs); full arc in `CLAUDE.md` §"Harbor's blob-store corruption was NEVER concurrency".
> <!-- arc-ok: 2026-07-13 -->

## Image-tag drift — the alignment gate

Every mirrored image's tag lives in **two** places: `images/images.txt` (the Renovate-tracked source
of truth) and whatever consumes it (k8s/Tekton manifests, `.env.example` version vars, the app
Dockerfile). A partial bump means the mirror pushes one tag while a manifest pulls another →
`ImagePullBackOff` at runtime, never at build. `make check-image-alignment` (in `static-check`) is
the deterministic backstop; a Renovate customManager bumps the consumers in lockstep.

## Open / unverified

- All the "community"-graded rows above (the 16/32-char key constraints, `tlsSecretLabels`, the
  double-base64 CA, same-Supervisor auto-trust) — **verify on a real 9.1 lab**.
- Whether the lab's Harbor is addressed by **FQDN** (the KinD stand-in uses an LB **IP** with
  `SAN=IP`, which is deliberate: it avoids DNS/sudo friction while keeping the self-signed-TLS
  posture identical).

## Sources

- Broadcom TechDocs — *Install Harbor as a Supervisor Service* (`/9-1/` URL, HTTP 200, Product
  Version 9.1 → 9.1-primary for the packaging) / *Integrate VKS with a Private Registry* (config
  specifics resolve only to `/9-0/`)
- williamlam.com (2025-08) — VKS private-registry quick-tip
- ogelbric/LAB — `Create_Harbor` (a working jump-box transcript)
