[![CI](https://github.com/AndriyKalashnykov/vks-cicd/actions/workflows/ci.yml/badge.svg)](https://github.com/AndriyKalashnykov/vks-cicd/actions/workflows/ci.yml)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/vks-cicd.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/vks-cicd/)

# Air-gapped CI/CD on VMware VKS — Reference Demo

Reference implementation of an end-to-end CI/CD pipeline for a **fully air-gapped**
VKS cluster (VMware vSphere Kubernetes Service, VCF 9 + Supervisor). The **pipeline
surface** wires self-hosted **Gitea** + **Tekton** (test → **Kaniko** build → **Harbor**
push → GitOps tag write-back) to the VKS-provided **Harbor** and **ArgoCD**; the
**delivery surface** covers an OS-portable (Ubuntu/PhotonOS) jump-box image mirror
(**skopeo**, dual-homed or sneakernet), a dependency-baked offline **Maven** builder, and a
one-command **KinD** end-to-end that proves the whole flow locally.

<p align="center"><img src="docs/diagrams/out/context.png" alt="System context: air-gapped CI/CD on VMware VKS" width="440"></p>

> A developer pushes a change to **Gitea** → **Tekton** runs tests, builds a container
> image with **Kaniko** and pushes it to **Harbor** → Tekton bumps the image tag in the
> deploy repo → **ArgoCD** syncs the new version to the cluster → the web UI updates.
> Harbor and ArgoCD are **provided by VKS**; this project mirrors all required images
> into Harbor and installs + wires **Gitea + Tekton** and the demo app.

## Quick Start (dual-homed jump box)

```bash
cp .env.example .env          # edit: Harbor/Gitea URLs, VKS access, CA files, secrets (see below)
make deps                     # [offline] install jump-box toolchain
make ci                       # [offline] lint + validate + app tests + docs
make install-all              # [cluster] mirror → builder → vks-login → platform → gitops
make verify                   # [cluster] end-to-end smoke test
```

`make install-all` runs, in order: `mirror` (pull images → Harbor) → `builder-image`
(build+push the offline Maven builder) → `vks-login` → `platform` (Gitea + Tekton) →
`gitops` (ArgoCD Application). Run `make help` for the full target list.

> **Try it with no VKS cluster:** `make e2e-kind` stands the whole thing up locally in
> KinD — see [Try it locally end-to-end with KinD](#try-it-locally-end-to-end-with-kind).

## Prerequisites

- A jump box running **Ubuntu** or **PhotonOS** with internet access.
- Network reach to the VKS Supervisor, Harbor, and (for dual-homed) the workload cluster.
- The Harbor (and Gitea, once installed) **CA certificates** (`.env` → `HARBOR_CA_FILE` / `GITEA_CA_FILE`).
- [mise](https://mise.jdx.dev/) for the toolchain (installed by `make deps` where possible).
- **docker or podman** on the jump box (to build + push the Maven builder image).

### Disk space on the jump box

Measured for the current image set (19 images: Tekton Pipelines+Triggers, Gitea,
Kaniko, Maven, Temurin JDK/JRE, alpine/git, yq). Figures are approximate.

| What | Where | Size |
|------|-------|------|
| Mirror image cache — **single-arch** (default, `MIRROR_ARCH=amd64`) | `bundle/images/` | **~3.0 GB** |
| Mirror image cache — **all architectures** (`MIRROR_ALL_ARCH=1`) | `bundle/images/` | ~5.2 GB |
| Maven builder image build (local docker/podman storage) | engine store | ~1.5 GB |
| Sneakernet bundle tarball (`RUN_MODE=sneakernet` only) | repo root | ~2.5 GB (on top of the cache) |

> Even in single-arch mode the **Tekton controller images stay multi-arch**
> (~2 GB of the 3 GB): they are digest-pinned in the release manifests, so their
> multi-arch list digest must be preserved for the pull to resolve. The single-arch
> saving therefore applies to the large tag-referenced images (Maven, Temurin, the builder).

**Recommended free space on the jump box:** **≥ 10 GB** dual-homed (cache + builder build +
overhead); **≥ 15 GB** sneakernet (adds the transferable bundle tarball). The **VKS/KinD
cluster** additionally stores these images in Harbor + each node's containerd (~5–6 GB) —
that is cluster-side, separate from the jump box.

## Architecture

Harbor + ArgoCD are **provided by VKS** (blue in the diagrams). The jump box mirrors every
image into Harbor; a `git push` then drives the whole CI/CD flow entirely inside the air gap.

### Containers

<p align="center"><img src="docs/diagrams/out/container.png" alt="Container diagram" width="900"></p>

### Deployment

<p align="center"><img src="docs/diagrams/out/deployment.png" alt="Deployment diagram" width="760"></p>

### Pipeline flow

<p align="center"><img src="docs/diagrams/out/pipeline-flow.png" alt="Pipeline flow" width="900"></p>

Diagram sources are committed under [`docs/diagrams/`](docs/diagrams/) (C4-PlantUML);
`make diagrams` re-renders the PNGs and `make diagrams-check` fails CI if they drift.

### Two operating modes

| Mode | When | Flow |
|------|------|------|
| **dual-homed** (default) | Jump box reaches internet **and** the VKS/Harbor network (routed to ESXi) | `make mirror` pulls + pushes in one run |
| **sneakernet** | Jump box has internet only | `make mirror-pull && make bundle` → carry the bundle → `make bundle-load && make mirror-push` inside |

Set `RUN_MODE` in `.env`.

## Try it locally end-to-end with KinD

You don't need a VKS cluster to exercise the whole pipeline. `make e2e-kind` stands up a
local [KinD](https://kind.sigs.k8s.io/) cluster, installs the "VKS-provided" pieces
(**Harbor** + **ArgoCD**) into it, then runs the exact same
`mirror → builder → platform → gitops → verify` flow the real environment uses. This path
is verified end-to-end (git push → Tekton build → Harbor → ArgoCD → the live app serves
the new version).

```bash
cp .env.example .env          # set HARBOR_PASSWORD + GITEA_ADMIN_PASSWORD (any demo values)
make deps                     # kind, helm, kubectl, skopeo, etc.
make e2e-kind                 # cluster → Harbor → ArgoCD → mirror → build → deploy → verify
# ... explore ...
make kind-down                # tear everything down (also prunes cloud-provider-kind orphans)
```

How the local stand-in works:

- **`cloud-provider-kind`** gives Harbor a real `LoadBalancer` IP on the kind docker
  network — reachable by the *same IP* from the host (push), Kaniko pods (push), and
  containerd (pull), which is what makes one image ref work everywhere.
- Harbor runs **plain HTTP**; `kind-up`/`install-harbor` wire each node's containerd
  (`/etc/containerd/certs.d`) to pull from it insecurely, and write the discovered
  `HARBOR_URL` (the LB IP) + `KUBECONFIG` into a gitignored **`.env.kind`** overlay so the
  normal scripts target the kind cluster unchanged.
- `make vks-login` uses the kind kubeconfig (`VKS_AUTH_METHOD=kubeconfig`), so no VCF auth
  is needed for the local run.

Individual targets: `make kind-up`, `make install-harbor`, `make install-argocd`.

## Detailed steps

Legend: **[offline]** verifiable without a cluster · **[cluster]** runs against live VKS.

| # | Command | Mode | What happens |
|---|---------|------|--------------|
| 1 | `cp .env.example .env` + edit | [offline] | Set Harbor/Gitea URLs, VKS auth, CA files, and secrets (`HARBOR_PASSWORD`, `GITEA_ADMIN_PASSWORD`). |
| 2 | `make deps` | [offline] | `mise install` + `scripts/00-install-prereqs.sh` (skopeo, tkn, argocd, kubectl, helm, jq, yq). |
| 3 | `make ci` | [offline] | shellcheck + yamllint + hadolint + kubeconform + `mvn test` + docs/diagram checks. |
| 4 | `make mirror` | [cluster] | `10-mirror-pull.sh` pulls all images (+ Tekton release manifests) then `21-mirror-push.sh` pushes them into Harbor. **Sneakernet:** `make mirror-pull && make bundle`, carry the bundle, then `make bundle-load BUNDLE_TARBALL=… && make mirror-push` inside. |
| 5 | `make builder-image` | [internet] | Builds the Maven builder image with this app's deps pre-baked and pushes it to Harbor (so in-cluster CI builds offline). |
| 6 | `make vks-login` | [cluster] | `30-vks-login.sh` writes a working `$KUBECONFIG`/context (see auth note). |
| 7 | `make platform` | [cluster] | Installs Gitea (`k8s/gitea/`), seeds the two repos + webhook, installs Tekton (images remapped to Harbor), applies the pipeline/triggers. |
| 8 | `make gitops` | [cluster] | Registers the deploy repo and creates the ArgoCD `Application` (auto-sync). |
| 9 | `make verify` | [cluster] | Pushes a marked change to `webui-app`, then asserts: PipelineRun succeeds → image in Harbor → deploy tag bumped → ArgoCD Synced/Healthy → the live page shows the marker. |

### Minimum `.env` you must set

```bash
HARBOR_URL=harbor.<your-domain>          # provided by VKS
HARBOR_PASSWORD=<robot-or-admin-secret>  # never committed
HARBOR_CA_FILE=./secrets/harbor-ca.crt   # the Harbor CA (self-signed)
GITEA_URL=http://gitea.<your-domain>
GITEA_ADMIN_PASSWORD=<choose-one>
ARGOCD_NAMESPACE=argocd                  # where VKS runs ArgoCD
KUBECONFIG=./secrets/vks.kubeconfig      # produced by make vks-login
```

## Repository layout

| Path | Purpose |
|------|---------|
| `scripts/` | Ordered, OS-portable (Ubuntu+PhotonOS) automation; `lib/os.sh` + `lib/mirror.sh` are shared libraries |
| `app/` | Minimal Spring Boot web UI (seeded into Gitea `webui-app`); `Dockerfile` + `Dockerfile.builder` |
| `deploy/base/` | Kustomize manifests ArgoCD deploys (seeded into Gitea `webui-deploy`) |
| `tekton/` | Tekton pipeline, tasks, triggers, RBAC |
| `argocd/` | ArgoCD `Application` definition |
| `k8s/gitea/` | Gitea install manifest (SQLite, single image) |
| `kind/` | KinD cluster config (containerd insecure-registry wiring) |
| `docs/diagrams/` | C4-PlantUML sources + rendered PNGs |
| `images/images.txt` | Authoritative image inventory to mirror |
| `.env.example` | Committed source of truth for every tunable |

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on push to `main`, tags `v*`, and pull requests.

| Job | Runs | Purpose |
|-----|------|---------|
| **changes** | always | `dorny/paths-filter` classifies the diff into `code` / `docs` |
| **static-check** | if `code` changed | `make static-check` — shellcheck, yamllint, hadolint, kubeconform, `mvn test` |
| **docs-lint** | if `docs` changed | `make docs-lint` — markdownlint + `diagrams-check` (PNG drift vs `.puml`) |
| **ci-pass** | always | Aggregator; the single required status check — green only if the needed jobs passed |

Locally, `make ci` runs the same gates (`static-check` + `docs-lint`).

## Configuration

Everything is driven by `.env` (copied from `.env.example`), with an optional `.env.kind`
overlay written by the KinD flow. Nothing is hardcoded in scripts or the Makefile. See
`.env.example` for the full, documented list of tunables.

## VKS authentication (VCF 9 + Supervisor)

`scripts/30-vks-login.sh` is the single pluggable step that produces a working
`KUBECONFIG` and context; everything downstream is auth-agnostic. It supports `kubeconfig` (bring your own),
`vcf` (VCF CLI, token-based in vSphere 9 — finalized once confirmed for the target
environment), and legacy `vsphere` (kubectl-vsphere plugin) methods via `VKS_AUTH_METHOD`.
