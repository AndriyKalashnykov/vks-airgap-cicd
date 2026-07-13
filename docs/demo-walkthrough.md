# Demo walkthrough — drive the GitOps loop by hand

<br>

This is the demo. Once the stack is up — **[KinD](kind-local.md)**, **[Scenario 1](scenario-1.md)** or
**[Scenario 2](scenario-2.md)**; the *loop* is identical on all three — you can watch a **one-line code
change flow from the Gitea web editor all the way to the running web page, entirely inside the air
gap**, with each hop visible in its own Web UI. `make verify` does exactly this automatically; the
steps below are the same loop by hand, so you can watch it happen.

## Before you start — get your URLs, usernames AND passwords

**One command prints all three, with the real values for *your* environment:**

```bash
make creds-show
```

It outputs a `Service · URL · Username · Password` table — the passwords are **printed, not named**.
(You never have to know where they came from: on the KinD path the flow *generates* them; on a real
lab they are the ones you set in `.env`. `make creds-show` reads them back either way.) It also gives
you the one-time `/etc/hosts` line the `*.vks.local` hosts need — there is no internet DNS in an air
gap.

| UI | Username | Password | What you'll watch |
|----|----------|----------|-------------------|
| **The app** | — | — (no login) | the greeting that changes |
| **Gitea** | `gitea_admin` | printed by `make creds-show` | edit the source; see the tag write-back |
| **Tekton Dashboard** | — | — (read-only, no login) | the PipelineRun: test → build → deploy |
| **Harbor** | `admin` | printed by `make creds-show` | the freshly-built image |
| **ArgoCD** | `admin` | printed by `make creds-show` (or `make argocd-password` on its own) | the sync that rolls the new image |

**Do not copy URLs from this page** — they are *not* the same on all three paths:

| UI | Where its URL comes from |
|----|--------------------------|
| **app / Gitea / Tekton** | the **ingress**, at `<app>.${APP_DOMAIN}` / `${GITEA_HOST}` / `${TEKTON_DASHBOARD_HOST}` — **derived**, so they change with `APP_DOMAIN` (default `vks.local`) |
| **Harbor** | **its OWN LoadBalancer — never the ingress** (its LB IP is load-bearing for the containerd pull path). An LB IP on KinD; your lab's own URL on a real lab |
| **ArgoCD** | **its OWN LoadBalancer — never the ingress** (mirroring the real lab, where ArgoCD is a **Supervisor Service** in a *different* cluster). An LB IP on KinD; your lab's own URL on a real lab |

See [Access the UIs](access-uis.md). The steps below use `javawebapp` at the **default** domain as the
worked example; substitute your own from `make creds-show`.

1. **See the current greeting.** Open your app URL (the default-domain example is
   <http://javawebapp.vks.local/>). The page shows a greeting —
   `Hello from vks-airgap-cicd` by default — rendered in the `<p class="message">` element,
   alongside the app version and git commit. This is what will visibly change.

2. **Edit the greeting in Gitea.** Go to **`demo/javawebapp-app`** →
   `src/main/resources/application.yml`, click the **edit (pencil)** icon, and change the
   greeting default on line 18:

   ```yaml
   # from:
     message: ${APP_MESSAGE:Hello from vks-airgap-cicd}
   # to (any text):
     message: ${APP_MESSAGE:Hello from the air-gapped pipeline}
   ```

   **Commit directly to `main`.** The commit fires the Gitea push webhook
   (`el-apps.ci.svc:8080`) → the Tekton EventListener → a new PipelineRun. (This is the same
   `application.yml` line `make verify` rewrites with a unique marker.)

3. **Watch Tekton build it.** In the **Tekton Dashboard** (default-domain example:
   <http://tekton.vks.local>), a new
   **`javawebapp-ci-*`** PipelineRun appears in the `ci` namespace. Its TaskRuns run in order — open
   each to tail logs live:

   | TaskRun | Does |
   |---------|------|
   | `clone-app` | clones `javawebapp-app`; its short commit SHA becomes the image tag |
   | `test` | runs `./mvnw -B -o test` **offline** (against the deps-baked builder image) |
   | `build` | **Kaniko** builds the image and pushes it to Harbor |
   | `deploy-update` | writes the new tag back into `javawebapp-deploy` (the GitOps hand-off) |

4. **See the new image in Harbor.** In Harbor, open project **`apps`** → repository
   **`javawebapp`**. A new tag appears — the **git short SHA** of your commit
   (`$HARBOR_URL/apps/javawebapp:<sha>` — on KinD that is Harbor's **LB IP**, which `make creds` prints;
   on a real lab it is your Harbor FQDN) — pushed by the Kaniko `build` task.

5. **See the tag written back in Gitea.** Open **`demo/javawebapp-deploy`** → `kustomization.yaml`.
   There's a new commit by **`ci-bot`** with message **`ci: deploy javawebapp <sha>`** that bumps
   `images[0].newTag` to your `<sha>`. This deploy repo — not the app repo — is what ArgoCD
   watches, which is why the tag write-back (not the source push) is what triggers a deploy.

6. **Watch ArgoCD deploy it.** In **ArgoCD** (its own self-signed-TLS LB IP on KinD —
   `https://<ARGOCD_LB_IP>`, shown by `make creds`; on a real VKS lab, **your lab's own
   ArgoCD URL**), the Application
   **`javawebapp`** flips **`OutOfSync → Synced`** (auto-sync + self-heal) and rolls the Deployment
   in namespace `javawebapp` to `$HARBOR_URL/apps/javawebapp:<sha>`. (Auto-sync polls the deploy repo
   on an interval; click **Refresh** to reconcile immediately.)

7. **See the page change.** Refresh your app URL. The greeting now shows your new
   text. That change went **source → test → image → registry → GitOps write-back → cluster →
   running page** without a single byte crossing the air gap.

> **`make verify` is the automated form of this whole loop** — it edits the same
> `application.yml` line with a unique marker, waits for the PipelineRun to succeed, forces an
> ArgoCD refresh, waits for the *deployed image* to change, then **port-forwards `svc/javawebapp`**
> and polls it until the page contains the marker — so it needs no ingress and no `/etc/hosts`
> entry. (`make verify-ingress` is the separate check that proves the `*.vks.local` routes.)
> Run it to prove the pipeline; walk the UIs above to *see* it.

---

[← back to the README](../README.md)
