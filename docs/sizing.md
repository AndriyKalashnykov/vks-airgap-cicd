# Sizing reference — jump box + guest cluster

<br>

**Jump-box disk space** — measured for the current image set (~30 images: 11 pinned in
[`images/images.txt`](../images/images.txt) plus the Tekton Pipelines+Triggers controller
images pulled from their release manifests, which dominate the count — alongside Gitea,
Kaniko, Maven, Temurin JDK/JRE, alpine/git, yq, and the ingress images). Figures are approximate.

| What | Where | Size |
|------|-------|------|
| Mirror image cache — **single-arch** (default, `MIRROR_ARCH=amd64`) | `bundle/images/` | **~3.0 GB** |
| Mirror image cache — **all architectures** (`MIRROR_ALL_ARCH=1`) | `bundle/images/` | ~5.2 GB |
| Builder images — **all six apps** (local docker/podman storage) | engine store | **~4.3 GB** |
| Their six upstream base images (pulled to build them) | engine store | **~3.3 GB** |
| Sneakernet bundle tarball (sneakernet flow only) | repo root | ~2.5 GB (on top of the cache) |

## Builder images — the number that changed when the demo went to six apps

Every app ships a `Dockerfile.builder` whose whole job is to bake its dependency cache, because an
in-cluster build reaches no package registry. That is six images, not one, and they are the largest
thing the jump box builds. * `linux/amd64`, current pins):

| app | builder image | its upstream base |
|---|---:|---:|
| rustwebapp | **1.57 GB** | `rust:1.98-alpine` 1.03 GB |
| gowebapp | **1.00 GB** | `golang:1.27.0-bookworm` 871 MB |
| dotnetwebapp | **967 MB** | `mcr…/dotnet/sdk:10.0-alpine` 762 MB |
| javawebapp | **622 MB** | `maven:3.9-eclipse-temurin-25` 494 MB |
| nodejswebapp | **178 MB** | `node:24-alpine` 169 MB |
| pythonwebapp | **105 MB** | `python:3.14-alpine` 50 MB |
| **total** | **≈ 4.3 GB** | **≈ 3.3 GB** |

### What each language actually requires

Derived from each app's `Dockerfile.builder` / `Dockerfile` (so it cannot drift from the code):

| app | build image | runtime base | cache it bakes | fetched from |
|---|---|---|---|---|
| `javawebapp` | `maven:3.9-eclipse-temurin-25` | `eclipse-temurin:…-jre-jammy` | `~/.m2` | `repo.maven.apache.org` |
| `gowebapp` | `golang:1.27.0-bookworm` | `distroless/static-debian12` | Go module cache | `proxy.golang.org` |
| `nodejswebapp` | `node:24-alpine` | `node:24-alpine` | `node_modules` | `registry.npmjs.org` |
| `pythonwebapp` | `python:3.14-alpine` | `python:3.14-alpine` | the venv | `pypi.org` |
| `rustwebapp` | `rust:1.98-alpine` | `distroless/static-debian12` | cargo registry | `crates.io` |
| `dotnetwebapp` | `mcr…/dotnet/sdk:10.0-alpine` | `mcr…/dotnet/aspnet:10.0-noble-chiseled` | NuGet cache | `api.nuget.org` |

**The jump box needs egress to ALL SIX package registries** — `builder-build` fails on whichever one
is blocked. The `fetched from` column names each ecosystem's PRIMARY host; it is **not a complete
firewall allowlist**, because several tools also contact a sibling host (Go a checksum DB, pip a
file CDN, cargo a separate index and CDN). If you must build an allowlist, derive it by running
`make builder-build` behind a logging proxy — do not transcribe this table. Two apps (`nodejswebapp`, `pythonwebapp`) run on their build image
as the runtime base; two (`gowebapp`, `rustwebapp`) ship a static binary on `distroless/static`.

Realistic floor for a **dual-homed six-app walk**, measured against a box that hit `ENOSPC` at 15 G used:

| component | size |
|---|---:|
| OS + toolchain + repo | ~4.0 GB |
| `bundle/images/` (crane OCI layout, separate store) | ~3.0 GB |
| engine store (six bases **once** + six deltas) | ~4.0 GB |
| `bundle/builders/*.tar` (uncompressed docker-archives) | ~4.3 GB |
| **core total** | **≈ 15.3 GB** |
| with 30% headroom | **≈ 20 GB** |

Both columns are live at once during `make builder-image` / `make builder-build` — but **they do not
add up**, and the difference matters. A builder image *contains* its base's layers (`FROM <base>`
makes them its parent layers), so the engine store holds each base **once** plus a small per-app
delta. MEASURED on the walkthrough VM: the reported sizes sum to 6.29 GB while the store held
**3.7 GB**, and the model `bases + deltas` predicts that to within 1.1% (deltas: go +114 MB, java
+105, node +6, python +55, rust +180). **Consequence: `podman rmi <base>` while its builder exists
frees ≈ 0 bytes** — the deduplication has already happened, so "prune the bases to make room" is not
a lever.

