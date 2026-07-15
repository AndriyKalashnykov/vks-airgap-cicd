# Demo walkthrough — watch a code change reach the running page

<br>

A one-line edit in Gitea travels **source → test → image → registry → GitOps write-back → cluster →
running page**, entirely inside the air gap. Each hop has a Web UI. This is that loop, by hand.

Works the same on all three paths (KinD, Scenario 1, Scenario 2) once the stack is up.
`make verify` does it automatically; walk it yourself to *see* it.

## Step 0 — get your URLs and passwords

```bash
make creds-show
```

It prints, for **your** environment: every **URL**, its **username**, its **password**, and the
one-time `/etc/hosts` line the `*.vks.local` hostnames need (there is no DNS in an air gap).

Use those URLs below. The examples say `javawebapp.vks.local` — that is just the default; yours are
whatever `make creds-show` printed.

## The loop

1. **See the current greeting.** Open the **app** URL. It shows a greeting with the app version and git
   commit — this is what will change. (If you arrived straight from `make e2e-kind`, its own `make verify`
   step already deployed a marker like `vks-airgap-cicd-verify-<epoch>`, so you'll see **that**, not the
   `Hello from vks-airgap-cicd` default. Either is fine — you're about to change it.)

2. **Sign in to Gitea first** (username `gitea_admin` + the password `make creds-show` printed — editing
   requires auth), then **edit it in Gitea.** Open **`demo/javawebapp-app`** →
   `src/main/resources/application.yml`, click the **pencil**, and change the greeting on line 18 (edit
   whatever text is currently after `${APP_MESSAGE:` — it may already be a verify marker):

   ```yaml
   # e.g. from:
     message: ${APP_MESSAGE:Hello from vks-airgap-cicd}
   # to (any text):
     message: ${APP_MESSAGE:Hello from the air-gapped pipeline}
   ```

   **Commit directly to `main`.** That fires the Gitea webhook → Tekton → a new PipelineRun.

3. **Watch Tekton build it.** In the **Tekton Dashboard**, a `javawebapp-ci-*` PipelineRun appears in
   the `ci` namespace. Open each TaskRun to tail its log:

   | TaskRun | Does |
   |---------|------|
   | `clone-app` | clones `javawebapp-app`; its short commit SHA becomes the image tag |
   | `test` | runs `./mvnw -B -o test` **offline** (against the deps-baked builder image) |
   | `build` | **Kaniko** builds the image and pushes it to Harbor |
   | `deploy-update` | writes the new tag back into `javawebapp-deploy` — the GitOps hand-off |

4. **See the image in Harbor.** Project **`apps`** → repository **`javawebapp`**. A new tag appears:
   the **git short SHA** of your commit.

5. **See the tag written back in Gitea.** **`demo/javawebapp-deploy`** → `kustomization.yaml` has a
   new commit by **`ci-bot`** (`ci: deploy javawebapp <sha>`) bumping `images[0].newTag`. ArgoCD
   watches **this** repo — which is why the *write-back*, not your source push, is what deploys.

6. **Watch ArgoCD deploy it.** The **`javawebapp`** Application flips **`OutOfSync` → `Synced`** and
   rolls the Deployment to the new image. (Auto-sync polls on an interval — click **Refresh** to
   reconcile now.)

7. **See the page change.** Refresh the app URL. Your new greeting is live — and nothing crossed the
   air gap.

> **`make verify` is this loop, automated**: it edits the same line with a unique marker, waits for
> the PipelineRun, forces an ArgoCD refresh, waits for the *deployed image* to change, then
> port-forwards the app and polls until the page contains the marker. It needs no ingress and no
> `/etc/hosts` entry.

---

[← back to the README](../README.md)
