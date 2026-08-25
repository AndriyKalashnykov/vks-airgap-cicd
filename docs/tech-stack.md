# Tech stack

<br>

| Layer | Technology | Why |
|-------|-----------|-----|
| Git server | **Gitea** (self-hosted, SQLite) | Single-image, air-gap-friendly Git host with webhooks; installed inside the cluster |
| CI engine | **Tekton** Pipelines + Triggers | Kubernetes-native, in-cluster builds — no external CI runner to reach across the air gap |
| CI dashboard | **Tekton Dashboard** | Read-only web UI for PipelineRuns / TaskRuns / logs, fronted at `tekton.vks.local` |
| Image build | **Kaniko** | Builds container images in-cluster without a Docker daemon (rootless, no privileged socket) |
| Registry | **Harbor** (a Supervisor Service) | The one OCI registry all parties share (host push, Kaniko push, containerd pull) |
| GitOps CD | **ArgoCD** (a Supervisor Service) | Watches the deploy repo and reconciles the cluster to the committed image tag |
| Ingress | **Istio** (default) / **Traefik** (option) / **attach to an existing Istio** | One LoadBalancer fronting the UIs at `*.vks.local`; pluggable via `INGRESS_CONTROLLER` (`istio` \| `istio-existing` \| `traefik`) |
| Image mirror | **crane** (go-containerregistry) | Copies images internet→Harbor (dual-homed) or into a sneakernet bundle, single- or multi-arch; a static Go binary, so it installs cross-distro via mise (incl. Photon OS 5, where skopeo has no static build/package) |
| Demo apps | six, one per language — Java, Go, Node.js, Python, Rust, .NET. `apps/registry.tsv` is the list; adding one is a row. | **Six languages, ONE pipeline.** Each app's greeting proves *its own* deployed image changed end-to-end, so a green Java app can never hide a broken Rust one. Each builds from a pre-baked offline builder image — that is the air-gap story: no app reaches a package registry at build time. |
| Offline build | dependency-baked **Maven** builder image | Bakes `~/.m2` so in-cluster `mvn` builds with no Maven Central reach |
| Local e2e | **KinD** + **cloud-provider-kind** | Stands up the Supervisor-Service pieces (Harbor + ArgoCD) locally with a real LoadBalancer |
| Toolchain | **mise** | One cross-distro (Ubuntu/PhotonOS) version manager for the jump-box tools |

---

[← back to the README](../README.md)
