# Try it locally end-to-end with KinD

<br>

> **You want to *see it work*.** No VKS cluster and no `.env`. Once you have the repo:
> `make deps` -> `make e2e-kind` -> `make creds-show` (three commands).

`make e2e-kind` stands up a local [KinD](https://kind.sigs.k8s.io/) cluster, installs the pieces a real
VKS provides as Supervisor Services (**Harbor** + **ArgoCD**), and runs the **same**
`mirror → builder → platform → gitops → verify` flow the real lab uses — ending with a git push that
travels through Tekton, Harbor and ArgoCD to a live page.

## Get the repo

A stock box has none of this. Everything below runs from the repo root.

**Ubuntu / Debian:**

```bash
sudo apt-get update && sudo apt-get install -y --no-install-recommends git make curl ca-certificates
```

**Photon OS 5** — `openssh openssh-socket` are both required. Without them this box loses SSH during
the install and you cannot reconnect.

```bash
sudo tdnf install -y git make curl curl-libs ca-certificates openssh openssh-socket
```

Already root? Drop the `sudo`.

```bash
git clone https://github.com/AndriyKalashnykov/vks-airgap-cicd.git
cd vks-airgap-cicd
```

⚠️ **You also need Docker, and `make deps` will NOT install it.** kind's nodes *are* docker
containers, so this one path needs Docker specifically — with `CONTAINER_ENGINE` unset, `make deps`
installs **podman** and zero docker packages, and `make kind-up` then stops at `require_cmd docker`.
Install Docker from your distribution first, or run `make deps CONTAINER_ENGINE=docker`, which
installs it together with its rootless prerequisites. On a Mac, follow **On macOS** below instead.

## On macOS (Apple silicon)

Measured on an 8 GB M1 (macOS 26.6.2): every KinD e2e target passes
([results](tested-platforms.md)). `e2e-kind` takes about 25 minutes and the VM peaks at 4.1–4.3 GiB.
KinD needs a Docker daemon, so on a Mac it runs in a [Colima](https://github.com/abiosoft/colima) VM.
Use these commands on a Mac instead of the **Run it** block below.

First install the macOS base tools: the `brew install` line in
[Common bootstrap](common-bootstrap.md) (GNU bash, sed, coreutils and the rest). The scripts refuse to
run with macOS's own bash 3.2 and BSD `sed`, so `deps` cannot start without them. Then:

```bash
brew install colima docker docker-buildx chipmk/tap/docker-mac-net-connect
softwareupdate --install-rosetta --agree-to-license   # no-op if Rosetta is already installed
podman machine stop 2>/dev/null   # only if you have podman: two VMs on 8 GB is untested
colima start --cpu 4 --memory 6 --disk 80 --vm-type vz --vz-rosetta --runtime docker
gmake deps CONTAINER_ENGINE=docker   # kind, helm, kubectl, crane, the docker CLI + buildx
```

Start Colima **before** `deps`: if no docker daemon answers, `deps` runs `colima start` itself, with
no flags, so the VM would come up without Rosetta and without the memory above. `--vz-rosetta` matters: Harbor publishes amd64 images only, and they
run on the arm64 node under Rosetta.

For `e2e-kind-cross-cluster`, which creates more than one kind cluster, raise the VM's inotify limit
first. At Colima's default of 128 the second extra cluster's control plane never started; at 512 it
did. That is one of the two values kind's
[known-issues page](https://kind.sigs.k8s.io/docs/user/known-issues/) recommends (the other is
`fs.inotify.max_user_watches=524288`). `sysctl -w` sets it only until the VM restarts (not measured
here), so run it again after a `colima start`:

```bash
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512
```

**Reach the LoadBalancer IPs.** kind's LoadBalancer addresses (`172.18.x.x`) live inside the VM and are
not routable from macOS. `docker-mac-net-connect` routes them over WireGuard, and it must run as root.
On the test Mac its `brew services` daemon did not find Colima, so start it with Colima's socket named
explicitly (`sudo -b` asks for your password first, then runs it in the background):

```bash
sudo -b DOCKER_HOST="unix://$HOME/.colima/default/docker.sock" \
  "$(brew --prefix)/opt/docker-mac-net-connect/bin/docker-mac-net-connect" > "$HOME/Library/Logs/docker-mac-net-connect.log" 2>&1
```

Then run it with `gmake` (Apple's `make` 3.81 is refused), building for the node's architecture:

```bash
export MIRROR_ARCH=arm64 CONTAINER_ENGINE=docker   # this shell only — never in .env
gmake e2e-kind
```

Set `MIRROR_ARCH=arm64` for **every** command in the session, including a re-run of one step: it
decides what `mirror` pulls, what `mirror-verify` checks and what the build guard accepts. **Never put
it in `.env`**: a later lab run would then mirror and build arm64 images, the guard would accept them,
and they would replace the lab's amd64 images in Harbor.

When you are done, stop the root daemon as well as the cluster (`make kind-down` does not stop it):

```bash
gmake kind-down
sudo pkill -f "$(brew --prefix)/opt/docker-mac-net-connect/bin/docker-mac-net-connect"
```

## Run it

```bash
make deps        # kind, helm, kubectl, crane, …
make e2e-kind    # cluster → Harbor → ArgoCD → mirror → build → deploy → ingress → verify
make creds-show  # every URL + login for what you just installed
```

**Expect:** it exits **0**. Among the lines you'll see (the count is dynamic; the real lines are prefixed
`level=INFO msg=…`, so this is the gist, not byte-for-byte):

```text
✓ mirror-verify: N images intact in Harbor          (mid-run, during install-all)
SUCCESS — all UIs reachable through the istio ingress at <LB-IP> (*.vks.local)
PSA OK — our namespaces are labelled at a level the cluster admits              (the final line)
```

Then: **[open the UIs](access-uis.md)** · **[walk a code change from Gitea to the live page](demo-walkthrough.md)**

```bash
make kind-down   # tear it all down (also prunes cloud-provider-kind orphans)
```

**You do not need a `.env`.** The KinD steps **discover** what they can (`KUBECONFIG`, Harbor's LB IP and
CA, ArgoCD's LB IP) and **generate** the passwords for the components they install, writing both into a
gitignored `.env.state`. `make creds-show` prints the result.

## Re-run one step

`e2e-kind` is those steps in order. When a run dies partway, re-run the piece — you don't need the
whole thing. (`make help` lists them all.)

| step | what it does here |
|---|---|
| `make env-init` | **optional** — KinD needs no `.env` (it discovers its own state and generates its own secrets). Run it only to pin your own demo passwords. |
| `make kind-up` | the cluster + `cloud-provider-kind`, which is what gives Harbor a real LoadBalancer IP |
| `make install-harbor` | the registry everything pulls from — self-signed HTTPS on that LB IP, mimicking the lab |
| `make install-argocd` | the GitOps engine, on **its own** LB (the real VKS doesn't put it behind the ingress either) |
| `make install-ingress` | the UIs at `*.vks.local`. **KinD has no service mesh, so this is the one path that *installs* one** — `INGRESS_CONTROLLER=istio` (default, `make install-istio`) or the lighter `traefik`. A real VKS guest cluster already ships Istio, so **both VKS scenarios attach to the existing mesh** (`INGRESS_CONTROLLER=istio-existing`) and never install it. |
| `make verify` | the actual proof: a git push → Tekton → Harbor → ArgoCD → the live page serves the new marker |

## Knobs

| | |
|---|---|
| `make e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1` | plain HTTP instead of self-signed TLS — faster to iterate against. Both modes are validated. |
| `make e2e-kind E2E_SKIP_DOTENV=0` | use **your** `.env`. By default the e2e **ignores it** (`SKIP_DOTENV=1`) so it reproduces a fresh operator and a CI runner — neither has a `.env`, so the secrets must be *generated*. Without that a local run silently reads values only your box has: a CI job once died on an empty `HARBOR_PASSWORD` while every local run was green. |
| `make e2e-sneakernet` | proves the **[sneakernet](sneakernet.md)** flow locally (pull → bundle → carry into a fresh Photon *and* Ubuntu air-gap container → push → verify). Sneakernet is a delivery mode for the **real lab**, not a KinD topic. |

## What the stand-in fakes, and what it doesn't

- **`cloud-provider-kind`** gives Harbor a real `LoadBalancer` IP on the kind docker network — reachable
  at the **same IP** from the host (push), from Kaniko pods (push), and from containerd (pull). That is
  what makes one image ref work everywhere, exactly as in the lab.
- **Harbor serves self-signed HTTPS on that IP by default**, mimicking VCF/VKS. The CA is trusted at every
  consumer **without sudo**. Mechanism: [KinD TLS fidelity](decisions/kind-tls-fidelity.md).
- **Harbor and ArgoCD each keep their own LB**, not the shared ingress — Harbor's IP is load-bearing for
  the containerd pull path, and the real VKS does not front ArgoCD behind the ingress either.
- **`make vks-login` is effectively a no-op here** (`VKS_AUTH_METHOD=kubeconfig`) — it only checks that
  `$KUBECONFIG` points at the KinD kubeconfig `kind-up` wrote; there is no VCF to authenticate to.

---

[← back to the README](../README.md)
