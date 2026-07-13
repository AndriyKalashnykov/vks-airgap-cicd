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

## What each language costs — every image, attributed

The two apps are not decoration — **they are the air-gap story**. Below is the **entire image set**,
each image attributed to the language that needs it. Measured (registry-compressed, `linux/amd64`;
the app images are the ones the pipeline actually built in the last KinD run).

| Bucket | Image | Size |
|---|---|---|
| **Java** | `maven:3.9-eclipse-temurin-25` (build) | 168 MB |
| **Java** | `eclipse-temurin:…-jre-jammy` (runtime base) | 99 MB |
| **Java** | `javawebapp-builder` — **offline builder, `~/.m2` pre-baked** (built on the jump box, pushed to Harbor) | **292 MB** |
| **Java** | `javawebapp:<sha>` — the image the pipeline builds | 130 MB |
| | **Java total** | **≈ 690 MB** |
| **Go** | `golang:1.26.5-bookworm` (build) | 283 MB |
| **Go** | `distroless/static-debian12` (runtime base) | 1 MB |
| **Go** | *offline builder* | **none — the app is stdlib-only, so its air-gapped build fetches nothing** |
| **Go** | `gowebapp:<sha>` — the image the pipeline builds | **4.85 MB** |
| | **Go total** | **≈ 290 MB** |
| **Shared** | Tekton (Pipelines + Triggers + Dashboard) | **~2 GB** — dominates the mirror |
| **Shared** | `gitea` 62 · `istio/proxyv2` 87 · `istio/pilot` 72 · `kaniko` 44 · `alpine/git` 35 · `traefik` 52 · `yq` 9 | 362 MB |
| | **Shared total** | **≈ 2.4 GB** |

### The three things this table says

1. **On the BUILD side the two languages cost about the same** — Java 267 MB of mirrored images
   (maven + JRE) vs Go 284 MB (the `golang` image alone is *bigger* than Maven's). The interesting
   difference is not the compiler.
2. **Java needs an offline builder and Go does not.** An in-cluster `mvn` cannot reach Maven Central,
   so `Dockerfile.builder` bakes the whole `~/.m2` on the internet side — that is the **292 MB**, and
   it is the single largest per-language cost in the repo. A stdlib-only Go build fetches **nothing**.
   Same pipeline, one `case` branch in `lib/apps.sh`.
3. **On the DELIVERY side Go wins by ~27×** — a 4.85 MB static binary on `distroless/static` versus a
   130 MB JAR on a JRE. That is what you ship, and re-ship on every commit.

> **These do not simply add up.** Layers are **shared and de-duplicated** in the registry and in each
> node's containerd: `javawebapp:<sha>` sits on the *same* Temurin JRE layers already mirrored, and
> the builder shares Maven's base. Read the per-language figures as the **marginal** cost of adding
> that language, not as slices of a pie.

Adding a **third app in an existing language** costs only its own app image (≈130 MB Java, ≈5 MB Go).
Adding a **new language** costs a build image + a runtime base — plus an offline builder **only if
that language cannot build offline unaided**.

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
