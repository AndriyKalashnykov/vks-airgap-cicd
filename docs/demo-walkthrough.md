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

1. **See the current greeting.** Open the **app** URL. It shows a greeting, the **deployed tag** —
   the app's own declared version, which is what the image is deployed BY — and the **git commit**
   it was built from. The greeting is what will change. (If you arrived straight from `make e2e-kind`, its own `make verify`
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

   (Building every app at once, without editing anything — e.g. right after an install, when Harbor
   is empty and the pods are in `ImagePullBackOff` — is `make build-apps`. It pushes an empty commit
   per app so the real pipeline runs, and skips any app whose image Harbor already holds.)

   ℹ️ **A greeting change alone DOES deploy.** The deployed image tag is the app's declared version,
   and ArgoCD only rolls when `<app>-deploy` changes in git — but the write-back also stamps the
   build's **commit sha** into `deployment.yaml`, and that changes on every build. So the deploy
   repo changes, ArgoCD rolls, and your greeting appears. (`imagePullPolicy: Always` is what makes
   the pod actually re-pull the re-pointed tag.)

   Bump the **version** when you want the release identity to change — that is what the `Deployed
   tag` on the page shows.

   ⚠️ MEASURED, and I had this backwards at first: with the commit stamped into the manifest, the
   version bump is NOT required for a redeploy. It would be if the tag were the only thing written.

   **The version to bump — the file per app.** Edit the
   app's **declared semantic version** in its own manifest. It is compiled into the image at build
   time, so it can never disagree with the artifact it describes, and the build tags the image with
   it (see step 4).

   | app | file to edit | the line |
   |-----|--------------|----------|
   | `javawebapp` | `pom.xml` | `<version>0.1.0</version>` (the one under the project's own `<artifactId>`) |
   | `gowebapp` | `main.go` | `const appVersion = "0.1.0"` |
   | `nodejswebapp` | `package.json` | `"version": "0.1.0"` |
   | `pythonwebapp` | `app.py` | `__version__ = "0.1.0"` |
   | `rustwebapp` | `Cargo.toml` | `version = "0.1.0"` under `[package]` |
   | `dotnetwebapp` | `dotnetwebapp.csproj` | `<Version>0.1.0</Version>` |

   Each app declares its own, in its own file, so bumping one changes **only that app** — java to
   `0.2.0` leaves the other five on `0.1.0`, and only java's next image gains a `0.2.0` tag.

   ℹ️ The page shows `Deployed tag` and `Commit`, and nothing else — `Deployed tag` IS this app's
   declared version, because the image is deployed by it. There is deliberately no separate
   `Version` row: it would carry the identical value, and one fact under two labels is the defect
   this page was corrected for once already. The image still carries the sha as a second Harbor tag,
   so every artifact remains traceable to the commit that built it, which `Commit` shows.

   Because the deployed tag now MOVES (a rebuild without a bump re-points it), the deployments use
   `imagePullPolicy: Always` — under `IfNotPresent` a node holding a cached layer would keep serving
   the old build and the page would silently lie.

   Change only the **text inside the quotes** to anything you like, e.g. `Hello from the air-gapped
   pipeline`. If you have already run `make verify` (or `make e2e-kind`, which calls it), that text
   is a `vks-airgap-cicd-verify-<epoch>` marker rather than the default — edit it anyway.

   **Commit directly to `main`.** That fires the Gitea webhook → Tekton → a new PipelineRun.

3. **Watch Tekton build it.** In the **Tekton Dashboard**, a `<app>-ci-*` PipelineRun appears in
   the `ci` namespace. Open each TaskRun to tail its log:

   | TaskRun | Does |
   |---------|------|
   | `clone-app` | clones `<app>-app`, and reads two things out of that clone: its short commit SHA, and the app's **declared version** (the deployed tag) |
   | `test` | runs the app's own test command **offline**, against its deps-baked builder image (java: `./mvnw -B -o test`; go: `go test`; and so on per language) |
   | `build` | **Kaniko** builds the image and pushes it to Harbor, then — as three further steps, `clone-deploy` -> `set-tag` -> `commit-push` — writes the new tag back into `<app>-deploy`. **That write-back is the GitOps hand-off**; it was its own TaskRun until it was merged here to save a pod per app per run. The Tekton dashboard still shows the three steps separately. |

4. **See the image in Harbor.** Project **`apps`** → repository **`<app>`**. The new artifact
   carries **two tags on one digest** (Harbor's Tags column shows both, e.g. `0.1.0, bfe621e`): the
   **git short SHA** of your commit, and the app's
   **declared semantic version** (`0.1.0` — read out of the clone's own `pom.xml` / `package.json` /
   `Cargo.toml` / `main.go` / `app.py` / `.csproj`, so each app bumps independently). **The version
   is what ArgoCD deploys** — it is what the write-back puts in `newTag`; the sha rides along as a
   second tag so the artifact stays traceable to the commit that built it.

5. **See the tag written back in Gitea.** **`demo/<app>-deploy`** → `kustomization.yaml` has a
   new commit by **`ci-bot`** (`ci: deploy <app> <version> (<sha>)`) setting `images[0].newTag`
   to your version and `APP_COMMIT` in `deployment.yaml` to the sha. ArgoCD
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
