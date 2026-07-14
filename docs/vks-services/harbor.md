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
| Packaging | **Supervisor Service**, installed on the **Supervisor** into its own vSphere Namespace | 9.0-doc (inferred for 9.1) |
| Exposure | LoadBalancer, **self-signed TLS** by default (an internal CA) | 9.0-doc + community |
| Ingress prereq | **Contour** is the paired ingress for the Harbor Supervisor Service (`enableContourHttpProxy: true`) — *not* Istio | 9.0-doc |
| `secretKey` | must be **exactly 16 chars** | community (Broadcom + William Lam) |
| `core.xsrfKey` | must be **exactly 32 chars** | community |
| `tlsSecretLabels` | `{managed-by: vmware-vRegistry}` is **REQUIRED** for VKS to trust it | community |
| CA trust for guest clusters | the Cluster spec's `trust.additionalTrustedCAs` — the cert must be **DOUBLE-base64** (`base64 -w0 ca.crt \| base64 -w0`) | community |
| Ordering | configure Harbor's cert + credentials **BEFORE** creating guest clusters | community |

> **Same-Supervisor auto-trust.** A guest cluster created under the **same Supervisor** as the
> Harbor Supervisor Service is reported to trust its CA automatically — simpler than the KinD
> stand-in, which must wire the CA into each node's containerd (`certs.d/<host>/ca.crt`).
> *Confidence: community — verify on a lab.*

## What you must obtain, and how

| Value | How | Confidence |
|---|---|---|
| `HARBOR_URL` | the FQDN you set, or `kubectl get svc -n <harbor-ns> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` | 9.0-doc |
| `HARBOR_CA_FILE` | `make fetch-harbor-ca` (pulls the self-signed CA off the endpoint) | KinD-verified |
| `HARBOR_USERNAME` / `HARBOR_PASSWORD` | a **robot account**. `make harbor-robot` creates one **only if you are a Harbor SYSTEM-admin**; otherwise **request** it from the platform team | CODE: `scripts/22-harbor-robot.sh:46-107` |

**Robot accounts are the tenant path — and a project-admin CANNOT self-service one in the default
config.** This page used to say a **project-admin** could, graded `KinD-verified`. **Both halves were
wrong**, and our own code says so:

- The default flow uses **two** projects (`HARBOR_INFRA_PROJECT=cicd` + `HARBOR_APP_PROJECT=apps`,
  `.env.example:80,90`). One credential spanning two projects can only be a `level: "system"` robot, and
  **Harbor gates that on system-admin**. So `make harbor-robot` as a project-admin falls straight into
  the `else` branch and **`die`s** (`scripts/22-harbor-robot.sh:64,76,88,107`) — *before the mirror ever
  starts*. A tenant following this page got a 403 and no robot.
- Two robots cannot substitute for one: Kaniko carries a **single** host-keyed docker auth and must
  PULL from the infra project and PUSH to the app project with it (`scripts/22-harbor-robot.sh:57-61`).
- The `KinD-verified` grade was unsupported: **no e2e exercises a non-sysadmin Harbor identity**, so
  nothing ever tested the claim it was asserting.

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
| `crane` (the mirror engine) | `SSL_CERT_FILE=<bundle>` — build the bundle as **system CAs + the Harbor CA**, since Go *replaces* its trust pool rather than augmenting it |
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

> **Run registry-mutating operations SERIALLY — but NOT for the reason this page used to give.**
>
> This page claimed *"concurrent pushes corrupt Harbor's blob store"*. **That was a misdiagnosis, and it
> is settled** (`CLAUDE.md` §"Harbor's blob-store corruption was NEVER concurrency — it was US",
> root-caused 2026-07-13). The real cause was **our own installer**: the registry's blob store was an
> `emptyDir`, and `install-harbor` helm-upgraded **unconditionally twice per run**, rolling the registry
> pod and **destroying the whole mirror** — while `harbor-redis` (a *different* pod, which does not roll)
> kept its **blob-descriptor cache**, so the registry went on answering `HEAD <blob>` with **200** for
> blobs it no longer had. `crane` reads a HEAD-200 as "already present", **skips the upload**, and exits
> **0**. Hence `MANIFEST_UNKNOWN` / `BLOB_UNKNOWN` later, on a pull or a Kaniko build.
>
> Two tells refute the concurrency story outright: it destroyed **36 of 36** images (a *wipe*; a write
> race damages *some*), and **the failing run had no concurrent load at all**. Its prescribed cure — a
> clean rebuild — worked only because it also destroyed Redis.
>
> **Fixed in code:** the registry now gets a **PVC** (`persistence.enabled=true`), the installer is
> idempotent (no second upgrade; full desired state, not `--reuse-values`), the Redis descriptor cache is
> flushed after an upgrade with the DB index **read from `cm/harbor-registry`** rather than guessed, and
> **`mirror` now depends on `mirror-verify`** — a push you have not verified by *fetching* is not a mirror.
> *Proven:* cold cluster → mirror → `rollout restart deploy/harbor-registry` with **zero** concurrent load
> → `mirror-verify` still 36/36 intact. Before the fix, that same restart destroyed everything.
>
> **So why still serialize?** Because these operations mutate a **shared cluster and registry**, and
> parallel runs make any failure **unattributable** — not because they corrupt blobs. The `flock` guard on
> the mirror/builder pushes (`scripts/lib/os.sh:54-71`) stands on that reasoning.

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

- Broadcom TechDocs — Harbor Supervisor Service install / *Integrate VKS with a Private Registry*
  (9.1 URLs → 9.0 tree)
- williamlam.com (2025-08) — VKS private-registry quick-tip
- ogelbric/LAB — `Create_Harbor` (a working jump-box transcript)
