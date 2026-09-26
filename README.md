[![CI](https://img.shields.io/github/actions/workflow/status/AndriyKalashnykov/vks-airgap-cicd/ci.yml?branch=main&label=CI&style=flat)](https://github.com/AndriyKalashnykov/vks-airgap-cicd/actions/workflows/ci.yml)
[![Renovate enabled](https://img.shields.io/badge/renovate-enabled-brightgreen?logo=renovatebot&style=flat)](https://docs.renovatebot.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen?style=flat)](LICENSE)

# Air-gapped CI/CD on VMware VKS

Reference implementation of an end-to-end CI/CD pipeline for a **fully air-gapped** VKS cluster
(VMware vSphere Kubernetes Service, VCF 9 + Supervisor).

- **Pipeline** — self-hosted **Gitea** + **Tekton**: test → **Kaniko** build → **Harbor** push →
  GitOps write-back (the version tag AND the commit sha) → **ArgoCD** sync → the live page.
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

An in-cluster build reaches **no package registry**, so every app ships a **pre-baked builder image**
(`Dockerfile.builder`) carrying its own dependency cache. All six are built on the
internet-connected jump box, pushed to Harbor, and consumed offline:

| app | cache it bakes | fetched from |
|---|---|---|
| `javawebapp` | `~/.m2` (`./mvnw -B verify`) | `repo.maven.apache.org` |
| `gowebapp` | the Go module cache (`go mod download`) | `proxy.golang.org` |
| `nodejswebapp` | `node_modules` (`npm ci`) | `registry.npmjs.org` |
| `pythonwebapp` | the venv (`pip install -r requirements.txt`) | `pypi.org` |
| `rustwebapp` | the cargo registry (`cargo fetch --locked`) | `crates.io` |
| `dotnetwebapp` | the NuGet cache (`dotnet restore`) | `api.nuget.org` |

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

### Tested platforms

Each row was produced by `make platform-report` on that host: every result is that target's own exit
code, and the test counts are the runner's own verdict line. Re-run it to refresh a row; a row names
the commit it measured, so an old row is dated, not wrong.

| OS | Arch | Host tools | Offline gates (commit, date, result) |
|----|------|------------|--------------------------------------|
| Ubuntu 24.04.5 LTS | x86_64 | GNU Make 4.3, bash 5.2.21, git 2.43.0, podman 4.9.3 (server 4.9.3 linux/amd64), docker 29.8.1 (server 29.8.1 linux/amd64) | `static-check` PASS (166 tests, 0 failed, 1 with skipped arms); `docs-lint` PASS @ `b4006c8`, 2026-09-25 |
| macOS 26.6.2 | arm64 (Apple M1) | GNU Make 4.4.1 (`gmake`), bash 5.3.20, git 2.55.0, podman 6.1.2 (server 6.1.2 linux/arm64), docker 29.8.1 (no daemon) | `static-check` PASS (166 tests, 0 failed, 4 with skipped arms); `docs-lint` PASS @ `b4006c8`, 2026-09-25 |

**Lab targets.** The lab-backed, non-KinD targets were run against a live VKS lab (guest cluster
on Kubernetes v1.36.2), serially, one box at a time, at commit `0440796`. The macOS
row reached the lab **through a test harness**, [`scripts/mac-lab-tunnel.sh`](scripts/mac-lab-tunnel.sh):
per-IP SSH reverse forwards, with the lab's names in the Mac's `/etc/hosts`. So it does not test real DNS,
the routing between a jump box and the lab, or the source address the lab sees.

| Class | Linux | macOS (via tunnel harness) |
|-------|-------|----------------------------|
| Read-only (28: `preflight`, `env-validate`, `creds-show`, `mirror-verify`, `verify-ingress`, …) | 28/28 PASS | 28/28 PASS |
| Idempotent installers, in scenario order (34, ending with `verify` and `install-all`) | 32/34 PASS; 2 refused as designed on this lab (below) | 30/34 PASS with `BUILD_EMULATE=1`; the same 2 refused as on Linux, plus 2 Linux-only (below) |
| Not run by design on a shared lab (24) | — | — |
| KinD, sneakernet and Linux test harnesses (28) | not in this table | out of scope on macOS |

- **After the macOS run, Linux re-verified the lab** (the Mac's builds replace the same Harbor tags the
  guest pulls): `verify` passed end to end for every app, from git push to the live page.
- **How the counts reconcile:** `creds` is an alias of `creds-show`; `creds-renew` ran once before the
  run (it spends one SSO attempt); `mirror-pull` and `mirror-push` are exercised inside `mirror`.
- **`mirror-verify` coverage depends on the local bundle:** in the read-only pass the Mac had never run
  `mirror-pull`, so it checked 17 images and skipped the provenance check (it says so). After `mirror`,
  both boxes verified the same 31 images intact.
- **Refused as designed:** `fetch-harbor-ca`, because this lab's Harbor serves only its leaf certificate
  and there is no CA on the wire to fetch. `fetch-argocd-ca`, because `ARGOCD_SERVER` is an IP and the
  certificate carries only names ([B486](BACKLOG.md)).
- **Linux-only for now (macOS):** `trust-harbor` and `engine-trust-check` refuse on macOS, because the
  engine trusts registries inside its VM, which this repo does not configure. Pushes to Harbor use
  `crane` and do not need it ([B735](BACKLOG.md)). On the Mac the images were built `linux/amd64`
  under emulation (Rosetta), and `install-all` took about 25 minutes.
- **Not run by design:** destructive or whole-vCenter targets (`wcp-restart`, `vcenter-repair`,
  `uninstall-*`, `vks-cluster-delete`, `mirror-verify-red-test`, …); targets that install a Supervisor
  Service or mint a new credential (`install-harbor-service`, `install-argocd-service`, `harbor-robot`,
  `harbor-admin-password`, `harbor-ca-from-cluster`); `env-init` / `env-populate`, which rewrite `.env`; and targets that switch
  the lab's ingress (`install-traefik`, `attach-istio`, `verify-ingress-both`).

**What this does and does not cover.** `static-check` is the full offline gate: lint, manifest
validation, security scans and every script unit test. It needs no lab. CI runs it on a schedule or a manual dispatch; a
pull request runs only a faster subset — see [CI/CD](docs/ci-cd.md). The lab-backed targets are in
the **Lab targets** table above.

- Tools pinned in [`.mise.toml`](.mise.toml) (kubectl, crane, helm, linters…) are not listed; the
  commit in each row pins them. On macOS, `crane` is built from source with Go ≥ 1.27 so it can trust
  Harbor's CA ([B735](BACKLOG.md)).
- **macOS:** use `gmake` (Homebrew GNU make). Apple's `/usr/bin/make` 3.81 is refused. Building the
  images on Apple silicon needs `BUILD_EMULATE=1` and Rosetta for the podman machine — see
  [Scenario 1](docs/scenario-1.md). The `gmake` bootstrap is in
  [Common bootstrap](docs/common-bootstrap.md).
- Out of scope on macOS ([B735](BACKLOG.md)): the KinD targets and the sneakernet flow;
  `make bundle` refuses to run there.

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
