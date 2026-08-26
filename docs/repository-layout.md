# Repository layout

<br>

| Path | Purpose |
|------|---------|
| `scripts/` | Ordered, OS-portable (Ubuntu+PhotonOS) automation; `lib/os.sh` + `lib/mirror.sh` are shared libraries |
| `apps/registry.tsv` | **The app registry — one row per app.** Everything loops over it: seeding, Tekton, ArgoCD, ingress, PSA, the gates. Adding an app is **one row** |
| `apps/<lang>/<app>/` | One dir per row of `apps/registry.tsv` (six today: `java/javawebapp`, `go/gowebapp`, `nodejs/nodejswebapp`, `python/pythonwebapp`, `rust/rustwebapp`, `dotnet/dotnetwebapp`). Each dir IS the content of its `<app>-app` Gitea repo and holds a `Dockerfile` (runtime) **and** a `Dockerfile.builder` — the pre-baked dependency cache that lets the in-cluster build reach no package registry |
| `deploy/<app>/` | Kustomize manifests ArgoCD deploys — one dir per app = one deploy repo. **Not applied by us** — seeded into Gitea `<app>-deploy`, which Tekton writes the image tag into and ArgoCD syncs |
| `k8s/` | Everything **we** apply to the cluster |
| `k8s/tekton/` | Tekton pipeline, tasks, triggers, RBAC |
| `k8s/argocd/` | ArgoCD `Application` definition |
| `k8s/gitea/` | Gitea install manifest (SQLite, single image) |
| `docs/vks-services/` | **What VKS actually provides** — Harbor, ArgoCD (Supervisor Services) and Istio (a guest-cluster Standard Package): what each one is, how it is installed/configured, how we consume it, and a provenance grade per fact (lab-verified / KinD-verified / doc / unverified). A living record — update it when a lab run confirms or refutes something |
| `k8s/istio/`, `k8s/traefik/` | Ingress manifests (`INGRESS_CONTROLLER=istio` default / `istio-existing` / `traefik`) fronting the UIs at `*.vks.local`. `k8s/istio/gateway.yaml` = the Gateway (selector is a token — it is DISCOVERED, never assumed); `virtualservices.yaml` = one VS per UI, in its BACKEND's namespace |
| `kind/` | KinD cluster config — containerd `certs.d` `config_path`, which carries the Harbor CA for the default TLS pulls (plain-HTTP only under `HARBOR_INSECURE=1`) |
| `docs/diagrams/` | C4-PlantUML sources + rendered PNGs |
| `images/images.txt` | Authoritative image inventory to mirror |
| `.env.example` | Committed source of truth for every tunable |

---

[← back to the README](../README.md)
