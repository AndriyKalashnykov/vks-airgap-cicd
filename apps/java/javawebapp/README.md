# javawebapp

The **java** app in this repo's six-language demo. All six serve an **identical page** — that is
the point: the pipeline, the ingress and `make verify` treat them the same, so what the demo proves
is the air-gapped CI/CD loop, not any one language. `make check-ui-contract` renders all six and
fails if they differ.

The page shows three things:

| field | where it comes from |
|---|---|
| the greeting | `APP_MESSAGE`, or the default compiled into the source |
| **Deployed tag** | the image tag the pod was pulled with — **this app's declared version**, from its own manifest |
| Commit | the git sha the image was built from (also a second Harbor tag) |

`GET /healthz` is the liveness/readiness probe and the container `HEALTHCHECK`.

## Build it manually

From this directory, with the native toolchain:

```sh
./mvnw -B test      # tests
./mvnw -B package     # build -> target/*.jar
java -jar target/javawebapp-<version>.jar       # run it, then open http://localhost:8080
```

Or through the repo, which uses the same **pinned, mirrored** toolchain the cluster uses — the
honest check, because it is what the air-gapped build actually runs:

```sh
make app-test  APP=javawebapp
make app-build APP=javawebapp
make app-run   APP=javawebapp
```

⚠️ Building locally proves the code compiles. It proves **nothing** about the air-gapped path — the
mirrored builder image, the Harbor push, the tag write-back, the ArgoCD sync. Only the pipeline does
that, which is what the next section is for.

## Redeploy it — **bump the version**

**The deployed image tag IS this app's declared version.** Bump it when you want the release
identity on the page to change.

A **code change alone also deploys**: the write-back stamps the build's commit sha into
`deployment.yaml` as well as the tag into `kustomization.yaml`, and the sha changes every build — so
the deploy repo changes, ArgoCD rolls, and `imagePullPolicy: Always` makes the pod re-pull the
re-pointed tag.

1. In Gitea, open **`demo/javawebapp-app`** -> **`pom.xml`** and bump the version
   (the one under the project's own `<artifactId>`, NOT the `<parent>` block):

   ```text
   <version>0.1.0</version>          ->   <version>0.1.1</version>
   ```

   Change the greeting in the same commit if you want to see it move too.

2. Commit. The push fires the webhook and the pipeline runs: clone -> test -> build -> push to
   Harbor -> write the new tag back into `javawebapp-deploy`.

3. Watch it: the Tekton dashboard, then Harbor (`apps/javawebapp` gains an artifact tagged with your new
   version **and** the commit sha, on one digest).

4. ArgoCD syncs the deploy repo and rolls the pod. Refresh **`javawebapp.vks.local`** — `Deployed tag`
   reads your new version, and `Commit` reads the sha that built it.

Each app declares its own version in its own file, so bumping this one changes **only javawebapp**.

⚠️ ArgoCD polls every **180s** (`timeout.reconciliation`), so step 4 can take up to three minutes
after the build finishes. Nothing is wrong if the page lags.

To build every app at once without editing anything — e.g. straight after an install, when Harbor is
empty and the pods are in `ImagePullBackOff` — run **`make build-apps`** from the repo root. It is
idempotent: it skips any app whose image Harbor already holds.

## Where things are

| | |
|---|---|
| this source | is the content of the Gitea repo **`demo/javawebapp-app`** |
| its manifests | `deploy/javawebapp/` -> the Gitea repo **`demo/javawebapp-deploy`** (ArgoCD's source) |
| its pipeline | rendered per app from `k8s/tekton/pipeline.yaml` by `make configure-tekton` |
| its row | `apps/registry.tsv` — one row per app; everything loops over it |
