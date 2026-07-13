# Try it locally end-to-end with KinD

<br>

> **You want to *see it work*.** No VKS cluster, **zero `.env`**, two commands.

You don't need a VKS cluster to exercise the whole pipeline. `make e2e-kind` stands up a
local [KinD](https://kind.sigs.k8s.io/) cluster, installs the Supervisor-Service pieces
(**Harbor** + **ArgoCD**) into it, then runs the exact same
`mirror → builder → platform → gitops → verify` flow the real environment uses. This path
is verified end-to-end (git push → Tekton build → Harbor → ArgoCD → the live app serves
the new version).

> **Zero `.env` setup — and the e2e ENFORCES it.** The kind steps **auto-discover and write
> `.env.state`** for you — `KUBECONFIG`, `HARBOR_URL` (the Harbor LB IP), `HARBOR_CA_FILE`, the
> ArgoCD LB IP — and **generate** the passwords for the components we install. Run
> `make creds-show` for the effective URLs, logins and passwords.
>
> `make e2e-kind` deliberately **ignores your `.env`** (`SKIP_DOTENV=1`, set by
> `E2E_SKIP_DOTENV ?= 1`). It is a stand-in for a brand-new operator and for a CI runner —
> neither of which has a `.env` — so the secrets **must be generated**, exactly as they will be
> on your machine. Without this, a local run silently reads values only *your* box has and the
> fresh-box path is never exercised: that is how a CI smoke job once died on an empty
> `HARBOR_PASSWORD` while every local run was green. Use your own `.env` with
> `make e2e-kind E2E_SKIP_DOTENV=0`.
>
> The VKS discovery (Scenario 1/2) is the manual parallel of the same thing.

```bash
make env-init                 # OPTIONAL for KinD (it discovers its own state); pins known demo secrets if you want them
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
  see [KinD TLS fidelity](decisions/kind-tls-fidelity.md)); `install-harbor` mints a
  self-signed CA + leaf (SAN = the LB IP) and wires each node's containerd
  (`/etc/containerd/certs.d/<ip>/`) with that **CA** so pulls verify over TLS. The CA is
  trusted at every consumer **sudo-free** — jump-box `crane`/`curl` via `SSL_CERT_FILE`, the
  builder push via podman `--cert-dir`, in-cluster Kaniko via the `harbor-ca` ConfigMap. It
  writes the discovered `HARBOR_URL` (the LB IP) + `HARBOR_CA_FILE` + `KUBECONFIG` into a
  gitignored **`.env.state`** overlay so the normal scripts target the kind cluster unchanged.
  Harbor **and** ArgoCD both default to secure (self-signed TLS, mimicking the VCF/VKS 9.1
  lab). For the original plain-HTTP fast-iteration mode, flip both switches:
  `make e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1`. Both modes are validated locally.
- `make vks-login` uses the kind kubeconfig (`VKS_AUTH_METHOD=kubeconfig`), so no VCF auth
  is needed for the local run.
- **Ingress — the KinD stand-in has NO mesh, so we install one.** `make install-ingress` installs
  **Istio** (`INGRESS_CONTROLLER=istio`, the default — control plane + gateway, images from Harbor;
  `traefik` is the lighter option) as one LoadBalancer
  that fronts the Gitea/app/Tekton-Dashboard UIs at `*.vks.local`, so
  you reach them by hostname instead of `kubectl port-forward`. **Harbor and ArgoCD each keep
  their own direct LB** — Harbor's IP is load-bearing for the containerd pull path, and ArgoCD
  gets its own self-signed-TLS LB (like the VKS, which does not front ArgoCD behind
  the shared ingress). Both ingress images are mirrored into Harbor.

> **This is the only path where we install Istio.** A VKS already has it (Istio ships as a
> **VKS Standard Package** in the guest cluster), so both VKS scenarios **attach** to the
> existing mesh instead — see their ingress step. Full reference:
> [`docs/vks-services/istio.md`](vks-services/istio.md).

Individual targets: `make kind-up`, `make install-harbor`, `make install-argocd`,
`make install-ingress` (or `make install-istio` / `make install-traefik`).

---

[← back to the README](../README.md)
