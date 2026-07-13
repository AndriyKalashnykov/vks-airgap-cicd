# Tech stack

<br>

| Layer | Technology | Why |
|-------|-----------|-----|
| Git server | **Gitea** (self-hosted, SQLite) | Single-image, air-gap-friendly Git host with webhooks; installed inside the cluster |
| CI engine | **Tekton** Pipelines + Triggers | Kubernetes-native, in-cluster builds — no external CI runner to reach across the air gap |
| CI dashboard | **Tekton Dashboard** | Read-only web UI for PipelineRuns / TaskRuns / logs, fronted at `tekton.vks.local` |
| Image build | **Kaniko** | Builds container images in-cluster without a Docker daemon (rootless, no privileged socket) |
| Registry | **Harbor** (a VCF Supervisor Service) | The one OCI registry all parties share (host push, Kaniko push, containerd pull) |
| GitOps CD | **ArgoCD** (a VCF Supervisor Service) | Watches the deploy repo and reconciles the cluster to the committed image tag |
| Ingress | **Istio** (default) / **Traefik** (option) / **attach to an existing Istio** | One LoadBalancer fronting the UIs at `*.vks.local`; pluggable via `INGRESS_CONTROLLER` (`istio` \| `istio-existing` \| `traefik`) |
| Image mirror | **crane** (go-containerregistry) | Copies images internet→Harbor (dual-homed) or into a sneakernet bundle, single- or multi-arch; a static Go binary, so it installs cross-distro via mise (incl. Photon OS 5, where skopeo has no static build/package) |
| Demo apps | **javawebapp** — Spring Boot 4 / Java 25<br>**gowebapp** — Go, stdlib-only | Two apps, two languages, ONE pipeline (`apps/registry.tsv`). Each one's greeting proves *its own* deployed image changed end-to-end. The Java app needs a pre-baked offline Maven builder image; the Go app is stdlib-only and needs none — that contrast is the air-gap story. |
| Offline build | dependency-baked **Maven** builder image | Bakes `~/.m2` so in-cluster `mvn` builds with no Maven Central reach |
| Local e2e | **KinD** + **cloud-provider-kind** | Stands up the Supervisor-Service pieces (Harbor + ArgoCD) locally with a real LoadBalancer |
| Toolchain | **mise** | One cross-distro (Ubuntu/PhotonOS) version manager for the jump-box tools |

---

[← back to the README](../README.md)
