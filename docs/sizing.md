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

**Recommended free space on the jump box:** **≥ 10 GB** dual-homed (cache + builder build +
overhead); **≥ 15 GB** sneakernet (adds the transferable bundle tarball). The **VKS/KinD
cluster** additionally stores these images in Harbor + each node's containerd (~5–6 GB) —
that is cluster-side, separate from the jump box.

**Guest (VKS workload) cluster sizing** — sizing for the **guest cluster** where this project deploys **Gitea + Tekton (+ Dashboard) +
the javawebapp app** and its images. Harbor and ArgoCD run on the **Supervisor** as VCF Supervisor Services, so they are budgeted
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
  2 GB CI workspace, plus transient kaniko/maven scratch and a new `javawebapp:<sha>` image per
  run (budget growth room — hence the 40 → 100 GB range).
- **If Harbor + ArgoCD are co-located** in this same guest cluster (instead of provided
  externally), add roughly **+2 vCPU / +4 GB RAM / +5 GB disk** to each tier.

---

[← back to the README](../README.md)