The term that *is* easy to miss: `14-builder-build.sh` also `podman save`s every builder into
`bundle/builders/*.tar` as uncompressed docker-archives — **another ≈ 4.3 GB** — and it does so on
the **dual-homed** path too, because `make builder-image` is a thin orchestrator over that same
script. `bundle/images/` (crane's OCI layout) is a **separate** store from podman's, so those really
are second copies.

> **This is what a 16 GB ROOT FILESYSTEM runs out of, and it fails at the LAST app.**
> 16 GB Photon walkthrough VM: `make install-all` died in `builder-image` on the **sixth** builder —
> `Error: committing container … no space left on device` while unpacking the NuGet cache — with
> `/dev/sda2 16G 15G 558M 97%`. The VM's virtual disk was **40 GiB** — `lsblk` showed `sda` at 40 GiB
> with `sda2` at only 16 GiB and ~24 GiB unallocated behind it, because the Photon GCE base image ships
> a 16 GiB root layout and nothing grew it at first boot. **Check the PARTITION, not just the disk.** The failure then arrives **disguised**: `install-all` never reaches
> `platform → seed-gitea`, so the next step reports `missing secrets/gitea-ci-token — run 'make
> seed-gitea' first`, which sends you to Gitea instead of to the disk. If you see that token error,
> check `df -h /` before anything else — and see the note below: on the walkthrough VM the disk was
> not too small, its filesystem had simply never grown into it.
On the mirror cache itself:
> Even in single-arch mode the **Tekton controller images stay multi-arch**
> (~2 GB of the 3 GB): they are digest-pinned in the release manifests, so their
> multi-arch list digest must be preserved for the pull to resolve. The single-arch
> saving therefore applies to the large tag-referenced images (Maven, Temurin, the builder).

## Java vs Go — a two-language deep-dive on build vs delivery cost

⚠️ **This section covers TWO of the six apps.** It predates the six-app table above and is kept
because the Java-vs-Go contrast is the clearest illustration of the build-side / delivery-side
split. It is **not** the full image set — the builder figures above are, and they are newer. Node.js,
Python, Rust and .NET are not attributed here; their builder sizes are in the six-app table.

Measured (registry-compressed, `linux/amd64`; the app images are the ones the pipeline actually
built in a KinD run).

| Bucket | Image | Size |
|---|---|---|
| **Java** | `maven` build image (tag pinned in `images/images.txt`) | 168 MB |
| **Java** | `eclipse-temurin:…-jre-jammy` (runtime base) | 99 MB |
| **Java** | `javawebapp-builder` — **offline builder, `~/.m2` pre-baked** (built on the jump box, pushed to Harbor) | **292 MB** |
| **Java** | `javawebapp:<sha>` — the image the pipeline builds | 130 MB |
| | **Java total** | **≈ 690 MB** |
| **Go** | `golang` build image (tag pinned in `images/images.txt`) | 287 MB |
| **Go** | `distroless/static-debian12` (runtime base) | 1 MB |
| **Go** | `gowebapp-builder` — **offline builder, module cache pre-baked** | *not measured registry-compressed.* The six-app table above reports **1.00 GB LOCAL** — a different unit, so it cannot be added to this column. The row used to say "none"; that was wrong. |
| **Go** | `gowebapp:<sha>` — the image the pipeline builds | **4.85 MB** |
| | **Go total** | **≈ 293 MB** — EXCLUDING the builder, which is not measured in this unit |
| **Shared** | Tekton (Pipelines + Triggers + Dashboard) | **~2 GB** — dominates the mirror |
| **Shared** | `gitea` 62 · `istio/proxyv2` 87 · `istio/pilot` 72 · `kaniko` 44 · `alpine/git` 35 · `traefik` 52 · `yq` 9 | 362 MB |
| | **Shared total** | **≈ 2.4 GB** |

### The three things this table says

1. **On the BUILD side the languages cost about the same** — Java 267 MB of mirrored images
   (maven + JRE) vs Go 284 MB (the `golang` image alone is *bigger* than Maven's). The interesting
   difference is not the compiler.
2. **EVERY app needs an offline builder — and they cost wildly different amounts.** An in-cluster
   build reaches no package registry, so each `Dockerfile.builder` bakes that language's cache on the
   internet side. Java's `~/.m2` is the **292 MB** in this compressed column. It is NOT the largest in
   the repo — by the local measure in the six-app table above, **rust (1.57 GB) and go (1.00 GB) are
   both bigger than java (622 MB)**. Same pipeline, one `case` branch in `lib/apps.sh`.
3. **On the DELIVERY side Go wins by ~27×** — a 4.85 MB static binary on `distroless/static` versus a
   130 MB JAR on a JRE. That is what you ship, and re-ship on every commit.

> **These do not simply add up.** Layers are **shared and de-duplicated** in the registry and in each
> node's containerd: `javawebapp:<sha>` sits on the *same* Temurin JRE layers already mirrored, and
> the builder shares Maven's base. Read the per-language figures as the **marginal** cost of adding
> that language, not as slices of a pie.

Adding a **third app in an existing language** costs only its own app image (≈130 MB Java, ≈5 MB Go).
Adding a **new language** costs a build image + a runtime base — plus an offline builder **only if
that language cannot build offline unaided**.

**Recommended free space on the jump box:** **≥ 20 GB** dual-homed and **≥ 25 GB** sneakernet
(which adds the transferable bundle tarball). RAISED 2026-08-23 from 10/15 GB, which was sized when the
demo shipped ONE builder: six builders + six bases are ≈ 7.6 GB by themselves, and a 16 GB box was
measured failing at 97% full on the sixth. The **VKS/KinD cluster** additionally stores these images in
Harbor + each node's containerd (~5–6 GB) —

**Guest (VKS workload) cluster sizing** — sizing for the **guest cluster** where this project deploys **Gitea + Tekton (+ Dashboard) +
the demo apps** and their images. Harbor and ArgoCD run on the **Supervisor** as Supervisor Services, so they are budgeted
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
