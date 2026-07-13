# Architecture

<br>

Harbor + ArgoCD are **Supervisor Services** — you install them (Scenario 1) or the platform team already has (Scenario 2); the [cluster-topology diagram](../README.md#cluster-topology-VKS) is the one that shows where they actually run (the context/container/deployment diagrams below draw the **collapsed** single-cluster view the KinD stand-in uses). The jump box mirrors every
image into Harbor; a `git push` then drives the whole CI/CD flow entirely inside the air gap.

## System context

<p align="center"><img src="docs/diagrams/out/context.png" alt="System context: air-gapped CI/CD on VMware VKS" width="640"></p>

### Containers

<p align="center"><a href="docs/diagrams/out/container.png"><img src="docs/diagrams/out/container.png" alt="Container diagram — N apps (javawebapp, gowebapp) from apps/registry.tsv, one shared Tekton EventListener — click to enlarge" width="960"></a></p>

### Deployment

<p align="center"><a href="docs/diagrams/out/deployment.png"><img src="docs/diagrams/out/deployment.png" alt="Deployment diagram — collapsed single-cluster view (KinD stand-in); one namespace per app — click to enlarge" width="900"></a></p>

### Cluster topology (VKS)

On VKS the stack spans **two** clusters: Harbor + ArgoCD are Supervisor Services
Supervisor Services that run on the **Supervisor**, while Gitea, Tekton, the ingress, and
the app are installed into the **guest** workload cluster. Because ArgoCD lives on the
Supervisor, the guest cluster is **registered as an ArgoCD destination** (`make
argocd-register-guest`) so it can deploy the apps (`javawebapp`, `gowebapp`) there — it does **not** run a second ArgoCD
in the guest. (The KinD stand-in collapses both levels into one cluster.)

<p align="center"><a href="docs/diagrams/out/vks-topology.png"><img src="docs/diagrams/out/vks-topology.png" alt="VKS namespace/cluster topology — Supervisor (Harbor + ArgoCD as Supervisor Services) vs the guest workload cluster we install into — click to enlarge" width="960"></a></p>

### Pipeline flow

<p align="center"><a href="docs/diagrams/out/pipeline-flow.png"><img src="docs/diagrams/out/pipeline-flow.png" alt="Pipeline flow — one lane per app (javawebapp, gowebapp) through the shared Tekton EventListener — click to enlarge" width="720"></a></p>

Diagram sources are committed under [`docs/diagrams/`](diagrams/) (C4-PlantUML);
`make diagrams` re-renders the PNGs and `make diagrams-check` fails CI if they drift.

### Two operating modes

| Mode | When | Flow |
|------|------|------|
| **dual-homed** (default) | Jump box reaches internet **and** the VKS/Harbor network (routed to ESXi) | `make mirror` pulls + pushes in one run |
| **sneakernet** | Jump box has internet only | `make mirror-pull && make bundle` → carry the bundle → `make bundle-load && make mirror-push` inside |

There's no switch to flip — the mode is simply **which mirror commands you run** (the Flow column above).

---

[← back to the README](../README.md)
