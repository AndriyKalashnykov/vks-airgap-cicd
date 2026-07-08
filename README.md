# vks-cicd — Air-gapped VKS end-to-end CI/CD demo

A self-contained demonstration of a complete CI/CD pipeline running on a **fully
air-gapped VKS cluster** (VMware vSphere Kubernetes Service, VCF 9 + Supervisor):

> A developer pushes a change to **Gitea** → **Tekton** runs tests, builds a
> container image with **Kaniko**, and pushes it to **Harbor** → Tekton bumps the
> image tag in the deploy repo → **ArgoCD** syncs the new version to the cluster →
> the web UI updates.

Harbor and ArgoCD are **provided by VKS**. This project mirrors all required images
into Harbor and installs + wires **Gitea + Tekton** and the demo app.

> ⚠️ **Status:** work in progress. This README's command flow is being built out
> phase by phase (see `plan`/`CLAUDE.md`). Steps are marked
> **[offline]** (validated without a cluster) or **[cluster]** (runs on live VKS).

## Architecture

```
INTERNET SIDE (jump box: Ubuntu or PhotonOS)   AIR GAP (VKS: Harbor + ArgoCD given)
────────────────────────────────────────────  ────────────────────────────────────
skopeo pull images.txt ──(dual-homed / bundle)──▶ Harbor  (CI/CD + build-base images)
                                                    │
                                        install  ──▶ Gitea  (webui-app, webui-deploy)
                                        install  ──▶ Tekton (Pipelines + Triggers)
                                                    │
  git push ─▶ Gitea webhook ─▶ Tekton EventListener ─▶ PipelineRun:
     clone → mvn test → mvn package → kaniko build+push→Harbor → write-back tag→webui-deploy
                                                    │
                                 ArgoCD (tracks webui-deploy) ─▶ sync ─▶ Deployment/Service
                                                                            │
                                                                    web UI reachable
```

## Two operating modes

| Mode | When | Flow |
|------|------|------|
| **dual-homed** (default) | Jump box reaches internet **and** the VKS/Harbor network (routed to ESXi) | `make mirror` pulls + pushes in one run |
| **sneakernet** | Jump box has internet only | `make mirror-pull && make bundle` → carry the bundle → `make bundle-load && make mirror-push` inside |

Set `RUN_MODE` in `.env`.

## Prerequisites

- A jump box running **Ubuntu** or **PhotonOS** with internet access.
- Network reach to the VKS Supervisor, Harbor, and (for dual-homed) the workload cluster.
- The Harbor (and Gitea, once installed) **CA certificates** (`.env` → `HARBOR_CA_FILE` / `GITEA_CA_FILE`).
- [mise](https://mise.jdx.dev/) for the toolchain (installed by `make deps` where possible).

## Quickstart (dual-homed jump box)

```bash
git clone <this-repo> vks-cicd && cd vks-cicd
cp .env.example .env          # edit: Harbor/Gitea URLs, VKS access, CA files, secrets (see below)
make deps                     # [offline] install jump-box toolchain
make ci                       # [offline] lint + validate + app tests
make install-all              # [cluster] mirror → builder → vks-login → platform → gitops
make verify                   # [cluster] end-to-end smoke test
```

`make install-all` runs, in order: `mirror` (pull images → Harbor) → `builder-image`
(build+push the offline Maven builder) → `vks-login` → `platform` (Gitea + Tekton) →
`gitops` (ArgoCD Application). Run `make help` for the full target list.

## Detailed steps

Legend: **[offline]** verifiable without a cluster · **[cluster]** runs against live VKS.

| # | Command | Mode | What happens |
|---|---------|------|--------------|
| 1 | `cp .env.example .env` + edit | [offline] | Set Harbor/Gitea URLs, VKS auth, CA files, and secrets (`HARBOR_PASSWORD`, `GITEA_ADMIN_PASSWORD`). |
| 2 | `make deps` | [offline] | `mise install` + `scripts/00-install-prereqs.sh` (skopeo, tkn, argocd, kubectl, helm, jq, yq). |
| 3 | `make ci` | [offline] | shellcheck + yamllint + hadolint + kubeconform + `mvn test`. |
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
| `images/images.txt` | Authoritative image inventory to mirror |
| `.env.example` | Committed source of truth for every tunable |

## Configuration

Everything is driven by `.env` (copied from `.env.example`). Nothing is hardcoded
in scripts or the Makefile. See `.env.example` for the full, documented list.

## VKS authentication (VCF 9 + Supervisor)

`scripts/30-vks-login.sh` is the single pluggable step that produces a working
`KUBECONFIG` + context; everything downstream is auth-agnostic. The exact login
command (VCF CLI, token-based in vSphere 9) is finalized once confirmed for the
target environment.
