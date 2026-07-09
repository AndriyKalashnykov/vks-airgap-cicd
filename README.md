[![CI](https://github.com/AndriyKalashnykov/vks-airgap-cicd/actions/workflows/ci.yml/badge.svg)](https://github.com/AndriyKalashnykov/vks-airgap-cicd/actions/workflows/ci.yml)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovatebot)](https://docs.renovatebot.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/vks-airgap-cicd.svg?view=today-total&style=plastic)](https://hits.sh/github.com/AndriyKalashnykov/vks-airgap-cicd/)

# Air-gapped CI/CD on VMware VKS — Reference Demo

Reference implementation of an end-to-end CI/CD pipeline for a **fully air-gapped**
VKS cluster (VMware vSphere Kubernetes Service, VCF 9 + Supervisor). The **pipeline
surface** wires self-hosted **Gitea** + **Tekton** (test → **Kaniko** build → **Harbor**
push → GitOps tag write-back) to the VKS-provided **Harbor** and **ArgoCD**; the
**delivery surface** covers an OS-portable (Ubuntu/PhotonOS) jump-box image mirror
(**skopeo**, dual-homed or sneakernet), a dependency-baked offline **Maven** builder, a
pluggable ingress (**Istio** by default, **Traefik** optional) fronting the UIs at
`*.vks.local`, and a one-command **KinD** end-to-end that proves the whole flow locally.

<p align="center"><img src="docs/diagrams/out/context.png" alt="System context: air-gapped CI/CD on VMware VKS" width="500"></p>

> A developer pushes a change to **Gitea** → **Tekton** runs tests, builds a container
> image with **Kaniko** and pushes it to **Harbor** → Tekton bumps the image tag in the
> deploy repo → **ArgoCD** syncs the new version to the cluster → the web UI updates.
> Harbor and ArgoCD are **provided by VKS**; this project mirrors all required images
> into Harbor and installs + wires **Gitea + Tekton** and the demo app.

## Prerequisites

### Install and configure git (first — before mise)

git is the one tool you need **before everything else**: you use it to clone this repo, and
the CI flow uses git both in-cluster (clone) and for the GitOps tag write-back. Install the
client for your jump-box OS (`scripts/00-install-prereqs.sh` also installs it via the OS
package manager, but you need it *before* you can clone the repo and run `make deps`):

```bash
# Ubuntu
sudo apt-get update && sudo apt-get install -y git

# Photon OS
sudo tdnf install -y git
```

Set your commit identity — used for any local commits you make on the jump box (the
in-cluster pipeline commits under its own identity):

```bash
git config --global user.name  "VKS Developer"
git config --global user.email "vks.developer@sample.corp.com"
```

### Toolchain and access

- A jump box running **Ubuntu** or **PhotonOS** with internet access.
- Network reach to the VKS Supervisor, Harbor, and (for dual-homed) the workload cluster.
- The Harbor (and Gitea, once installed) **CA certificates** (`.env` → `HARBOR_CA_FILE` / `GITEA_CA_FILE`).
- [mise](https://mise.jdx.dev/) for the rest of the toolchain (installed by `make deps`; git must already be present).
- **Container engine:** image operations (mirror, Maven builder build/push, diagram
  rendering) use `CONTAINER_ENGINE` — **podman-preferred**, docker fallback. The
  **local KinD end-to-end** additionally **requires Docker**: KinD's node and
  `cloud-provider-kind` run on the `kind` Docker network + socket. So a real air-gap
  run can be podman-only; `make e2e-kind` needs Docker.

### Disk space on the jump box

Measured for the current image set (~30 images: 10 pinned in
[`images/images.txt`](images/images.txt) plus the Tekton Pipelines+Triggers controller
images pulled from their release manifests, which dominate the count — alongside Gitea,
Kaniko, Maven, Temurin JDK/JRE, alpine/git, yq, and the ingress images). Figures are approximate.

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

### Guest (VKS workload) cluster sizing

Sizing for the **guest cluster** where this project deploys **Gitea + Tekton (+ Dashboard) +
the webui app** and its images. Harbor and ArgoCD are **VKS-provided**, so they are budgeted
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
  2 GB CI workspace, plus transient kaniko/maven scratch and a new `webui:<sha>` image per
  run (budget growth room — hence the 40 → 100 GB range).
- **If Harbor + ArgoCD are co-located** in this same guest cluster (instead of provided
  externally), add roughly **+2 vCPU / +4 GB RAM / +5 GB disk** to each tier.

## Tech stack

| Layer | Technology | Why |
|-------|-----------|-----|
| Git server | **Gitea** (self-hosted, SQLite) | Single-image, air-gap-friendly Git host with webhooks; installed inside the cluster |
| CI engine | **Tekton** Pipelines + Triggers | Kubernetes-native, in-cluster builds — no external CI runner to reach across the air gap |
| CI dashboard | **Tekton Dashboard** | Read-only web UI for PipelineRuns / TaskRuns / logs, fronted at `tekton.vks.local` |
| Image build | **Kaniko** | Builds container images in-cluster without a Docker daemon (rootless, no privileged socket) |
| Registry | **Harbor** (VKS-provided) | The one OCI registry all parties share (host push, Kaniko push, containerd pull) |
| GitOps CD | **ArgoCD** (VKS-provided) | Watches the deploy repo and reconciles the cluster to the committed image tag |
| Ingress | **Istio** (default) / **Traefik** (option) | One LoadBalancer fronting the UIs at `*.vks.local`; pluggable via `INGRESS_CONTROLLER` |
| Image mirror | **skopeo** | Copies images internet→Harbor (dual-homed) or into a sneakernet bundle, single- or multi-arch |
| Demo app | **Spring Boot 4 / Java 25** | Minimal web UI whose greeting proves the deployed image changed end-to-end |
| Offline build | dependency-baked **Maven** builder image | Bakes `~/.m2` so in-cluster `mvn` builds with no Maven Central reach |
| Local e2e | **KinD** + **cloud-provider-kind** | Stands up the "VKS-provided" Harbor + ArgoCD locally with a real LoadBalancer |
| Toolchain | **mise** | One cross-distro (Ubuntu/PhotonOS) version manager for the jump-box tools |

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

## Architecture

Harbor + ArgoCD are **provided by VKS** (blue in the diagrams). The jump box mirrors every
image into Harbor; a `git push` then drives the whole CI/CD flow entirely inside the air gap.

### Containers

<p align="center"><img src="docs/diagrams/out/container.png" alt="Container diagram" width="960"></p>

### Deployment

<p align="center"><img src="docs/diagrams/out/deployment.png" alt="Deployment diagram" width="900"></p>

### Pipeline flow

<p align="center"><img src="docs/diagrams/out/pipeline-flow.png" alt="Pipeline flow" width="960"></p>

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
make e2e-kind                 # cluster → Harbor → ArgoCD → mirror → build → deploy → ingress → verify
# open the UIs → see "Access the UIs" below for the *.vks.local hostnames
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
- **`make install-ingress`** installs one ingress LoadBalancer (`INGRESS_CONTROLLER=istio`
  by default, `traefik` optional) that fronts the Gitea/ArgoCD/app/Tekton-Dashboard UIs at `*.vks.local`, so
  you reach them by hostname instead of `kubectl port-forward`. Harbor keeps its own direct
  LB (its IP is load-bearing for the containerd pull path). Both ingress images are mirrored
  into Harbor.

Individual targets: `make kind-up`, `make install-harbor`, `make install-argocd`,
`make install-ingress` (or `make install-istio` / `make install-traefik`).

### Access the UIs (URLs, logins, passwords)

Run **`make creds`** — it prints the URLs and logins for whichever context you're in (the
KinD demo or a real VKS lab), self-resolving the kubeconfig so there's no `kubectl` context
to set. It also prints the one-time `/etc/hosts` line that maps the `*.vks.local` hosts to
the ingress LoadBalancer. (Gitea, ArgoCD, the app, and the read-only Tekton Dashboard are
fronted by the ingress at `*.vks.local`; Harbor keeps its own LB IP over plain HTTP.)

Ordered by the pipeline flow (Gitea → Tekton → Harbor → ArgoCD → App):

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| **Gitea** | <http://gitea.vks.local> | `gitea_admin` | your `GITEA_ADMIN_PASSWORD` from `.env` |
| **Tekton Dashboard** | <http://tekton.vks.local> | — | — (read-only; no login) |
| **Harbor** | its own LB IP, plain HTTP | `admin` | your `HARBOR_PASSWORD` from `.env` |
| **ArgoCD** | <http://argocd.vks.local> | `admin` | `make argocd-password` |
| **App (webui)** | <http://app.vks.local/> | — | — (health at `/actuator/health`) |

**ArgoCD password** — `make argocd-password` reveals it for either context:

- **KinD:** set `ARGOCD_ADMIN_PASSWORD` in `.env` for a known, stable login (applied at
  `make install-argocd`, like Gitea/Harbor); leave it blank to keep ArgoCD's auto-generated
  password. Either way `make argocd-password` prints it — no `kubectl`/context needed.
- **Real VKS:** ArgoCD is lab-provided — leave `ARGOCD_ADMIN_PASSWORD` blank; the command
  reads the initial-admin secret if present, otherwise points you to your lab.

> Without the ingress (or before adding the `/etc/hosts` line), the same services are still
> reachable over `kubectl port-forward` — e.g. `kubectl -n gitea port-forward svc/gitea-http
> 3000:3000` → <http://localhost:3000>. Harbor is always a direct LoadBalancer, not behind the ingress.

The **Tekton Dashboard** (above) is Tekton's web UI. The Tekton **EventListener** is a
separate, in-cluster-only webhook receiver (`el-webui.ci.svc:8080`) — the Gitea webhook fires
cluster-internally, so there is nothing to expose or log into there.

## Run against a real VKS lab (Harbor & ArgoCD pre-provided)

This is the real target: the VKS lab already runs **Harbor** and **ArgoCD** (you have their
IPs, logins, and passwords) and gives you a workload-cluster kubeconfig. You install only
**Gitea** + **Tekton** and wire the flow. Dual-homed: the jump box reaches both the internet
and the lab (VKS API + Harbor).

**Step 0 — remove the KinD overlay.** `.env.kind` (written by the local flow) is sourced
*after* `.env` and would silently redirect everything at a kind cluster. Delete it first:

```bash
make kind-down        # if you ran the local flow (also removes .env.kind)
rm -f .env.kind       # belt-and-suspenders
```

**Step 1 — fill in `.env`** (copied from `.env.example`; gitignored, never committed) with
the lab-provided values:

```bash
# --- Harbor (pre-provided by the lab) ---
HARBOR_URL=harbor.<lab-host-or-ip>       # the lab's Harbor (HTTPS)
HARBOR_USERNAME=admin                    # or a robot account name (step 4)
HARBOR_PASSWORD=<lab-harbor-secret>      # set in .env only, never on argv
HARBOR_CA_FILE=./secrets/harbor-ca.crt   # the lab Harbor's CA (step 2)
HARBOR_INFRA_PROJECT=cicd                # CI/CD + base images
HARBOR_APP_PROJECT=apps                  # the built application image

# --- ArgoCD (pre-provided, running IN the workload cluster) ---
ARGOCD_NAMESPACE=<ns-where-lab-argocd-runs>   # e.g. argocd — find it in step 4
ARGOCD_APP_NAME=webui
ARGOCD_DEST_NAMESPACE=webui
ARGOCD_TRACK_BRANCH=main
# ARGOCD_SERVER is NOT consumed by the scripts (wiring is via kubectl, not the argocd CLI).
# You only need the lab's ArgoCD IP/login/password to open its UI (step 7).

# --- Gitea (WE install it) ---
GITEA_ADMIN_PASSWORD=<choose-one>        # set in .env only

# --- VKS access ---
VKS_AUTH_METHOD=kubeconfig               # simplest: bring the lab's kubeconfig
KUBECONFIG=./secrets/vks.kubeconfig      # place the lab's exported kubeconfig here
VKS_CONTEXT=<context-name-in-that-kubeconfig>
```

For VKS auth, `kubeconfig` (drop the lab's exported kubeconfig at `$KUBECONFIG`) is the
simplest working method. If the lab uses the vSphere plugin instead, set
`VKS_AUTH_METHOD=vsphere` and `SUPERVISOR_HOST` / `VKS_NAMESPACE` / `VKS_CLUSTER_NAME` /
`VKS_USERNAME` / `VKS_PASSWORD`. (The `vcf` method is a stub — do not use it yet.)

**Step 2 — save the Harbor CA certificate** to `./secrets/harbor-ca.crt` (the
`HARBOR_CA_FILE` path). If the lab handed you the cert, drop it there. Otherwise fetch it
from the running Harbor:

```bash
mkdir -p secrets
openssl s_client -connect <harbor-host>:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > secrets/harbor-ca.crt
```

(Or download it from the Harbor UI → your project → **Registry Certificate**.) The CA is
consumed in **two** places, both handled for you: `make mirror` / `make vks-login` install it
into the jump box's system trust store (so `skopeo` can push over HTTPS), and `make platform`
creates an in-cluster ConfigMap **`harbor-ca`** (key `ca.crt`) in the `ci` namespace so
Kaniko/Tekton trust it too. If Harbor presents a publicly-trusted cert, leave
`HARBOR_CA_FILE` empty.

**Step 3 — install prereqs and log in to VKS:**

```bash
make deps         # skopeo, tkn, argocd, kubectl, helm, mise tools
make vks-login    # validates $KUBECONFIG + context against the lab cluster
```

**Step 4 — Harbor projects + (recommended) a robot account.** `make mirror` (run in step 6)
creates the `cicd` and `apps` projects for you via Harbor's REST API if they don't exist
(needs push rights). For least-privilege CI, create a Harbor **robot account** (Harbor UI →
**Administration → Robot Accounts**, or the REST API) scoped to push/pull those two projects,
and put its name/secret in `HARBOR_USERNAME` / `HARBOR_PASSWORD` instead of `admin`. Find the
namespace the lab's ArgoCD watches (for `ARGOCD_NAMESPACE` in step 1):

```bash
kubectl get pods -A | grep argocd-application-controller   # its namespace = ARGOCD_NAMESPACE
```

**Step 5 — verify (or create) the in-cluster registry secret.** The pipeline pushes the
built image to Harbor from inside the cluster, which needs a Docker-config secret.
`make platform` (its `configure-tekton` step, run in step 6) creates it for you as
**`harbor-dockerconfig`** in the `ci` namespace, from `HARBOR_USERNAME` / `HARBOR_PASSWORD`.
Check whether it already exists:

```bash
kubectl -n ci get secret harbor-dockerconfig
```

If you ever need to create or rotate it by hand (keeping the secret **off argv** — build the
`config.json` on disk and load it from a file; kaniko needs the key named literally
`config.json`, not `.dockerconfigjson`):

```bash
umask 077
auth=$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 -w0)
printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" > /tmp/harbor-config.json
kubectl -n ci create secret generic harbor-dockerconfig \
  --from-file=config.json=/tmp/harbor-config.json --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/harbor-config.json
```

The Kubernetes secret is built from your Harbor **login/password**; Harbor's **REST API** is
used only to create the *projects* (and, optionally, a robot account) — it does not create
this cluster secret.

**Step 6 — install everything and verify end-to-end:**

```bash
make install-all   # mirror → builder-image → vks-login → platform → gitops
make verify        # push a marked change → Tekton → Harbor → ArgoCD → live app serves it
```

`install-all` deliberately does **not** install Harbor or ArgoCD — those are the lab's. It
mirrors all images into the lab Harbor, builds + pushes the offline Maven builder image,
installs Gitea + Tekton, and creates the ArgoCD `Application`.

**Step 7 — access the UIs.** Harbor and ArgoCD are the lab's — use the IPs/logins/passwords
the lab gave you. For **Gitea** (which you installed) and the deployed **app**, either run
`make install-ingress` to reach them by hostname at `*.vks.local` (add the printed
`INGRESS_LB_IP` line to `/etc/hosts`; see [Access the UIs](#access-the-uis-urls-logins-passwords)),
or use `kubectl port-forward` — `kubectl -n gitea port-forward svc/gitea-http 3000:3000` and
`kubectl -n webui port-forward svc/webui 18080:80`.

### VKS-lab checklist (easy-to-miss items)

- **`.env.kind` must not exist** (step 0) — it is sourced after `.env` and silently forces
  kind values.
- **ArgoCD must run in the same cluster** your `KUBECONFIG` targets. The `Application`'s
  destination is `https://kubernetes.default.svc` (in-cluster) and the scripts wire it by
  `kubectl apply`-ing the `Application` into `ARGOCD_NAMESPACE` — **not** via the ArgoCD API.
  A remote/off-cluster ArgoCD addressed by URL + API is not supported.
- **`ARGOCD_NAMESPACE` must match** where the lab's ArgoCD controller watches Applications
  (step 4).
- **ArgoCD reaches Gitea over the in-cluster URL** (`GITEA_INTERNAL_URL`, default
  `http://gitea-http.gitea.svc:3000`) — Gitea and ArgoCD are in the same cluster, so this
  works without exposing Gitea externally.
- **cluster-admin** on the workload cluster is required — the flow creates namespaces
  (`gitea`, `ci`, `webui`) and installs Tekton CRDs.
- **StorageClass:** Gitea uses a PVC (`GITEA_STORAGE_SIZE`, default `5Gi`). Ensure the
  cluster has a default StorageClass (or set one explicitly).
- **Harbor projects** `cicd` + `apps` must exist (auto-created by `make mirror` with push
  rights; otherwise create them first).
- **Network reach (dual-homed):** the jump box must reach the VKS API server and the lab
  Harbor.

## Detailed steps

Legend: **[offline]** verifiable without a cluster · **[cluster]** runs against live VKS.

| # | Command | Mode | What happens |
|---|---------|------|--------------|
| 1 | `cp .env.example .env` + edit | [offline] | Set Harbor/Gitea URLs, VKS auth, CA files, and secrets (`HARBOR_PASSWORD`, `GITEA_ADMIN_PASSWORD`). |
| 2 | `make deps` | [offline] | `mise install` + `scripts/00-install-prereqs.sh` (skopeo, tkn, argocd, kubectl, helm, jq, yq). |
| 3 | `make ci` | [offline] | toolchain/image alignment + shellcheck + yamllint + hadolint + kubeconform + gitleaks + trivy fs/config + `mvn test` + docs/diagram checks. |
| 4 | `make mirror` | [cluster] | `10-mirror-pull.sh` pulls all images (+ Tekton release manifests) then `21-mirror-push.sh` pushes them into Harbor. **Sneakernet:** `make mirror-pull && make bundle`, carry the bundle, then `make bundle-load BUNDLE_TARBALL=… && make mirror-push` inside. |
| 5 | `make builder-image` | [internet] | Builds the Maven builder image with this app's deps pre-baked and pushes it to Harbor (so in-cluster CI builds offline). |
| 6 | `make vks-login` | [cluster] | `30-vks-login.sh` writes a working `$KUBECONFIG`/context (see auth note). |
| 7 | `make platform` | [cluster] | Installs Gitea (`k8s/gitea/`), seeds the two repos + webhook, installs Tekton (images remapped to Harbor), applies the pipeline/triggers. |
| 8 | `make gitops` | [cluster] | Registers the deploy repo and creates the ArgoCD `Application` (auto-sync). |
| 9 | `make verify` | [cluster] | Pushes a marked change to `webui-app`, then asserts: PipelineRun succeeds → image in Harbor → deploy tag bumped → ArgoCD Synced/Healthy → the live page shows the marker. |

### Minimum `.env` you must set

```bash
HARBOR_URL=harbor.<lab-host-or-ip>          # provided by VKS
HARBOR_PASSWORD=<robot-or-admin-secret>  # never committed
HARBOR_CA_FILE=./secrets/harbor-ca.crt   # the Harbor CA (self-signed)
GITEA_URL=http://gitea.<lab-host-or-ip>
GITEA_ADMIN_PASSWORD=<choose-one>
ARGOCD_NAMESPACE=argocd                  # where VKS runs ArgoCD
KUBECONFIG=./secrets/vks.kubeconfig      # produced by make vks-login
```

## Repository layout

| Path | Purpose |
|------|---------|
| `scripts/` | Ordered, OS-portable (Ubuntu+PhotonOS) automation; `lib/os.sh` + `lib/mirror.sh` are shared libraries |
| `apps/java/webui/` | Minimal Spring Boot web UI (seeded into Gitea `webui-app`); `Dockerfile` + `Dockerfile.builder` |
| `deploy/base/` | Kustomize manifests ArgoCD deploys (seeded into Gitea `webui-deploy`) |
| `tekton/` | Tekton pipeline, tasks, triggers, RBAC |
| `argocd/` | ArgoCD `Application` definition |
| `k8s/gitea/` | Gitea install manifest (SQLite, single image) |
| `k8s/istio/`, `k8s/traefik/` | Ingress manifests (`INGRESS_CONTROLLER=istio` default / `traefik` option) fronting the UIs at `*.vks.local` |
| `kind/` | KinD cluster config (containerd insecure-registry wiring) |
| `docs/diagrams/` | C4-PlantUML sources + rendered PNGs |
| `images/images.txt` | Authoritative image inventory to mirror |
| `.env.example` | Committed source of truth for every tunable |

## Make targets

`make help` prints the full grouped list. The most-used targets:

| Group | Target | Purpose |
|-------|--------|---------|
| Prereqs | `deps` | Install the jump-box toolchain (mise tools + skopeo/tkn/argocd) |
| Mirror | `mirror` / `mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | Pull images → Harbor (dual-homed), or the sneakernet phases |
| Mirror | `builder-image` | Build + push the deps-baked offline Maven builder image |
| Install | `vks-login` / `platform` / `gitops` / `install-all` | Auth to VKS; install Gitea+Tekton; wire ArgoCD; or all of it |
| KinD e2e | `e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify) |
| KinD e2e | `kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps (`install-istio` / `install-traefik` pick the controller) |
| Verify | `verify` | End-to-end smoke test on a LIVE cluster |
| Verify | `verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| App dev | `app-test` / `app-build` / `app-run` | Spring Boot app tests / jar / local run |
| Gates | `ci` / `static-check` / `docs-lint` | Composite offline gate; code gate; docs gate |
| Gates | `lint` / `validate` / `check-image-alignment` / `check-toolchain-alignment` | Individual code gates |
| Security | `sec` / `secrets` / `trivy-fs` / `trivy-config` | gitleaks + trivy fs (app deps) / config (manifests) |
| Diagrams | `diagrams` / `diagrams-check` / `vendor-diagrams` | Render PNGs / byte-diff drift gate / re-vendor C4-PlantUML |

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on push to `main`, tags `v*`, and pull requests.

| Job | Runs | Purpose |
|-----|------|---------|
| **changes** | always | `dorny/paths-filter` classifies the diff into `code` / `docs` |
| **static-check** | if `code` changed | `make static-check` — toolchain/image alignment, shellcheck, yamllint, hadolint, kubeconform, security scans (gitleaks + trivy fs/config), `mvn test` |
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

## Contributing

Contributions welcome — open an issue or a pull request. Before pushing, run `make ci`
(the offline gate: alignment, lint, manifest validation, security scans, app tests, and
docs/diagram drift checks) so the change matches what CI enforces. Dependency updates are
managed by [Renovate](https://docs.renovatebot.com/); tool and image versions are pinned
via `.mise.toml`, `.env.example`, `images/images.txt`, and inline `# renovate:` comments.

## License

Released under the [MIT License](LICENSE).
