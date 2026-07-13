# Access the UIs (URLs, logins, passwords)

<br>

Run **`make creds`** — it self-resolves the kubeconfig and prints the URLs, logins, and (when an
ingress is installed) the one-time `/etc/hosts` line for the `*.vks.local` hosts. **Which URLs are
correct depends on the context** — Harbor and ArgoCD are *ours* in KinD but the *lab's* on a real
VKS cluster:

- The **`*.vks.local`** hostnames exist **only after the ingress is in place** — `make install-ingress`
  (KinD / a mesh-free cluster), or `make install-ingress INGRESS_CONTROLLER=istio-existing` on a real
  VKS lab, where Istio already exists and we only attach routes (part of
  `make e2e-kind`; a separate, optional step in the lab flow) and front only the UIs this project
  controls — **Gitea, the app, and the Tekton Dashboard**.
- **Harbor and ArgoCD are never behind the ingress** — each has its own LB address in both
  contexts. In KinD, Harbor is **self-signed HTTPS on its LB IP** and ArgoCD is **self-signed
  TLS on its own LB IP** (published as `ARGOCD_LB_IP`); the real lab serves the same posture at
  the lab's own URLs. The KinD-vs-lab gap shrinks to "we mint the cert locally".

| Service | Local KinD | Real VKS lab | Login |
|---------|------------|--------------|-------|
| **Gitea** (we install) | <http://gitea.vks.local> | `http://gitea.vks.local` once the ingress is in place (install, or attach with `INGRESS_CONTROLLER=istio-existing`), else `kubectl -n gitea port-forward svc/gitea-http 3000:3000` | `gitea_admin` / `GITEA_ADMIN_PASSWORD` |
| **Tekton Dashboard** (we install) | <http://tekton.vks.local> | same — ingress or `port-forward` | — (read-only) |
| **App (javawebapp)** (we deploy) | <http://javawebapp.vks.local/> | same — ingress or `port-forward svc/javawebapp` | — (health at `/actuator/health`) |
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
separate, in-cluster-only webhook receiver (`el-apps.ci.svc:8080`) — the Gitea webhook fires
cluster-internally, so there is nothing to expose or log into there.

---

[← back to the README](../README.md)
