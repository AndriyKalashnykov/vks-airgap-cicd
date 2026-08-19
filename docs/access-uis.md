# Access the UIs (URLs, logins, passwords)

<br>

Run **`make creds-show`** — it self-resolves the kubeconfig and prints the URLs, logins, and (when an
ingress is installed) the one-time `/etc/hosts` line for the `*.vks.local` hosts. **Which URLs are
correct depends on the context** — Harbor and ArgoCD are *ours* in KinD but the *lab's* on a real
VKS cluster:

> **Passwords print only to a terminal.** If you **pipe or redirect** `creds-show` — into a file, a
> pager, `grep`, a CI capture — the password column reads
> `<hidden: not a terminal — re-run with SHOW_SECRETS=1>`. That is deliberate: the walkthrough
> harness runs every documented command with stdout redirected to a log, and live Gitea, Harbor and
> ArgoCD passwords were reaching those logs in cleartext. Everything else — URLs, usernames, the
> DISCOVERED/STORED provenance — is unchanged, so a redirect still gives you the whole table.
>
> To capture the passwords too, ask for it explicitly:
>
> ```bash
> SHOW_SECRETS=1 make creds-show > creds.txt
> ```
>
> ⚠️ Putting `SHOW_SECRETS=1` in your `.env` does **not** work, on purpose — it is read from the
> environment *before* `.env` is loaded, so one forgotten line cannot silently re-arm the leak for
> every future capture.
>
> ⚠️ **A pty-based capture counts as a terminal and WILL show the passwords.** The test is "is stdout
> a tty", not "is a human reading this" — so `script`, `ssh -t`, `unbuffer` and some CI runners get
> the cleartext into their transcript. Only a **pipe or a redirect** masks. If you are recording a
> session that will be shared, capture it with a redirect, not with `script`.

- The **`*.vks.local`** hostnames exist **only after the ingress is in place** — `make install-ingress`
  (KinD / a mesh-free cluster), or `make install-ingress INGRESS_CONTROLLER=istio-existing` on a real
  VKS lab, where Istio already exists and we only attach routes (part of
  `make e2e-kind`; a separate, optional step in the lab flow) and front only the UIs this project
  controls — **Gitea, the app, and the Tekton Dashboard**.
- **Harbor and ArgoCD are never behind the ingress** — each has its own LB address in both
  contexts. In KinD, Harbor is **self-signed HTTPS on its LB IP** and ArgoCD is **self-signed
  TLS on its own LB IP** (published as `ARGOCD_LB_IP`); VKS serves the same posture at
  the lab's own URLs. The KinD-vs-lab gap shrinks to "we mint the cert locally".

For the concrete URLs, usernames and passwords in *your* context, run **`make creds-show`** — it is the
single source of truth (it resolves KinD-vs-lab and the tenant-vs-admin login for you), so this page keeps
only the model, not a static table that would drift out of date.

**ArgoCD password** — **`make argocd-password`** prints it **on a terminal**, and masks it otherwise
(see the note below — the qualification is not optional, and it used to sit under this line where a
reader skimming for the command would never reach it). It asks the **cluster** first, so what it
prints is the password that actually works.

> It masks off a terminal, exactly like `creds-show` above — pipe or redirect it and you get
> `<hidden: not a terminal — re-run with SHOW_SECRETS=1>`. Same reason: this command appears as a
> walked step, so its output was landing in per-row logs in cleartext. On your own terminal nothing
> changes. `SHOW_SECRETS=1 make argocd-password > f` captures it deliberately, and the same pty
> caveat applies.

- **KinD:** the flow generates one for you (`.env.state`) and applies it at install — nothing to set.
- **VKS:** ArgoCD is the platform's. If you set `ARGOCD_ADMIN_PASSWORD` in `.env`, that is what you
  get; otherwise the command reads the initial-admin secret, or points you at your lab.

> Setting `ARGOCD_ADMIN_PASSWORD` in `.env` does **not** affect `make e2e-kind` — that path runs with
> `SKIP_DOTENV=1` (it stands in for a fresh operator, who has no `.env`). To pin your own on KinD:
> `make e2e-kind E2E_SKIP_DOTENV=0`. `make argocd-password` will tell you if a value you set was
> never applied, rather than printing a password that does not log in.

---

> Without the ingress (or before adding the `/etc/hosts` line), the same services are still
> reachable over `kubectl port-forward` — e.g. `kubectl -n gitea port-forward svc/gitea-http
> 3000:3000` → <http://localhost:3000>. Harbor and ArgoCD are always direct LoadBalancers, not behind the ingress.

The **Tekton Dashboard** (above) is Tekton's web UI. The Tekton **EventListener** is a
separate, in-cluster-only webhook receiver (`el-apps.ci.svc:8080`) — the Gitea webhook fires
cluster-internally, so there is nothing to expose or log into there.

---

[← back to the README](../README.md)
