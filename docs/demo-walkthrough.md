# Demo walkthrough — watch a code change reach the running page

<br>

A one-line edit in Gitea travels **source → test → image → registry → GitOps write-back → cluster →
running page**, entirely inside the air gap. Each hop has a Web UI. This is that loop, by hand.

Works the same on all three paths (Scenario 1, Scenario 2, KinD) once the stack is up.
`make verify` does it automatically; walk it yourself to *see* it.

## Step 0 — get your URLs and passwords

```bash
make creds-show
```

It prints, for **your** environment: every **URL**, its **username**, its **password**, and the
one-time `/etc/hosts` line the `*.vks.local` hostnames need (there is no DNS in an air gap).

Use those URLs below. The examples walk **`javawebapp`**, but the repo ships **six** apps and
`make creds-show` lists them as equals — pick any one. Two things change per app: the **hostname**,
which is always `<app>.<APP_DOMAIN>` (`APP_DOMAIN` defaults to `vks.local`, and `make creds-show`
prints the real URL for *your* environment), and the **file you edit**, which the table in Step 2
gives.

## The loop

1. **See the current greeting.** Open the **app** URL. It shows a greeting with the app version and git
   commit — this is what will change. (If you arrived straight from `make e2e-kind`, its own `make verify`
   step already deployed a marker like `vks-airgap-cicd-verify-<epoch>`, so you'll see **that**, not the
   `Hello from vks-airgap-cicd` default. Either is fine — you're about to change it.)

2. **Sign in to Gitea first** (the username **and** password `make creds-show` prints — editing
   requires auth), then **edit the greeting in Gitea.** Open **`demo/<app>-app`**, navigate to the
   file for your app, click the **pencil**, and change the text. Each app keeps its greeting in its
   own language's idiom, so the file differs — this is the whole table:

   | app | file to edit | the line |
   |-----|--------------|----------|
   | `javawebapp` | `src/main/resources/application.yml` | `message: ${APP_MESSAGE:Hello from vks-airgap-cicd}` |
   | `gowebapp` | `main.go` | `const defaultMessage = "Hello from vks-airgap-cicd"` |
   | `nodejswebapp` | `server.js` | `const defaultMessage = 'Hello from vks-airgap-cicd';` |
   | `pythonwebapp` | `app.py` | `DEFAULT_MESSAGE = "Hello from vks-airgap-cicd"` |
   | `rustwebapp` | `src/main.rs` | `const DEFAULT_MESSAGE: &str = "Hello from vks-airgap-cicd";` |
   | `dotnetwebapp` | `Program.cs` | `public const string DefaultMessage = "Hello from vks-airgap-cicd";` |

   Change only the **text inside the quotes** to anything you like, e.g. `Hello from the air-gapped
   pipeline`. If you have already run `make verify` (or `make e2e-kind`, which calls it), that text
   is a `vks-airgap-cicd-verify-<epoch>` marker rather than the default — edit it anyway.

   **Commit directly to `main`.** That fires the Gitea webhook → Tekton → a new PipelineRun.

3. **Watch Tekton build it.** In the **Tekton Dashboard**, a `<app>-ci-*` PipelineRun appears in
   the `ci` namespace. Open each TaskRun to tail its log:

   | TaskRun | Does |
   |---------|------|
   | `clone-app` | clones `<app>-app`; its short commit SHA becomes the image tag |
   | `test` | runs the app's own test command **offline**, against its deps-baked builder image (java: `./mvnw -B -o test`; go: `go test`; and so on per language) |
   | `build` | **Kaniko** builds the image and pushes it to Harbor |
   | `deploy-update` | writes the new tag back into `<app>-deploy` — the GitOps hand-off |

4. **See the image in Harbor.** Project **`apps`** → repository **`<app>`**. A new tag appears:
   the **git short SHA** of your commit.

5. **See the tag written back in Gitea.** **`demo/<app>-deploy`** → `kustomization.yaml` has a
   new commit by **`ci-bot`** (`ci: deploy <app> <sha>`) bumping `images[0].newTag`. ArgoCD
   watches **this** repo — which is why the *write-back*, not your source push, is what deploys.

6. **Watch ArgoCD deploy it.** The **`<app>`** Application flips **`OutOfSync` → `Synced`** and
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
