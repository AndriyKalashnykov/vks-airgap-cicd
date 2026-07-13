# Sizing reference — jump box + guest cluster

<br>

**Jump-box disk space** — measured for the current image set (~30 images: 9 pinned in
[`images/images.txt`](images/images.txt) plus the Tekton Pipelines+Triggers controller
images pulled from their release manifests, which dominate the count — alongside Gitea,
Kaniko, Maven, Temurin JDK/JRE, alpine/git, yq, and the ingress images). Figures are approximate.

| What | Where | Size |
|------|-------|------|
| Mirror image cache — **single-arch** (default, `MIRROR_ARCH=amd64`) | `bundle/images/` | **~3.0 GB** |
| Mirror image cache — **all architectures** (`MIRROR_ALL_ARCH=1`) | `bundle/images/` | ~5.2 GB |
| Maven builder image build (local docker/podman storage) | engine store | ~1.5 GB |
| Sneakernet bundle tarball (sneakernet flow only) | repo root | ~2.5 GB (on top of the cache) |

> Even in single-arch mode the **Tekton controller images stay multi-arch**
> (~2 GB of the 3 GB): they are digest-pinned in the release manifests, so their
> multi-arch list digest must be preserved for the pull to resolve. The single-arch
> saving therefore applies to the large tag-referenced images (Maven, Temurin, the builder).

## What each app costs

The two apps are not decoration — **they are the air-gap story**, and the sizes show why. Measured
(registry-compressed, `linux/amd64`; the app images are the ones the pipeline actually built in the
last KinD run):

| | **Java** (`javawebapp`) | **Go** (`gowebapp`) |
|---|---|---|
| build image | `maven:3.9-eclipse-temurin-25` — **168 MB** | `golang:1.26.5-bookworm` — **283 MB** |
| **offline builder** (deps pre-baked) | `javawebapp-builder` — **292 MB** | **none needed** — the app is stdlib-only, so its air-gapped build fetches nothing |
| runtime base | `eclipse-temurin:…-jre-jammy` — **99 MB** | `distroless/static-debian12` — **1 MB** |
| **the app image the pipeline builds** | **130 MB** | **4.85 MB** |
| **≈ per-app total** | **~690 MB** | **~290 MB** |

Two things worth reading off that table:

- **The Go app's runtime image is ~27× smaller** (4.85 MB vs 130 MB): a static binary on
  `distroless/static` versus a JAR on a JRE.
- **The Java app needs a pre-baked dependency cache and the Go app does not.** An in-cluster `mvn`
  cannot reach Maven Central, so `Dockerfile.builder` bakes the whole `~/.m2` on the internet side
  (that is the 292 MB). A stdlib-only Go build needs nothing — same pipeline, one `case` branch.

> **These do not simply add up.** Layers are **shared and de-duplicated** in the registry and in each
> node's containerd: `javawebapp:<sha>` sits on the *same* Temurin JRE layers already mirrored, and
> the builder shares the Maven image's base. Treat the per-app figures as the **marginal** cost of
> adding that language, not as slices of a pie.

**Everything else is shared infrastructure** — Tekton (Pipelines + Triggers + Dashboard, which
dominate the count and ~2 GB of the mirror), Gitea, Kaniko, Harbor, the ingress, `alpine/git`, `yq`.
Adding a *third app in an existing language* costs only its own app image; a **new language** adds a
build image + a runtime base (+ a builder image only if that language cannot build offline
unaided).

**Recommended free space on the jump box:** **≥ 10 GB** dual-homed (cache + builder build +
overhead); **≥ 15 GB** sneakernet (adds the transferable bundle tarball). The **VKS/KinD
cluster** additionally stores these images in Harbor + each node's containerd (~5–6 GB) —
that is cluster-side, separate from the jump box.

**Guest (VKS workload) cluster sizing** — sizing for the **guest cluster** where this project deploys **Gitea + Tekton (+ Dashboard) +
the demo apps** and their images. Harbor and ArgoCD run on the **Supervisor** as VCF Supervisor Services, so they are budgeted
separately (see the last bullet). Figures were measured on the live single-node KinD stack
(no metrics-server, so per-pod RAM is the declared request or a working-set estimate).

| Tier | vCPU | RAM | Disk | Fits |
|------|------|-----|------|------|
| **Minimum** | 4 | 8 GB | 40 GB | steady state + one pipeline; pipelines serialize, no concurrency headroom |
| **Recommended** | 6 | 12 GB | 60 GB | comfortable single pipeline + ~30% headroom + image-growth room |
| **Comfortable** | 8 | 16 GB | 80–100 GB | 2–3 concurrent PipelineRuns, production-ish headroom |

- **What dominates the baseline:** the steady-state RAM *request* is ~3.7 GiB, of which
  **istiod alone reserves 2 GiB** (its real working set is ~150–200 MiB). Choosing
  `INGRESS_CONTROLLER=traefik` (single binary, ~128 MiB) frees ~2 GiB + ~0.5 vCPU — the
  Minimum tier then drops to **4 vCPU / 6 GB**.
- **The spikes are the pipeline pods.** `maven-test` (offline JVM build, ~1–1.5 GiB) and
  `kaniko-build` (image build, ~1.5–2 GiB) run **sequentially**, so a single-pipeline peak is
  the baseline **+ ~2 vCPU / ~2 GiB**; each *concurrent* run adds that again. These pods
  declare no limits, so the cluster needs real headroom for them.
- **Disk:** ~6 GB of mirrored + built images in the node's containerd, a 5 GB Gitea PVC, a
  2 GB CI workspace, plus transient kaniko/maven scratch and a new `<app>:<sha>` image per app per
  run (budget growth room — hence the 40 → 100 GB range).
- **If Harbor + ArgoCD are co-located** in this same guest cluster (instead of provided
  externally), add roughly **+2 vCPU / +4 GB RAM / +5 GB disk** to each tier.

---

[← back to the README](../README.md)
