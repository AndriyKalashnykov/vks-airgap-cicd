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
# open the UIs → see "Access the UIs" below for URLs, logins, and passwords
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

### Access the UIs (URLs, logins, passwords)

Every service is `ClusterIP` (Harbor is a `LoadBalancer` on the kind network), so you reach
each one over `kubectl port-forward` — run each in its own terminal (it blocks). Logins are
the values you put in `.env`; ArgoCD's is generated and read from a secret.

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| **Harbor** | `http://$(grep '^HARBOR_URL=' .env.kind \| cut -d= -f2)` (the LB IP, plain HTTP) | `admin` | your `HARBOR_PASSWORD` from `.env` |
| **Gitea** | `kubectl -n gitea port-forward svc/gitea-http 3000:3000` → <http://localhost:3000> | `gitea_admin` | your `GITEA_ADMIN_PASSWORD` from `.env` |
| **ArgoCD** | `kubectl -n argocd port-forward svc/argocd-server 8081:80` → <http://localhost:8081> | `admin` | see command below |
| **App (webui)** | `kubectl -n webui port-forward svc/webui 18080:80` → <http://localhost:18080/> | — | — (health at `/actuator/health`) |

```bash
# ArgoCD initial admin password (generated at install):
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

The Tekton **EventListener** is reached in-cluster only (`el-webui.ci.svc:8080`); the Gitea
webhook fires cluster-internally, so there is nothing to expose or log into.

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
the lab gave you. For **Gitea** (which you installed) and the deployed **app**, use the same
port-forward pattern as the local run (see [Access the UIs](#access-the-uis-urls-logins-passwords)):
`kubectl -n gitea port-forward svc/gitea-http 3000:3000` and
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
