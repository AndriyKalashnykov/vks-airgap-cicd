# Try it locally end-to-end with KinD

<br>

> **You want to *see it work*.** No VKS cluster, no `.env`, three commands.

`make e2e-kind` stands up a local [KinD](https://kind.sigs.k8s.io/) cluster, installs the pieces a real
VKS provides as Supervisor Services (**Harbor** + **ArgoCD**), and runs the **same**
`mirror → builder → platform → gitops → verify` flow the real lab uses — ending with a git push that
travels through Tekton, Harbor and ArgoCD to a live page.

## Run it

```bash
make deps        # kind, helm, kubectl, crane, …
make e2e-kind    # cluster → Harbor → ArgoCD → mirror → build → deploy → ingress → verify
make creds-show  # every URL + login for what you just installed
```

**Expect:** it exits **0**, and the last lines read

```text
✓ mirror-verify: 36 images intact in Harbor
SUCCESS — all UIs reachable through the istio ingress at <LB-IP> (*.vks.local)
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
- **`make vks-login` is a no-op here** (`VKS_AUTH_METHOD=kubeconfig`) — there is no VCF to authenticate to.

---

[← back to the README](../README.md)
