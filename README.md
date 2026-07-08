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

## Quickstart

```bash
git clone <this-repo> vks-cicd && cd vks-cicd
cp .env.example .env         # edit: Harbor/Gitea URLs, VKS access, CA files, secrets
make deps                    # [offline] install jump-box toolchain
make ci                      # [offline] lint + validate + app tests

# On the jump box, against live VKS:
make mirror                  # [cluster] pull images → push to Harbor  (dual-homed)
make vks-login               # [cluster] authenticate to VKS (VCF 9 + Supervisor)
make platform                # [cluster] install + wire Gitea and Tekton
make gitops                  # [cluster] create the ArgoCD Application
make verify                  # [cluster] end-to-end smoke test
```

Run `make help` for the full target list.

## Repository layout

| Path | Purpose |
|------|---------|
| `scripts/` | Ordered, OS-portable (Ubuntu+PhotonOS) automation; `lib/os.sh` is the shared library |
| `app/` | Minimal Spring Boot web UI (seeded into Gitea `webui-app`) |
| `deploy/` | Kustomize manifests ArgoCD deploys (seeded into Gitea `webui-deploy`) |
| `tekton/` | Tekton pipeline, tasks, and triggers |
| `argocd/` | ArgoCD `Application` definition |
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
