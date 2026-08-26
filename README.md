[![CI](https://img.shields.io/github/actions/workflow/status/AndriyKalashnykov/vks-airgap-cicd/ci.yml?branch=main&label=CI&style=flat)](https://github.com/AndriyKalashnykov/vks-airgap-cicd/actions/workflows/ci.yml)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovatebot&style=flat)](https://docs.renovatebot.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen?style=flat)](LICENSE)

# Air-gapped CI/CD on VMware VKS

Reference implementation of an end-to-end CI/CD pipeline for a **fully air-gapped** VKS cluster
(VMware vSphere Kubernetes Service, VCF 9 + Supervisor).

- **Pipeline** — self-hosted **Gitea** + **Tekton**: test → **Kaniko** build → **Harbor** push →
  GitOps tag write-back → **ArgoCD** sync → the live page.
- **Delivery** — an OS-portable (Ubuntu / PhotonOS) jump-box image mirror (**crane**, dual-homed or
  **[sneakernet](docs/sneakernet.md)**), a pre-baked offline builder image per language, an optional
  ingress fronting the UIs at `*.vks.local`, and a **KinD** end-to-end that proves the flow locally.

On VKS, **Harbor** and **ArgoCD** are **Supervisor Services** — you either install them, or they
already exist and you are a tenant. **Istio** is a guest-cluster **VKS Standard Package**, so this
project *attaches* to a mesh that already exists (`INGRESS_CONTROLLER=istio-existing`) and installs
its own only when there is none — `make istio-preflight` tells you which case you are in. What this
project always owns: mirroring every required image into Harbor, and installing and wiring
**Gitea + Tekton** and the demo apps.

The ingress is **optional** — it only decides *how you reach the UIs*. The pipeline is verified over
a port-forward, so it needs no ingress and no `/etc/hosts` entry.

<p align="center"><img src="docs/diagrams/out/airgap.png" alt="Air-gap connectivity: the jump box bridges the internet and the air-gapped VKS cluster" width="760"></p>

<p align="center"><em>The jump box is the only bridge — it pulls from the internet and pushes into the air gap.</em></p>

## What the demo deploys

**Six apps, one per language** — Java, Go, Node.js, Python, Rust and .NET — each run through the
*same* pipeline and verified independently. `apps/registry.tsv` is the single source of truth;
everything else loops over it.

An in-cluster build reaches no package registry, so every app ships a **pre-baked builder image**
(`Dockerfile.builder`) carrying its own dependency cache — `~/.m2` for Java, the module cache for Go,
and so on. All are built on the internet-connected jump box, pushed to Harbor, and consumed offline.

Adding an app is **one row** in `apps/registry.tsv` — see [Adding an app](docs/adding-an-app.md).

## Choose your path

Pick the one that matches your situation and follow it in order — each is self-contained end to end.

| I want to… | Path | You need |
|------------|------|----------|
| **Install Harbor + ArgoCD myself** (I am the admin) | [Scenario 1](docs/scenario-1.md) | a vSphere login that can install a Supervisor Service |
| **They already exist** (I am a **tenant**) | [Scenario 2](docs/scenario-2.md) | cluster-admin on your own guest cluster |
| **Just see it work** (no VKS cluster) | [KinD](docs/kind-local.md) | Docker · internet access · **zero `.env`** |

Both VKS paths start with the shared [Common bootstrap](docs/common-bootstrap.md). Once the stack is
up: **[Access the UIs](docs/access-uis.md)** for URLs, logins and passwords.

If no single box reaches **both** the internet *and* Harbor, mirror via
**[sneakernet](docs/sneakernet.md)** — pull on the internet box, carry the bundle, push from the
air-gap box.

**Container engine:** podman is the default and needs no action. Docker is supported opt-in — see
[container engine](docs/decisions/container-engine-support.md). `make e2e-kind` needs Docker
regardless, because kind's nodes *are* docker containers.

## Reference

Deep-dives. Each path names the ones it needs, so you do not have to read these first.

| | |
|---|---|
| [Architecture](docs/architecture.md) | system context, containers, deployment, pipeline flow |
| [Tech stack](docs/tech-stack.md) | what the demo is built from |
| [Prerequisites — the manual path](docs/prerequisites-manual.md) | the step-by-step the bootstrap automates |
| [Sizing](docs/sizing.md) | jump-box disk + guest-cluster resources |
| [Repository layout](docs/repository-layout.md) | where things live |
| [Adding an app](docs/adding-an-app.md) | one row in `apps/registry.tsv` — what loops over it, and what a tenant must request |
| [Make targets](docs/make-targets.md) | a **curated subset** with context — `make help` is the exhaustive list |
| [CI/CD](docs/ci-cd.md) | what CI actually gates (and what it deliberately does not) |
| [VKS authentication](docs/vks-authentication.md) | how `$KUBECONFIG` is produced on VKS (`VKS_AUTH_METHOD`, the `vcf` CLI flow), and **why Scenario 1 needs a second kubeconfig**. Both VKS scenarios run `make vks-login` themselves; **the KinD path skips it entirely** |
| [Demo walkthrough](docs/demo-walkthrough.md) | drive the GitOps loop by hand |
| [VKS services](docs/vks-services/) | what Broadcom ships (Harbor / ArgoCD / Istio), and how confident we are in each fact |
| [Decisions](docs/decisions/) | one document per design decision, with the evidence behind it |

## Contributing

Open an issue or a pull request. Before you push:

```bash
make ci
```

`make ci` is a superset of what a PR runs, so a green `make ci` can still differ from CI — see
[CI/CD](docs/ci-cd.md).

**Do not bump tool or image versions by hand** — [Renovate](https://docs.renovatebot.com/) owns
them. The same version lives in several files and an alignment gate asserts they agree, so a partial
hand-edit fails `make ci`.

## License

Released under the [MIT License](LICENSE).
