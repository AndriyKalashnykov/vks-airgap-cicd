[![CI](https://img.shields.io/github/actions/workflow/status/AndriyKalashnykov/vks-airgap-cicd/ci.yml?branch=main&label=CI&style=flat)](https://github.com/AndriyKalashnykov/vks-airgap-cicd/actions/workflows/ci.yml)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovatebot&style=flat)](https://docs.renovatebot.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen?style=flat)](LICENSE)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/vks-airgap-cicd.svg?view=today-total&style=flat&color=4c1)](https://hits.sh/github.com/AndriyKalashnykov/vks-airgap-cicd/)

# Air-gapped GitOps CI/CD on VMware VKS — Reference Demo

Reference implementation of an end-to-end CI/CD pipeline for a **fully air-gapped**
VKS cluster (VMware vSphere Kubernetes Service, VCF 9 + Supervisor). Two surfaces:

- **Pipeline surface** — self-hosted **Gitea** + **Tekton** (test → **Kaniko** build →
  **Harbor** push → GitOps tag write-back), wired to the VKS-provided **Harbor** + **ArgoCD**.
- **Delivery surface** — an OS-portable (Ubuntu / PhotonOS) jump-box image mirror (**crane**,
  dual-homed or sneakernet), a dependency-baked offline **Maven** builder, a pluggable ingress
  (**Istio** default, **Traefik** optional) fronting the UIs at `*.vks.local`, and a one-command
  **KinD** end-to-end that proves the whole flow locally.

<p align="center"><img src="docs/diagrams/out/airgap.png" alt="Air-gap connectivity: the jump box bridges the internet and the air-gapped VKS cluster; the cluster itself has no internet access" width="820"></p>

<p align="center"><em>The jump box is the only bridge — it pulls from the internet and pushes into the air-gapped cluster, which has no internet access of its own.</em></p>

> A developer pushes a change to **Gitea** → **Tekton** runs tests, builds a container
> image with **Kaniko** and pushes it to **Harbor** → Tekton bumps the image tag in the
> deploy repo → **ArgoCD** syncs the new version to the cluster → the web UI updates.
> Harbor and ArgoCD are **provided by VKS**; this project mirrors all required images
> into Harbor and installs + wires **Gitea + Tekton** and the demo app.

## Prerequisites

### Bootstrap a bare jump box (before you can clone this repo)

Everything else (mise, `make deps`, the toolchain) runs from a clone of this repo, so first
get **git + SSH + `make`** working on a fresh box. Do this once, manually.

**Ubuntu:**

```bash
sudo apt-get update
sudo apt-get install -y git openssh-client ca-certificates curl make
```

**Photon OS:**

```bash
# Refresh the package cache FIRST. A stale tdnf cache is the #1 cause of a broken TLS stack
# on a long-lived Photon box: `tdnf install git` UPGRADES openssl-libs, and a partial or
# mismatched upgrade then breaks HTTPS/SSH — git clone fails with an SSL error. Cleaning the
# cache and installing a consistent TLS set up front avoids it.
sudo tdnf clean all && sudo tdnf makecache
sudo tdnf install -y ca-certificates openssl curl git openssh-clients make tar
```

**If `git clone` (or `make deps`) still fails with an SSL / TLS / certificate error on Photon
OS**, that is the stale-cache openssl mismatch — refresh and reinstall the TLS stack, then
retry the clone:

```bash
sudo tdnf clean all && sudo tdnf makecache
sudo tdnf reinstall -y ca-certificates openssl openssl-libs curl curl-libs
```

**Configure your git identity** (both OSes; used for local commits — the in-cluster pipeline
commits under its own identity):

```bash
git config --global user.name  "VKS Developer"
git config --global user.email "vks.developer@sample.corp.com"
```

**Create an SSH key and add it to GitHub** (for `git@github.com:` clones):

```bash
ssh-keygen -t ed25519 -C "vks.developer@sample.corp.com" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub     # add this line at GitHub → Settings → SSH and GPG keys → New SSH key
ssh -T git@github.com         # expect: "Hi <user>! You've successfully authenticated…"
```

**Clone the repo, then install mise** and let the Makefile pull the rest of the toolchain:

```bash
# SSH (needs the key above added to your GitHub account)…
git clone git@github.com:AndriyKalashnykov/vks-airgap-cicd.git
# …or HTTPS (this repo is public — no key needed):
git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git
cd vks-airgap-cicd

curl https://mise.run | sh                 # installs mise to ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"       # put mise on PATH for THIS shell (the installer also
                                           # adds `mise activate` to your profile for new shells)
make deps                                  # installs the full jump-box toolchain (mise tools +
                                           # scripts/00-install-prereqs.sh); it also sets up rootless
                                           # podman for the builder-image build — crun + registries on
                                           # Photon, uidmap + slirp4netns on Ubuntu
```

> The **`make deps` toolchain install + rootless-podman engine + cluster reachability** are
> validated end-to-end by `make jumpbox` — it runs them on a fresh jump-box container
> (`JUMPBOX_OS=photon` on `photon:5.0`, the default, or `JUMPBOX_OS=ubuntu` on `ubuntu:26.04`;
> `make jumpbox-both` runs the matrix), joined to a local KinD cluster with rootless podman, and
> fails if `make deps` or the container-engine setup breaks on a real jump box of that OS.

### Toolchain and access

- A jump box running **Ubuntu** or **PhotonOS** with internet access.
- Network reach to the VKS Supervisor, Harbor, and (for dual-homed) the workload cluster.
- The Harbor (and Gitea, once installed) **CA certificates** (`.env` → `HARBOR_CA_FILE` / `GITEA_CA_FILE`).
- [mise](https://mise.jdx.dev/) for the rest of the toolchain (installed by `make deps`; git must already be present).
- **Container engine:** image operations (mirror, Maven builder build/push, diagram
  rendering) use `CONTAINER_ENGINE` — **podman-preferred**, docker fallback. `make deps`
  installs the rootless-podman runtime deps per OS (crun + an active
  `unqualified-search-registries` on Photon; `uidmap` + `slirp4netns` on Ubuntu, which apt
  leaves out of a default podman install). The **local KinD end-to-end** additionally
  **requires Docker**: KinD's node and `cloud-provider-kind` run on the `kind` Docker network +
  socket. So a real air-gap run can be podman-only; `make e2e-kind` needs Docker.

<details>
<summary><strong>Sizing reference</strong> — jump-box disk space + guest-cluster resources (click to expand)</summary>

<br>

**Jump-box disk space** — measured for the current image set (~30 images: 10 pinned in
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

**Guest (VKS workload) cluster sizing** — sizing for the **guest cluster** where this project deploys **Gitea + Tekton (+ Dashboard) +
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

</details>

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
| Image mirror | **crane** (go-containerregistry) | Copies images internet→Harbor (dual-homed) or into a sneakernet bundle, single- or multi-arch; a static Go binary, so it installs cross-distro via mise (incl. Photon OS 5, where skopeo has no static build/package) |
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

### System context

<p align="center"><img src="docs/diagrams/out/context.png" alt="System context: air-gapped CI/CD on VMware VKS" width="640"></p>

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

## Run against a real VKS lab (Harbor & ArgoCD need to be installed)

This is the real target. You are given a **Supervisor** endpoint (IP), a login, and a password —
nothing else. **Harbor** and **ArgoCD** are **not** pre-provided: you install them as **VCF
Supervisor Services**, provision a **workload VKS cluster**, then install **Gitea** + **Tekton**
and wire the pipeline. Dual-homed: the jump box reaches both the internet and the lab (Supervisor
API + Harbor).

The order below installs the lab-side services first (**Part A** — Harbor, ArgoCD, workload
cluster; mostly the vSphere Client + `kubectl`), then wires this repo and runs the flow
(**Part B**).

**Downloads** (each needs your Broadcom entitlement):

- **VCF Consumption CLI** 9.1.0.0 —
  [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0&os=&servicePk=540528&language=EN&groupId=540529&viewGroup=true)
- **VCF Consumption CLI Plugins** 9.1.0.0 —
  [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0&os=&servicePk=540528&language=EN&groupId=540672&viewGroup=true)
- **ArgoCD Service** (search **vSphere Supervisor Services** → **ArgoCD Service**) —
  [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.1.0&os=&servicePk=538499&language=EN)
- **Harbor** (search **vSphere Supervisor Services** → **Harbor**) —
  [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.14.3&os=&servicePk=542081&language=EN)

Reference docs:
[Installing and Configuring Harbor as a VCF Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html)
·
[Install the Argo CD Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html).

### Part A — install the lab services

**A1 — Install Harbor as a Supervisor Service** (vSphere Client — not scriptable):

1. **Ingress prereq:** install **Contour** first (Harbor's default ingress on VKS), or configure
   an NGINX-based load balancer for the Supervisor.
2. **Register the operator:** vSphere Client → **Supervisor Management → Services → Add New
   Service** → upload `harbor-service-<ver>.yml`.
3. **Configure `harbor-data-values-<ver>.yml`** — the key fields: `hostname` (the Harbor
   **FQDN**), `harborAdminPassword` (initial admin password, changeable later), `secretKey`
   (exactly 16 chars), `database.password`, `core.xsrfKey` (32 chars), the storage classes
   (registry/jobservice/database/redis/trivy — your storage-policy name, lowercased with dashes),
   and the ingress toggle (`enableContourHttpProxy: true` for Contour **or**
   `enableNginxLoadBalancer: true` for NGINX). Leave the `tlsCertificate` block alone unless you
   bring a custom cert — cert-manager auto-issues a self-signed one (keep the
   `managed-by: vmware-vRegistry` label; it is required for VKS trust).
4. **Deploy:** Harbor service card → **Actions → Manage Service** → pick version + target
   Supervisor → paste the edited `harbor-data-values` → **Finish**.
5. **Map the FQDN:** get the ingress IP (`kubectl get svc -n <harbor-ns>` for NGINX, or the
   Contour Envoy service IP), then add a DNS record — or a jump-box `/etc/hosts` entry — mapping
   the Harbor FQDN → that IP.

> **Fidelity bonus (real lab beats KinD here):** when Harbor and your VKS workload cluster run on
> the **same Supervisor**, the VKS clusters **automatically trust the Harbor registry
> certificate** — so the workload-node image pull "just works" without the per-node `certs.d`
> wiring the KinD stand-in uses.

**A2 — Install the ArgoCD Operator + an ArgoCD instance** (`kubectl`-driven):

1. **Install the ArgoCD Operator** service on the Supervisor (Supervisor Services, same flow as
   Harbor).
2. **Create a vSphere Namespace** for the instance (e.g. `argocd-instance-1`) with VM + storage
   classes.
3. **Authenticate to the Supervisor:** `vcf context create mgmt-cluster --endpoint <supervisor-IP>
   --type k8s` (vSphere 9+; on vSphere 8 use `kubectl vsphere login --server <IP>`).
4. **Pick a supported version** with `kubectl explain argocd.spec.version`, then apply the CR:

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata:
     name: argocd-1
     namespace: argocd-instance-1
   spec:
     version: <supported-version>   # e.g. 2.14.15+vmware.1-vks.1
   ```

5. **Get its LoadBalancer IP:** `kubectl get svc -n argocd-instance-1` → the `argocd-server`
   EXTERNAL-IP (its **own** LB, self-signed TLS with no IP SAN — like the KinD stand-in).
6. **Get the admin password:**
   `kubectl get secret -n argocd-instance-1 argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
7. **Log in + rotate:** `argocd login <LB-IP>` (accept the self-signed cert) →
   `argocd account update-password`.

> **Version note:** the operator CR pins the ArgoCD **server** (the example is `2.14.15`, a 2.x
> line), while the shipped `argocd` **CLI** from the VCF download is `3.0.19-vcf` (3.x). Read the
> real supported server versions with `kubectl explain argocd.spec.version` on the lab; the KinD
> stand-in runs a 3.x server, so expect a possible server-generation delta.
>
> **Topology to verify on the lab:** `make gitops` applies an ArgoCD `Application` (via
> `kubectl`) into `ARGOCD_NAMESPACE` and targets the in-cluster destination
> `https://kubernetes.default.svc`. Confirm the ArgoCD instance can deploy into the workload
> namespace it watches — same cluster, or the workload cluster registered with ArgoCD. An
> off-cluster ArgoCD addressed **only** by URL + API is not what the scripts assume.
>
> **`make argocd-preflight`** automates both checks against your `KUBECONFIG` cluster — it
> prints the operator's supported server versions (`kubectl explain argocd.spec.version`), the
> running server image, the `argocd` CLI version, and a **TOPOLOGY OK / MISMATCH** verdict
> (is ArgoCD in this cluster, are any workload clusters registered, does the target namespace
> exist). Run it after Step 1 (kubeconfig in place), before `make gitops`.

**A3 — Provision the workload VKS cluster + get its kubeconfig.** Gitea, Tekton, and the demo app
run in a **guest VKS (Tanzu Kubernetes) cluster**, not on the Supervisor. Create a vSphere
Namespace, provision a VKS cluster in it, and obtain its kubeconfig (e.g. a `vcf`/`kubectl
vsphere` login to the guest cluster, or export it from VCF Automation). You need **cluster-admin**
on it — the flow creates namespaces (`gitea`, `ci`, `webui`) and installs Tekton CRDs. Place the
kubeconfig at `$KUBECONFIG` (Part B, Step 1).

### Part B — wire this repo and run

**Step 0 — remove the KinD overlay.** `.env.kind` (written by the local flow) is sourced
*after* `.env` and would silently redirect everything at a kind cluster. Delete it first:

```bash
make kind-down        # if you ran the local flow (also removes .env.kind)
rm -f .env.kind       # belt-and-suspenders
```

**Step 1 — fill in `.env`** (copied from `.env.example`; gitignored, never committed) with
the lab-provided values:

```bash
# --- Harbor (you installed it in A1) ---
HARBOR_URL=harbor.<lab-fqdn>             # the Harbor FQDN you set in A1 (HTTPS)
HARBOR_USERNAME=admin                    # or the robot account name (step 4)
HARBOR_PASSWORD=<harborAdminPassword>    # the A1 admin password; set in .env only, never on argv
HARBOR_CA_FILE=./secrets/harbor-ca.crt   # Harbor's self-signed CA (step 2)
HARBOR_INFRA_PROJECT=cicd                # CI/CD + base images
HARBOR_APP_PROJECT=apps                  # the built application image

# --- ArgoCD (you installed it in A2 — its own LoadBalancer) ---
ARGOCD_NAMESPACE=<ns-where-argocd-runs>       # e.g. argocd-instance-1 — where the A2 ArgoCD runs
ARGOCD_APP_NAME=webui
ARGOCD_DEST_NAMESPACE=webui
ARGOCD_TRACK_BRANCH=main
ARGOCD_SERVER=<argocd-server-LB-IP>           # the A2 argocd-server EXTERNAL-IP (for the UI + fetch-argocd-ca)
# ARGOCD_CA_FILE=./secrets/argocd-ca.crt      # ArgoCD's self-signed CA (step 2, make fetch-argocd-ca)

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
from the running Harbor with **`make fetch-harbor-ca`** (reads `HARBOR_URL`, writes
`HARBOR_CA_FILE`), or by hand:

```bash
make fetch-harbor-ca                         # convenience: HARBOR_URL → HARBOR_CA_FILE
# …or the equivalent by hand:
mkdir -p secrets
openssl s_client -connect <harbor-host>:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > secrets/harbor-ca.crt
```

(Or download it from the Harbor UI → your project → **Registry Certificate**.) The CA is
consumed in **two** places, both handled for you: `make mirror` builds a **sudo-free** trust
bundle (`SSL_CERT_FILE` = the system CAs + your Harbor CA) so `crane` pushes over HTTPS
**without** touching the jump box's system trust store, and `make platform` creates an
in-cluster ConfigMap **`harbor-ca`** (key `ca.crt`) so Kaniko/Tekton trust it too. If Harbor
presents a publicly-trusted cert, leave `HARBOR_CA_FILE` empty.

For **ArgoCD**'s self-signed CA (only needed if you drive `argocd login` with verification, or
to trust its UI), fetch it the same way — set `ARGOCD_SERVER` to the A2 `argocd-server` LB IP and
run **`make fetch-argocd-ca`** (writes `ARGOCD_CA_FILE`). The pipeline wires ArgoCD via `kubectl`
(not the `argocd` CLI), so this is optional for the demo itself.

**Step 3 — install prereqs and log in to VKS:**

```bash
make deps         # crane, tkn, argocd, kubectl, helm, mise tools
make vks-login    # validates $KUBECONFIG + context against the lab cluster
```

**Step 3b (optional) — install the Broadcom VCF/VKS lab CLIs.** To drive the lab's
VKS-provided ArgoCD directly (`argocd login`, open its UI) or use the `vcf` Consumption CLI +
plugins, you need the **licensed** `argocd-vcf` + `vcf` binaries. The pipeline itself wires
everything via `kubectl`, so this is optional for the demo. They install **sudo-free** to
`~/.local/bin`, and the installer picks the right archive for the jump box's **OS/arch**.

**Supply them as a folder.** Download the artifacts — however you have entitlement (the
[Broadcom support portal](https://support.broadcom.com) or an internal mirror) — on an
internet-connected box, drop them **all in one directory** (e.g. your browser's default
`~/Downloads/vcf`), and point `VCF_CLI_SRC_DIR` at it. This is the air-gap-correct path: carry
the folder in, no download client / token / network at install time.

**Just dump everything in there — the installer auto-selects.** You don't have to prune the
folder to this box's platform: it may hold every arch (`…-Linux_AMD64-…` + `…-Linux_ARM64-…`),
macOS builds, **and** the portal's multi-arch `…-Binaries-…` bundle, all at once. The installer
picks the archive matching **this jump box's OS/arch** and the **pinned versions** (from
`.env.example`) and ignores the rest — a mixed folder resolves deterministically, and if the
pinned version isn't present it errors clearly rather than ever installing a different version.

`VCF_CLI_SRC_DIR` is **required** — the installer does not guess where you dropped the files. Set
it on the command line, or uncomment it in `.env` (gitignored) so every `make` invocation picks
it up. The version pins in `.env.example` already match the current portal artifacts, so normally
you only set the folder:

```bash
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf   # argocd-vcf + vcf + vcf plugins
# or put it in .env once:  VCF_CLI_SRC_DIR=/home/you/Downloads/vcf   → then just `make install-vcf-clis`
# versions are pinned in .env.example (ARGOCD_VCF_VERSION / VCF_CLI_VERSION / VCF_PLUGINS_VERSION);
# keep them in sync with the artifacts you place in the folder.
```

**Packages this step needs** (`tar`, `gzip`/`gunzip`, `find`, `install`) — **`make deps`
already provides them** (`scripts/00-install-prereqs.sh` installs `tar`, `gzip`, `findutils`),
so if you ran the bootstrap you're covered. The installer also checks for them and errors
clearly if any is missing. On a minimal box where you skipped `make deps`:

- **Ubuntu:** present by default — nothing extra.
- **Photon OS:** `sudo tdnf install -y findutils` (`find` is not in Photon's base; its
  `gzip`/`tar` come from BusyBox-style **toybox**, which lacks `gzip -t` — the installer uses
  portable checks so it works there). `unzip` is **not** required — the artifacts are `.gz`/`.tar.gz`.

> **Fidelity vs a real lab.** The local KinD stand-in faithfully reproduces the lab's
> **self-signed-TLS + CA-trust** posture (Harbor HTTPS + ArgoCD self-signed TLS on their own
> LBs). Three things differ on a real VKS lab and must be verified there: the workload cluster
> trusts the Harbor CA **declaratively** via the Cluster spec `trust.additionalTrustedCAs`
> (not per-node `certs.d`); a **private** Harbor project needs a robot account +
> `imagePullSecret`; and the lab is **FQDN**-addressed. See
> [KinD TLS fidelity → Fidelity vs a real VCF/VKS 9.1 lab](docs/decisions/kind-tls-fidelity.md).

**Step 4 — Harbor projects + (recommended) a robot account.** `make mirror` (run in step 6)
creates the `cicd` and `apps` projects for you via Harbor's REST API if they don't exist
(needs push rights). It creates them **public** (`HARBOR_PUBLIC_PROJECTS=true`, the default),
so the cluster's containerd/kubelet pull the app image **anonymously** — the deployed manifest
carries no `imagePullSecret`, which is why the KinD demo needs none.

**If your lab mandates PRIVATE projects**, set `HARBOR_PUBLIC_PROJECTS=false` (so any project
`make mirror` auto-creates is private) or pre-create them private, and additionally create a
**robot-account image-pull secret** in the app namespace (`ARGOCD_DEST_NAMESPACE`) and
reference it from the app Deployment's `imagePullSecrets` — the pipeline's push secret
(`harbor-dockerconfig` in `ci`, step 5) authorizes **pushes only**, not the workload's pull.
The demo does not scaffold that pull secret (it assumes public projects); it is the one
private-lab step you supply by hand.

For least-privilege CI, create a Harbor **robot account** (push/pull scoped to the two projects)
instead of using `admin`. **`make harbor-robot`** does it via Harbor's REST API — it creates
`robot$<HARBOR_ROBOT_NAME>` (default `vks-cicd`) and writes the name + one-time secret to a
gitignored `secrets/harbor-robot.env` (mode 0600, never printed):

```bash
make harbor-robot                                  # → secrets/harbor-robot.env
# then copy its two lines (HARBOR_USERNAME='robot$vks-cicd' / HARBOR_PASSWORD=…) into .env
```

Confirm the namespace your ArgoCD (A2) runs in / watches (for `ARGOCD_NAMESPACE`):

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

<details>
<summary>Create or rotate <code>harbor-dockerconfig</code> by hand (only if needed)</summary>

<br>

Keep the secret **off argv** — build the `config.json` on disk and load it from a file; kaniko
needs the key named literally `config.json`, not `.dockerconfigjson`:

```bash
umask 077
auth=$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 -w0)
printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" > /tmp/harbor-config.json
kubectl -n ci create secret generic harbor-dockerconfig \
  --from-file=config.json=/tmp/harbor-config.json --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/harbor-config.json
```

</details>

The Kubernetes secret is built from your Harbor **login/password**; Harbor's **REST API** is
used only to create the *projects* (and, optionally, a robot account) — it does not create
this cluster secret.

**Step 6 — install everything and verify end-to-end:**

```bash
make install-all   # mirror → builder-image → vks-login → platform → gitops
make verify        # push a marked change → Tekton → Harbor → ArgoCD → live app serves it
```

`install-all` deliberately does **not** install Harbor or ArgoCD — those you installed in
**Part A**. It mirrors all images into that Harbor, builds + pushes the offline Maven builder
image, installs Gitea + Tekton, and creates the ArgoCD `Application`.

**Step 7 — access the UIs.** Harbor and ArgoCD are your **Part A** installs — use the FQDN /
LB IP + admin credentials you set there. For **Gitea** (which you installed) and the deployed
**app**, either run
`make install-ingress` to reach them by hostname at `*.vks.local` (add the printed
`INGRESS_LB_IP` line to `/etc/hosts`; see [Access the UIs](#access-the-uis-urls-logins-passwords)),
or use `kubectl port-forward` — `kubectl -n gitea port-forward svc/gitea-http 3000:3000` and
`kubectl -n webui port-forward svc/webui 18080:80`.

<details>
<summary><strong>VKS-lab checklist</strong> — easy-to-miss items (click to expand)</summary>

<br>

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

</details>

## Try it locally end-to-end with KinD

You don't need a VKS cluster to exercise the whole pipeline. `make e2e-kind` stands up a
local [KinD](https://kind.sigs.k8s.io/) cluster, installs the "VKS-provided" pieces
(**Harbor** + **ArgoCD**) into it, then runs the exact same
`mirror → builder → platform → gitops → verify` flow the real environment uses. This path
is verified end-to-end (git push → Tekton build → Harbor → ArgoCD → the live app serves
the new version).

```bash
cp .env.example .env          # set HARBOR_PASSWORD + GITEA_ADMIN_PASSWORD (any demo values)
make deps                     # kind, helm, kubectl, crane, etc.
make e2e-kind                 # cluster → Harbor → ArgoCD → mirror → build → deploy → ingress → verify
# open the UIs (see "Access the UIs" below) and drive the pipeline by hand:
# → "Demo walkthrough" below walks a code change from Gitea to the live page
make kind-down                # tear everything down (also prunes cloud-provider-kind orphans)
```

How the local stand-in works:

- **`cloud-provider-kind`** gives Harbor a real `LoadBalancer` IP on the kind docker
  network — reachable by the *same IP* from the host (push), Kaniko pods (push), and
  containerd (pull), which is what makes one image ref work everywhere.
- Harbor runs **self-signed HTTPS on its LB IP** by default (mimicking the VCF/VKS lab —
  see [KinD TLS fidelity](docs/decisions/kind-tls-fidelity.md)); `install-harbor` mints a
  self-signed CA + leaf (SAN = the LB IP) and wires each node's containerd
  (`/etc/containerd/certs.d/<ip>/`) with that **CA** so pulls verify over TLS. The CA is
  trusted at every consumer **sudo-free** — jump-box `crane`/`curl` via `SSL_CERT_FILE`, the
  builder push via podman `--cert-dir`, in-cluster Kaniko via the `harbor-ca` ConfigMap. It
  writes the discovered `HARBOR_URL` (the LB IP) + `HARBOR_CA_FILE` + `KUBECONFIG` into a
  gitignored **`.env.kind`** overlay so the normal scripts target the kind cluster unchanged.
  Harbor **and** ArgoCD both default to secure (self-signed TLS, mimicking the VCF/VKS 9.1
  lab). For the original plain-HTTP fast-iteration mode, flip both switches:
  `make e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1`. Both modes are validated locally.
- `make vks-login` uses the kind kubeconfig (`VKS_AUTH_METHOD=kubeconfig`), so no VCF auth
  is needed for the local run.
- **`make install-ingress`** installs one ingress LoadBalancer (`INGRESS_CONTROLLER=istio`
  by default, `traefik` optional) that fronts the Gitea/app/Tekton-Dashboard UIs at `*.vks.local`, so
  you reach them by hostname instead of `kubectl port-forward`. **Harbor and ArgoCD each keep
  their own direct LB** — Harbor's IP is load-bearing for the containerd pull path, and ArgoCD
  gets its own self-signed-TLS LB (like the real VKS lab, which does not front ArgoCD behind
  the shared ingress). Both ingress images are mirrored into Harbor.

Individual targets: `make kind-up`, `make install-harbor`, `make install-argocd`,
`make install-ingress` (or `make install-istio` / `make install-traefik`).

## Access the UIs (URLs, logins, passwords)

Run **`make creds`** — it self-resolves the kubeconfig and prints the URLs, logins, and (when an
ingress is installed) the one-time `/etc/hosts` line for the `*.vks.local` hosts. **Which URLs are
correct depends on the context** — Harbor and ArgoCD are *ours* in KinD but the *lab's* on a real
VKS cluster:

- The **`*.vks.local`** hostnames exist **only after `make install-ingress`** (part of
  `make e2e-kind`; a separate, optional step in the lab flow) and front only the UIs this project
  controls — **Gitea, the app, and the Tekton Dashboard**.
- **Harbor and ArgoCD are never behind the ingress** — each has its own LB address in both
  contexts. In KinD, Harbor is **self-signed HTTPS on its LB IP** and ArgoCD is **self-signed
  TLS on its own LB IP** (published as `ARGOCD_LB_IP`); the real lab serves the same posture at
  the lab's own URLs. The KinD-vs-lab gap shrinks to "we mint the cert locally".

| Service | Local KinD | Real VKS lab | Login |
|---------|------------|--------------|-------|
| **Gitea** (we install) | <http://gitea.vks.local> | `http://gitea.vks.local` after `make install-ingress`, else `kubectl -n gitea port-forward svc/gitea-http 3000:3000` | `gitea_admin` / `GITEA_ADMIN_PASSWORD` |
| **Tekton Dashboard** (we install) | <http://tekton.vks.local> | same — ingress or `port-forward` | — (read-only) |
| **App (webui)** (we deploy) | <http://app.vks.local/> | same — ingress or `port-forward svc/webui` | — (health at `/actuator/health`) |
| **Harbor** | its own LB IP, **self-signed HTTPS** (`https://<ip>`, our CA) | the **lab's** Harbor URL, **HTTPS** | `admin` / `HARBOR_PASSWORD` |
| **ArgoCD** | its own LB IP, **self-signed TLS** (`https://<ARGOCD_LB_IP>`, `--insecure`) — **not** behind the ingress | the **lab's own ArgoCD** URL/IP, self-signed TLS | `admin` / `make argocd-password` |

**ArgoCD password** — `make argocd-password` reveals it for either context:

- **KinD:** set `ARGOCD_ADMIN_PASSWORD` in `.env` for a known, stable login (applied at
  `make install-argocd`, like Gitea/Harbor); leave it blank to keep ArgoCD's auto-generated
  password. Either way `make argocd-password` prints it — no `kubectl`/context needed.
- **Real VKS:** ArgoCD is lab-provided — leave `ARGOCD_ADMIN_PASSWORD` blank; the command
  reads the initial-admin secret if present, otherwise points you to your lab.

> Without the ingress (or before adding the `/etc/hosts` line), the same services are still
> reachable over `kubectl port-forward` — e.g. `kubectl -n gitea port-forward svc/gitea-http
> 3000:3000` → <http://localhost:3000>. Harbor and ArgoCD are always direct LoadBalancers, not behind the ingress.

The **Tekton Dashboard** (above) is Tekton's web UI. The Tekton **EventListener** is a
separate, in-cluster-only webhook receiver (`el-webui.ci.svc:8080`) — the Gitea webhook fires
cluster-internally, so there is nothing to expose or log into there.

## Demo walkthrough — drive the GitOps loop by hand

This is the demo. With the stack up (`make e2e-kind` locally, or `make install-all` against a
real VKS lab) you can watch a **one-line code change flow from the Gitea web editor all the way
to the running web page — entirely inside the air gap**, and see each hop in its own Web UI.
`make verify` does exactly this automatically; the steps below are the same loop by hand.

**Before you start:** run **`make creds`** for the URLs, logins, and the one-time `/etc/hosts`
line that maps the `*.vks.local` hosts to the ingress LoadBalancer (see
[Access the UIs](#access-the-uis-urls-logins-passwords)). Open these four UIs in tabs:

| UI | URL | Login | What you'll watch |
|----|-----|-------|-------------------|
| **App (webui)** | <http://app.vks.local/> | — | the greeting that changes |
| **Gitea** | <http://gitea.vks.local> | `gitea_admin` / your `GITEA_ADMIN_PASSWORD` | edit source; see the tag write-back |
| **Tekton Dashboard** | <http://tekton.vks.local> | — (read-only) | the PipelineRun: test → build → deploy |
| **Harbor** | its own LB IP, self-signed HTTPS (KinD) or the lab's HTTPS URL | `admin` / your `HARBOR_PASSWORD` | the freshly-built image |
| **ArgoCD** | its own LB IP, self-signed TLS (`https://<ARGOCD_LB_IP>`, `--insecure`) on KinD — on a real VKS lab, **your lab's own ArgoCD URL** | `admin` / `make argocd-password` | the sync that rolls the new image |

1. **See the current greeting.** Open <http://app.vks.local/>. The page shows a greeting —
   `Hello from vks-airgap-cicd` by default — rendered in the `<p class="message">` element,
   alongside the app version and git commit. This is what will visibly change.

2. **Edit the greeting in Gitea.** Go to **`demo/webui-app`** →
   `src/main/resources/application.yml`, click the **edit (pencil)** icon, and change the
   greeting default on line 18:

   ```yaml
   # from:
     message: ${APP_MESSAGE:Hello from vks-airgap-cicd}
   # to (any text):
     message: ${APP_MESSAGE:Hello from the air-gapped pipeline}
   ```

   **Commit directly to `main`.** The commit fires the Gitea push webhook
   (`el-webui.ci.svc:8080`) → the Tekton EventListener → a new PipelineRun. (This is the same
   `application.yml` line `make verify` rewrites with a unique marker.)

3. **Watch Tekton build it.** In the **Tekton Dashboard** (<http://tekton.vks.local>), a new
   **`webui-ci-*`** PipelineRun appears in the `ci` namespace. Its TaskRuns run in order — open
   each to tail logs live:

   | TaskRun | Does |
   |---------|------|
   | `clone-app` | clones `webui-app`; its short commit SHA becomes the image tag |
   | `test` | runs `./mvnw -B -o test` **offline** (against the deps-baked builder image) |
   | `build` | **Kaniko** builds the image and pushes it to Harbor |
   | `deploy-update` | writes the new tag back into `webui-deploy` (the GitOps hand-off) |

4. **See the new image in Harbor.** In Harbor, open project **`apps`** → repository
   **`webui`**. A new tag appears — the **git short SHA** of your commit
   (`harbor.vks.local/apps/webui:<sha>`) — pushed by the Kaniko `build` task.

5. **See the tag written back in Gitea.** Open **`demo/webui-deploy`** → `kustomization.yaml`.
   There's a new commit by **`ci-bot`** with message **`ci: deploy webui <sha>`** that bumps
   `images[0].newTag` to your `<sha>`. This deploy repo — not the app repo — is what ArgoCD
   watches, which is why the tag write-back (not the source push) is what triggers a deploy.

6. **Watch ArgoCD deploy it.** In **ArgoCD** (its own self-signed-TLS LB IP on KinD —
   `https://<ARGOCD_LB_IP>`, shown by `make creds`; on a real VKS lab, **your lab's own
   ArgoCD URL**), the Application
   **`webui`** flips **`OutOfSync → Synced`** (auto-sync + self-heal) and rolls the Deployment
   in namespace `webui` to `harbor.vks.local/apps/webui:<sha>`. (Auto-sync polls the deploy repo
   on an interval; click **Refresh** to reconcile immediately.)

7. **See the page change.** Refresh <http://app.vks.local/>. The greeting now shows your new
   text. That change went **source → test → image → registry → GitOps write-back → cluster →
   running page** without a single byte crossing the air gap.

> **`make verify` is the automated form of this whole loop** — it edits the same
> `application.yml` line with a unique marker, waits for the PipelineRun to succeed, forces an
> ArgoCD refresh, waits for the *deployed image* to change, then curls
> <http://app.vks.local/> until the page contains the marker. Run it to prove the pipeline;
> walk the UIs above to *see* it.

## Detailed steps

Legend: **[offline]** verifiable without a cluster · **[cluster]** runs against live VKS.

| # | Command | Mode | What happens |
|---|---------|------|--------------|
| 1 | `cp .env.example .env` + edit | [offline] | Set Harbor/Gitea URLs, VKS auth, CA files, and secrets (`HARBOR_PASSWORD`, `GITEA_ADMIN_PASSWORD`). |
| 2 | `make deps` | [offline] | `mise install` (kubectl, helm, crane, jq, yq, …) + `scripts/00-install-prereqs.sh` (tkn, argocd). |
| 3 | `make ci` | [offline] | toolchain/image alignment + shellcheck + yamllint + hadolint + kubeconform + gitleaks + trivy fs/config + `mvn test` + docs/diagram checks. |
| 4 | `make mirror` | [cluster] | `10-mirror-pull.sh` pulls all images (+ Tekton release manifests) then `21-mirror-push.sh` pushes them into Harbor. **Sneakernet:** `make mirror-pull && make bundle`, carry the bundle, then `make bundle-load BUNDLE_TARBALL=… && make mirror-push` inside. |
| 5 | `make builder-image` | [internet] | Builds the Maven builder image with this app's deps pre-baked and pushes it to Harbor (so in-cluster CI builds offline). |
| 6 | `make vks-login` | [cluster] | `30-vks-login.sh` writes a working `$KUBECONFIG`/context (see auth note). |
| 7 | `make platform` | [cluster] | Installs Gitea (`k8s/gitea/`), seeds the two repos + webhook, installs Tekton (images remapped to Harbor), applies the pipeline/triggers. |
| 8 | `make gitops` | [cluster] | Registers the deploy repo and creates the ArgoCD `Application` (auto-sync). |
| 9 | `make verify` | [cluster] | Pushes a marked change to `webui-app`, then asserts: PipelineRun succeeds → image in Harbor → deploy tag bumped → ArgoCD Synced/Healthy → the live page shows the marker. |

> **The mirror is resumable and verifiable.** If `make mirror` / `make mirror-pull` is
> interrupted (Ctrl+C, dropped connection, an upstream-CDN reset such as ghcr.io throttling),
> **just re-run it** — every digest-pinned image already fully pulled is **skipped** (a
> per-image `.mirror-ok` completeness marker, written only on a complete pull), so it
> **resumes** from where it stopped instead of re-pulling all of them. Progress shows as
> `[i/N] (elapsed …)` so you can see it moving. `MIRROR_RETRIES` (default 5) sets per-image
> retries; `MIRROR_FORCE_PULL=1` re-pulls everything.
>
> After pushing, run **`make mirror-verify`** to confirm every image is intact in Harbor —
> `crane validate` fetches and digests each layer (catches a corrupt/incomplete blob before
> it surfaces mid-pipeline as `MANIFEST_UNKNOWN`/`BLOB_UNKNOWN`) and cross-checks Harbor's
> digest against `images.lock`. `mirror-verify` is **read-only**, so it too is safe to
> interrupt and re-run.

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
| Prereqs | `deps` | Install the jump-box toolchain (mise tools incl. crane + tkn/argocd) |
| Prereqs | `install-vcf-clis` | Install the Broadcom VCF/VKS lab CLIs (argocd-vcf + vcf + plugins), sudo-free — lab-only, licensed artifacts from a folder (`VCF_CLI_SRC_DIR`) |
| Mirror | `mirror` / `mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | Pull images → Harbor (dual-homed), or the sneakernet phases |
| Mirror | `builder-image` | Build + push the deps-baked offline Maven builder image |
| Install | `vks-login` / `platform` / `gitops` / `install-all` | Auth to VKS; install Gitea+Tekton; wire ArgoCD; or all of it |
| Install | `fetch-harbor-ca` | Fetch a self-signed lab Harbor's CA cert → `HARBOR_CA_FILE` (VKS-lab convenience) |
| KinD e2e | `e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify) |
| KinD e2e | `kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps (`install-istio` / `install-traefik` pick the controller) |
| Verify | `verify` | End-to-end smoke test on a LIVE cluster |
| Verify | `verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| Verify | `jumpbox` / `jumpbox-both` | Validate the README bootstrap on a real jump-box container — `JUMPBOX_OS=photon`\|`ubuntu`, or both (needs the KinD cluster up) |
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
