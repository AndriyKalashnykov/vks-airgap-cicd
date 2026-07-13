[![CI](https://img.shields.io/github/actions/workflow/status/AndriyKalashnykov/vks-airgap-cicd/ci.yml?branch=main&label=CI&style=flat)](https://github.com/AndriyKalashnykov/vks-airgap-cicd/actions/workflows/ci.yml)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovatebot&style=flat)](https://docs.renovatebot.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen?style=flat)](LICENSE)
[![Hits](https://hits.sh/github.com/AndriyKalashnykov/vks-airgap-cicd.svg?view=today-total&style=flat&color=4c1)](https://hits.sh/github.com/AndriyKalashnykov/vks-airgap-cicd/)

# Air-gapped CI/CD on VMware VKS

Reference implementation of an end-to-end CI/CD pipeline for a **fully air-gapped**
VKS cluster (VMware vSphere Kubernetes Service, VCF 9 + Supervisor). Two surfaces:

- **Pipeline surface** — self-hosted **Gitea** + **Tekton** (test → **Kaniko** build →
  **Harbor** push → GitOps tag write-back), wired to **Harbor** + **ArgoCD**, which run as **Supervisor Services** (you install them, or they already exist and you are a tenant).
- **Delivery surface** — an OS-portable (Ubuntu / PhotonOS) jump-box image mirror (**crane**,
  dual-homed or sneakernet), a dependency-baked offline **Maven** builder, an **optional** pluggable
  ingress (**Istio** default, **Traefik** optional — or **attach to the Istio a VKS cluster already
  has**, since Istio ships there as a VKS Standard Package) fronting the UIs at `*.vks.local`, and a
  one-command **KinD** end-to-end that proves the whole flow locally.

  The ingress is **not part of the pipeline** and **not part of `make install-all`** — it only decides
  *how you reach the UIs*. `make verify` proves the whole GitOps loop over a **port-forward**, so it
  needs no ingress and no `/etc/hosts` entry. Add one when you want `*.vks.local` URLs
  (`make install-ingress`; on VKS **`INGRESS_CONTROLLER=istio-existing`** — attach only, never
  install a second istiod over the platform's mesh).

<p align="center"><img src="docs/diagrams/out/airgap.png" alt="Air-gap connectivity: the jump box bridges the internet and the air-gapped VKS cluster; the cluster itself has no internet access" width="820"></p>

<p align="center"><em>The jump box is the only bridge — it pulls from the internet and pushes into the air-gapped cluster, which has no internet access of its own.</em></p>

> A developer pushes a change to **Gitea** → **Tekton** runs tests, builds a container
> image with **Kaniko** and pushes it to **Harbor** → Tekton bumps the image tag in the
> deploy repo → **ArgoCD** syncs the new version to the cluster → the web UI updates.
> On VKS, **Harbor** and **ArgoCD** run as **Supervisor Services** (on the Supervisor —
> you either install them, or they already exist and you're a tenant), and **Istio** is a **VKS
> Standard Package** in the guest cluster — so this project **attaches** to it rather than
> installing it. What this project always owns: mirroring every required image into Harbor, and
> installing + wiring **Gitea + Tekton** and the demo app.
> See [`docs/vks-services/`](docs/vks-services/) for what each service is, and how to install/configure/use it.

## Choose your path

New here? Pick the path that matches your situation — each one is self-contained end to end:

1. **KinD** — *see it work.* No VKS cluster, **zero `.env`**, one command.
2. **VKS — I install Harbor + ArgoCD** (as **Supervisor Services**) — I am the admin: I provision the workload cluster too, then run the pipeline.
3. **VKS — Harbor + ArgoCD already exist** — I am a **tenant**: I **discover** them,
   **request** what I'm not allowed to self-service, then run the pipeline.

| I want to… | Path | You need |
|------------|------|----------|
| **Just see it work** (no VKS cluster) | [KinD](docs/kind-local.md) — one command, zero `.env` | **Have:** Docker (KinD needs Docker specifically) · internet access<br>**Run:** `make deps` → `make e2e-kind` |
| **VKS — I install Harbor + ArgoCD** (I am the admin) | [Scenario 1](docs/scenario-1.md) | **Have:** a vSphere login that can install a Supervisor Service, create a vSphere Namespace and provision a guest cluster · cluster-admin on that guest cluster · the licensed VCF CLI archives ([where to get them](docs/vks-authentication.md))<br>**Reachable from the jump box:** the internet, the Supervisor API, Harbor — and ArgoCD's cluster must reach your guest API<br>**Run:** `make deps` → `make install-vcf-clis` → `make env-init` → `make env-populate` → `make env-check` → `make psa-check` |
| **VKS — Harbor + ArgoCD already exist** (I am a **tenant**) | [Scenario 2](docs/scenario-2.md) | **Have:** cluster-admin on your own guest cluster · Harbor **project-admin** (else ask for robot credentials) · the licensed VCF CLI archives<br>**Ask the platform team for:** your guest cluster **registered** with ArgoCD (admin-only) · an ArgoCD role that lets you create an `Application` · mesh rights — `make istio-preflight` prints exactly what to request<br>**Run:** `make deps` → `make install-vcf-clis` → `make env-init` → `make env-populate` → `make harbor-robot` → `make psa-check` |

The VKS paths start from the jump-box **[Prerequisites](#prerequisites)** below.
Run **`make check-tools`** to see which CLIs you have and which are required.

> **Container engine:** podman or Docker on VKS (`CONTAINER_ENGINE`, podman preferred).
> `make e2e-kind` requires **Docker** specifically.

## Demo apps

The demo ships **two apps, in two languages**, and runs both through the *same* walk:
`git push` → Tekton (test → Kaniko build → Harbor → tag write-back) → ArgoCD → the live page.
`apps/registry.tsv` is the single source of truth — seeding, Tekton, ArgoCD, the ingress, PSA and
the gates all loop over it.

**The two languages are not decoration — they are the air-gap story.** The Java app needs a
**pre-baked offline Maven builder image** (`Dockerfile.builder`), because an in-cluster `mvn` cannot
reach Maven Central. The Go app is **stdlib-only**, so its air-gapped build fetches *nothing* and it
needs **no builder image at all**. Same pipeline, and the difference is one `case` branch.

`make verify` proves **each app independently** (its own marker, its own PipelineRun, its own
deployed image) — a green `javawebapp` never hides a broken `gowebapp`.

<details>
<summary><strong>Add another app</strong> — one row in <code>apps/registry.tsv</code></summary>

<br>

**One row** in `apps/registry.tsv` (a new *language* is that row plus one `case` branch in
`scripts/lib/apps.sh`):

```tsv
# name        lang  src                   deploy
javawebapp    java  apps/java/javawebapp  deploy/javawebapp
gowebapp      go    apps/go/gowebapp      deploy/gowebapp
```

Each app gets: its own Gitea repos (`<app>-app` + `<app>-deploy`), its own Tekton `Pipeline`
(`<app>-ci`) and `Trigger`, its own Harbor repo, its own namespace, its own ArgoCD `Application`,
its own ingress host — and `make verify` proves **each app independently** (its own marker on its
own page). `make check-app-hardcodes` fails the build if any shared file (**including
`.env.example`**) names an app — that is the gate that keeps "one row" true.

The **ingress hostname is derived, not configured**: an app is reachable at
**`<app>.${APP_DOMAIN}`** (`APP_DOMAIN=vks.local`, one global in `.env.example`). There is no
per-app `<APP>_HOST` variable — there used to be, and it meant a new row silently died until you
*also* edited `.env.example`, so "one row" was a lie the gates could not see.

Only two things differ per language: which Tekton task runs the tests (`maven-test` / `go-test`),
and where `verify` injects its marker. Both live in `scripts/lib/apps.sh`.

</details>

<details>
<summary><strong>On VKS, adding an app may need grants you must request</strong></summary>

<br>

Locally (and in **Scenario 1**, where you are the admin) nothing else is needed. As a **tenant**
(Scenario 2) an app's **new namespace** and **new hostname** may not be covered by what you were
granted. What that means concretely:

| What | When it bites | What to run / ask for |
|---|---|---|
| **ArgoCD AppProject destination** | Always, as a tenant (you get your own AppProject; ours defaults to `default`, which permits everything — VKS's will not). The `Application` is rejected: *"application destination … is not permitted in project"* | **Check first:** `kubectl -n $ARGOCD_NAMESPACE get appproject <yours> -o jsonpath='{.spec.destinations}{"\n"}{.spec.sourceRepos}'` — your new namespace AND the new `<app>-deploy` repo URL must both be listed.<br>**Ask the ArgoCD admin** to add them: `kubectl -n $ARGOCD_NAMESPACE patch appproject <yours> --type=json -p='[{"op":"add","path":"/spec/destinations/-","value":{"server":"$ARGOCD_DEST_SERVER","namespace":"<app>"}},{"op":"add","path":"/spec/sourceRepos/-","value":"<gitea>/<org>/<app>-deploy.git"}]'` |
| **Ingress hostname on a SHARED Gateway** | **Only** on the classic route API against a platform-owned Gateway (`ISTIO_SHARED_GATEWAY`). Its `hosts:` list belongs to the mesh admin, so an unlisted host **404s from a listener that exists** | **Check first:** `make istio-preflight` (and `istio_assert_shared_gateway_hosts` fails the install rather than 404ing later).<br>**Ask the mesh admin** to admit the host — ideally once, as a wildcard: `kubectl -n <gw-ns> patch gateway <gw> --type=json -p='[{"op":"add","path":"/spec/servers/0/hosts/-","value":"*.vks.local"}]'` |
| **Harbor** | Never (for a *new app*) | Nothing to do **when adding an app**: the robot's push+pull is scoped to the whole project, so a new repo under it is already covered — and `make gitops` creates the `harbor-pull` Secret in the new app's namespace for you. **But the robot itself is not always self-serviceable**: only a Harbor **system-admin** can create one that spans two projects. See [Scenario 2 → grants](docs/scenario-2.md). |

**On the Gateway-API path the hostname needs nobody:** Istio
auto-provisions the gateway from a `Gateway` we create in **our own** namespace, so its `hosts:`
list is ours. That leaves the AppProject destination as the only universal tenant request.

> **Provenance.** The *mechanism* is **KinD-verified** (`make e2e-kind-istio-existing` — Istio
> auto-provisioned the gateway and its LB from our own `Gateway`). That **Broadcom's Istio routes with
> the Gateway API** is **doc-inferred, never seen on a lab** — and it is load-bearing for a tenant
> (it decides whether you must ask the mesh admin for a hostname at all). It is item 12 of the
> [lab validation plan](docs/lab-validation-plan.md).
---
> ⚠️ **Provenance of the commands above: INFERRED, not lab-verified.** The *facts* are sourced —
> ArgoCD's AppProject restricts by `spec.destinations` + `spec.sourceRepos`
> ([docs](https://argo-cd.readthedocs.io/en/stable/user-guide/projects/)); the Harbor robot we mint
> is project-scoped (`scripts/22-harbor-robot.sh`); an Istio `Gateway`'s `hosts:` list gates which
> hostnames a VirtualService may bind. But the exact `kubectl patch` invocations have **not** been
> run against a VKS cluster, and the ArgoCD **server** there is 2.14.x (ours is 3.x). Treat them as
> a starting point, confirm against your lab, and correct this table. See the backlog in CLAUDE.md.

</details>

## Prerequisites

### Bootstrap a bare jump box (before you can clone this repo)

**Fast path (dual-homed Ubuntu/Photon)** — one command OS-gates, installs git/curl/make +
mise, clones this repo, runs `make deps`, and prints a toolchain report:

```bash
curl -fsSL https://raw.githubusercontent.com/AndriyKalashnykov/vks-airgap-cicd/main/bootstrap-jumpbox.sh | bash
```

**Prefer to read a script before running it?** Download, inspect, then run — instead of the one-liner above:

```bash
curl -fsSLO https://raw.githubusercontent.com/AndriyKalashnykov/vks-airgap-cicd/main/bootstrap-jumpbox.sh
less bootstrap-jumpbox.sh
bash bootstrap-jumpbox.sh
```

It's idempotent (re-run skips what's present); pin a ref with `REF=<tag-or-sha>`. It installs
only the **open** toolchain — the licensed VCF CLIs stay operator-supplied (`make install-vcf-clis`).
It needs internet (dual-homed); a fully air-gapped host uses the carried bundle instead.

> **`curl` must already be present** for the pipe form above. Ubuntu images ship it; a **bare
> Photon OS 5** box does **not** — run `sudo tdnf install -y curl` first, then re-run the command.
>
> The **`make deps` toolchain install + rootless-podman engine + cluster reachability** are
> validated end-to-end by `make jumpbox` — it runs them on a fresh jump-box container
> (`JUMPBOX_OS=photon` on `photon:5.0`, the default, or `JUMPBOX_OS=ubuntu` on `ubuntu:26.04`;
> `make jumpbox-both` runs the matrix), joined to a local KinD cluster with rootless podman, and
> fails if `make deps` or the container-engine setup breaks on a real jump box of that OS.

### Toolchain and access

- A jump box running **Ubuntu** or **PhotonOS** with internet access.
- Network reach to the Supervisor, Harbor, and (for dual-homed) the workload cluster.
- The Harbor **CA certificate** (`.env` → `HARBOR_CA_FILE`) — Harbor is self-signed HTTPS; Gitea is served over HTTP (no CA needed).
- [mise](https://mise.jdx.dev/) for the rest of the toolchain (installed by `make deps`; git must already be present).
- **Container engine:** image operations (mirror, Maven builder build/push, diagram
  rendering) use `CONTAINER_ENGINE` — **podman-preferred**, docker fallback. `make deps`
  installs the rootless-podman runtime deps per OS (crun + an active
  `unqualified-search-registries` on Photon; `uidmap` + `slirp4netns` on Ubuntu, which apt
  leaves out of a default podman install). The **local KinD end-to-end** additionally
  **requires Docker**: KinD's node and `cloud-provider-kind` run on the `kind` Docker network +
  socket. So a real air-gap run can be podman-only; `make e2e-kind` needs Docker.

## The three paths

Pick **one** and follow it end to end. Each document is **self-contained** — every command you need
is in it, and nothing you must *run* is hidden behind a further link. (A CI gate enforces exactly
that: `make check-readme-scenarios`.)

| Path | Document | You are |
|---|---|---|
| **See it work, locally** | **[KinD end-to-end](docs/kind-local.md)** | just trying the demo — one command, no lab, no `.env` |
| **VKS — I install Harbor + ArgoCD** (I am the admin) | **[Scenario 1](docs/scenario-1.md)** | the admin: you install them as **Supervisor Services**, then wire the pipeline |
| **VKS — they already exist** | **[Scenario 2](docs/scenario-2.md)** | a **tenant**: you *discover* the endpoints and *request* the grants you need |

Then: **[Access the UIs](docs/access-uis.md)** — URLs, logins, passwords.

## Reference

Background and deep-dives. **Nothing you have to *run* lives behind these links** — each scenario
above is self-contained end to end (a CI gate enforces that: `make check-readme-scenarios`).

| | |
|---|---|
| [Architecture](docs/architecture.md) | system context, containers, deployment, pipeline flow |
| [Tech stack](docs/tech-stack.md) | what the demo is built from |
| [Prerequisites — the manual path](docs/prerequisites-manual.md) | the step-by-step the bootstrap automates |
| [Sizing](docs/sizing.md) | jump-box disk + guest-cluster resources |
| [Repository layout](docs/repository-layout.md) | where things live |
| [Make targets](docs/make-targets.md) | every target, grouped |
| [CI/CD](docs/ci-cd.md) | what CI actually gates (and what it deliberately does not) |
| [VKS authentication](docs/vks-authentication.md) | how `$KUBECONFIG` is produced on VKS (`VKS_AUTH_METHOD`, the `vcf` CLI flow), and **why Scenario 1 needs a second kubeconfig**. Both VKS scenarios run `make vks-login` themselves; **the KinD path skips it entirely** |
| [Demo walkthrough](docs/demo-walkthrough.md) | drive the GitOps loop by hand |
| [Detailed steps](docs/detailed-steps.md) | the full step-by-step |
| [Lab validation plan](docs/lab-validation-plan.md) | the 24 steps to run on a **real VKS lab** to settle what KinD cannot — each with the command, what to capture, and what a PASS/FAIL proves |
| [VKS services](docs/vks-services/) | what Broadcom actually ships (Harbor / ArgoCD / Istio), each fact **graded** by provenance |
| [Decisions](docs/decisions/) | why the KinD stand-in is built the way it is |

## Configuration

Everything is driven by `.env` (copied from `.env.example`), with an optional `.env.kind`
overlay written by the KinD flow. Nothing is hardcoded in scripts or the Makefile. See
`.env.example` for the full, documented list of tunables.

## Contributing

Contributions welcome — open an issue or a pull request. Before pushing, run `make ci`
(the offline gate: alignment, lint, manifest validation, security scans, app tests, and
docs/diagram drift checks) so the change matches what CI enforces. Dependency updates are
managed by [Renovate](https://docs.renovatebot.com/); tool and image versions are pinned
via `.mise.toml`, `.env.example`, `images/images.txt`, and inline `# renovate:` comments.

## License

Released under the [MIT License](LICENSE).
