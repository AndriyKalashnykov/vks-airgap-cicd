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

1. **See the current greeting.** Open the **app** URL. It shows a greeting, the deployed **image
   tag**, and the **git commit** it was built from — the pipeline tags every image with the commit
   sha, so those two match by construction, and the greeting is what will change. (If you arrived straight from `make e2e-kind`, its own `make verify`
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

   **Want to change the `Version` field instead (or as well)?** Same loop, different file — edit the
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

   ⚠️ `Version` and `Deployed tag` are different facts and are meant to differ. `Version` is what
   YOU declare. `Deployed tag` is the tag the running pod was **pulled with** — the git sha — and it
   is deliberately NOT `0.1.0`, even though the image carries BOTH tags on one digest: ArgoCD
   deploys by sha because a sha is unique per build, while a moving `0.1.0` under
   `imagePullPolicy: IfNotPresent` could serve a node's cached older layer. A bump changes the first
   immediately and the second to a new sha.

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

4. **See the image in Harbor.** Project **`apps`** → repository **`<app>`**. The new artifact
   carries **two tags on one digest** (Harbor's Tags column shows both, e.g. `0.1.0, bfe621e`): the
   **git short SHA** of your commit, and the app's
   **declared semantic version** (`0.1.0` — from its own `pom.xml` / `package.json` / `Cargo.toml` /
   `main.go` / `app.py` / `.csproj`, so each app can bump independently). The sha is what ArgoCD
   deploys; the version is there so the artifact list says what the app *is*, not only which build
   it was.

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
