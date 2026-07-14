# VKS — Scenario 2: Harbor & ArgoCD already exist (you are a tenant)

<br>

> **You're a *tenant***: Harbor + ArgoCD already exist. You **discover** them, **request** what you
> are not allowed to self-service, then run the pipeline.

In a shared lab the platform team has **already** installed Harbor and ArgoCD as Supervisor
Services. You are a **tenant**, not an admin — you don't install them. Instead you **discover**
the existing endpoints and **request** the grants you need, then wire this repo and run the flow.

**What that means concretely** — you consume a shared platform: you do **not** own the Supervisor,
the ArgoCD instance, the Harbor deployment, or (usually) the Istio mesh; you **do** own your guest
cluster's namespaces and the workloads in them.

| | |
|---|---|
| **Self-service** | your namespaces + Gitea/Tekton/the app · routes (`Gateway`/`HTTPRoute`/`VirtualService`) in **your own** namespaces · discovering the Harbor/ArgoCD/Istio endpoints · a Harbor **robot** *if* you hold **project-admin** (`make harbor-robot`) |
| **Must request** | the Harbor robot if you lack project-admin · an ArgoCD **AppProject/RBAC** role so you may create `Application`s · **registering your guest cluster** as an ArgoCD destination (**admin-only**) · a TLS `Secret` for `Gateway.tls.credentialName` (it lives in the *gateway's* namespace) |
| **Needed regardless** | **cluster-admin on your own guest cluster** (we create namespaces, RBAC, PSA labels) · PSA levels that admit Kaniko and the Istio-provisioned proxy (`make psa-check`) |
| **The surprise** | there are **no Istio credentials** — no login, no token, no admin API. Mesh access is plain kubectl RBAC; `make istio-preflight` reports what you may do and what to ask for. |

Everything you need is in this section — you do not have to read the other scenario. Dual-homed:
the jump box reaches both the internet and the lab (Supervisor API + Harbor).

## Discover Harbor & ArgoCD + request grants

**1 — Discover the endpoints** (read-only; you need at least read access to the Services'
namespaces, or ask the platform team for the values):

```bash
# Harbor LB IP (svc name/namespace vary per lab — verify on your lab):
kubectl get svc -n <harbor-namespace> <harbor-svc> \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# ArgoCD server LB IP:
kubectl get svc -n <argocd-namespace> argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

**2 — Request grants from the platform team:**

- **A Harbor project you can push to, plus a robot account.** Here the number of projects decides
  what you can do for yourself, because **Harbor scopes robots by level**:

  | You are | Projects the flow needs | What `make harbor-robot` does |
  |---|---|---|
  | Harbor **system-admin** | any | creates a **system-level** robot with push+pull on each — the only shape that can span two projects in one credential |
  | **project-admin**, and `HARBOR_INFRA_PROJECT` == `HARBOR_APP_PROJECT` | **one** | creates a **project-level** robot in it. Login name is `robot$<project>+<name>` (note: *not* `robot$<name>`) |
  | **project-admin**, two different projects | **two** | **impossible** — it prints the exact request and stops |

  Why impossible: a project-level robot (all a project-admin may create) is scoped to **exactly one**
  project, and *two robots cannot help* — the kaniko build pod carries **one** registry credential and
  must **pull** its builder/runtime images from `HARBOR_INFRA_PROJECT` *and* **push** the app image to
  `HARBOR_APP_PROJECT` with that same credential.

  So as a tenant, either **use one project for both** (set `HARBOR_INFRA_PROJECT` and
  `HARBOR_APP_PROJECT` to it **in `.env`** — the repo names don't collide) or **ask your platform
  admin** for a system-level robot with push+pull on both, and put `robot$<name>` + its secret in
  `.env`. `make harbor-robot` asks Harbor who you are (`GET /users/current`) and tells you which case
  you're in rather than failing with a bare 403.
- **An ArgoCD `AppProject` + RBAC** permitting `make gitops` to create each `Application` and
  deploy into that app's namespace. Set `ARGOCD_PROJECT` to your AppProject; per app, the admin
  must add the app's namespace to `spec.destinations` and its `<app>-deploy` repo URL to
  `spec.sourceRepos`. **UNVERIFIED and load-bearing:** a tenant may not be able to `kubectl apply`
  into the ArgoCD instance's (admin-owned) vSphere Namespace at all — a tenant's grant may be
  *ArgoCD* RBAC (via `argocd-server`) rather than *Kubernetes* RBAC. `make gitops` MEASURES this
  (`kubectl auth can-i`) and, if refused, prints exactly what to request. Settle it on your lab:
  `kubectl --kubeconfig $ARGOCD_KUBECONFIG -n $ARGOCD_NAMESPACE auth can-i create applications.argoproj.io`.
- **The workload cluster kubeconfig** — `vcf cluster kubeconfig get <cluster> --export-file
  ./secrets/vks.kubeconfig` for the cluster you run the demo in. You need **cluster-admin** on
  it (the flow creates the `gitea` / `ci` / `javawebapp` namespaces and installs Tekton CRDs).

**3 — Record what you discovered / were granted in `.env`.** `.env` is gitignored — create it first:

```bash
make env-init      # creates .env from .env.example (backs up any existing one)
```

Then set:

```bash
HARBOR_URL=<discovered-harbor-LB-IP-or-FQDN>
HARBOR_USERNAME='robot$<name>'          # the robot you were granted; set in .env only
HARBOR_PASSWORD=<robot-secret>          # never on argv
HARBOR_CA_FILE=./secrets/harbor-ca.crt  # fetched in Step 2 below (make fetch-harbor-ca)
HARBOR_INFRA_PROJECT=<granted-project>  # may be ONE shared project, not a cicd/apps split
HARBOR_APP_PROJECT=<granted-project>
HARBOR_PUBLIC_PROJECTS=false            # tenant projects are typically private (see Step 4)
ARGOCD_SERVER=<discovered-argocd-server-LB-IP>
ARGOCD_NAMESPACE=<namespace the shared ArgoCD instance watches>
ARGOCD_TRACK_BRANCH=main
# ARGOCD_CA_FILE=./secrets/argocd-ca.crt   # optional; fetched in Step 2 (make fetch-argocd-ca)
KUBECONFIG=./secrets/vks.kubeconfig
VKS_CONTEXT=<context-name-in-that-kubeconfig>
```

### Wire the repo & run the pipeline

**Step 0 — remove any STALE KinD overlay.** the state overlay is sourced *after* `.env`, so a leftover
one from a local run would silently redirect everything at a kind cluster. Delete it **before you
start**:

```bash
make state-show       # WHOSE state is this? (prints the cluster it was written for; redacts secrets)
make kind-down        # ONLY if you ran the local KinD flow on this box — deletes the state it wrote
```

The state overlay is **`.env.state`** (not `.env.kind` — that was renamed; a legacy `.env.kind` is still
read, and `make state-migrate` moves it). It is **stamped with the cluster it was written for**: if it
belongs to a *different* cluster it is **archived, not deleted** — it may hold the only copy of that
cluster's generated passwords. `make kind-down` removes it **only if the KinD flow wrote it**.

> **Do not delete it again later.** On VKS `make install-gitea` (inside `make platform`)
> *writes* the state overlay (`.env.state`) to publish the Gitea **LoadBalancer** address it just discovered
> (`GITEA_ARGOCD_URL`) — the address ArgoCD's repo-server clones from. That file is how the value
> reaches `make gitops`, which runs as a separate process. Removing it between `make platform` and
> `make gitops` throws the address away, and `make gitops` will refuse to build a repoURL ArgoCD
> cannot reach. (The name is a leftover from when only the KinD flow discovered anything.)

**Step 1 — finish `.env`.** The discovery step above filled the Harbor + ArgoCD values,
`ARGOCD_NAMESPACE`, and `KUBECONFIG` / `VKS_CONTEXT`. Only the **Gitea password** (a login for
the component **we** install) and the **VKS auth method** remain:

```bash
# --- Gitea (WE install it — you choose the password) ---
GITEA_ADMIN_PASSWORD=<choose-one>        # set in .env only

# --- VKS access method ---
VKS_AUTH_METHOD=kubeconfig               # simplest: use the KUBECONFIG you fetched above as-is
```

For VKS auth, `kubeconfig` (the kubeconfig `vcf cluster kubeconfig get` wrote) is the simplest
working method. To have `make vks-login` run the VCF Consumption CLI login itself, set
`VKS_AUTH_METHOD=vcf` and the `vcf` inputs (`SUPERVISOR_HOST` / `VKS_USERNAME` /
`VKS_NAMESPACE` / `VKS_CLUSTER_NAME` / `VKS_CONTEXT_NAME`) — see the
[VKS authentication](vks-authentication.md) section for the exact flow (written
to the verified shape but not yet lab-validated). For the legacy vSphere plugin, set
`VKS_AUTH_METHOD=vsphere` and `SUPERVISOR_HOST` / `VKS_NAMESPACE` / `VKS_CLUSTER_NAME` /
`VKS_USERNAME` / `VKS_PASSWORD`.

**Step 2 — save the Harbor CA certificate** to `./secrets/harbor-ca.crt` (the
`HARBOR_CA_FILE` path). If the lab handed you the cert, drop it there. Otherwise fetch it
from the running Harbor with **`make fetch-harbor-ca`** (reads `HARBOR_URL`, writes
`HARBOR_CA_FILE`), or by hand:

```bash
make fetch-harbor-ca                         # convenience: HARBOR_URL → HARBOR_CA_FILE
# …or the equivalent by hand:
mkdir -p secrets
openssl s_client -connect <harbor-host>:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > secrets/harbor-ca.crt
```

(Or download it from the Harbor UI → your project → **Registry Certificate**.) The CA is
consumed in **two** places, both handled for you: `make mirror` builds a **sudo-free** trust
bundle (`SSL_CERT_FILE` = the system CAs + your Harbor CA) so `crane` pushes over HTTPS
**without** touching the jump box's system trust store, and `make platform` creates an
in-cluster ConfigMap **`harbor-ca`** (key `ca.crt`) so Kaniko/Tekton trust it too. If Harbor
presents a publicly-trusted cert, leave `HARBOR_CA_FILE` empty.

For **ArgoCD**'s self-signed CA (only needed if you drive `argocd login` with verification, or
to trust its UI), fetch it the same way — `ARGOCD_SERVER` is already set from discovery, so run
**`make fetch-argocd-ca`** (writes `ARGOCD_CA_FILE`). The pipeline wires ArgoCD via `kubectl`
(not the `argocd` CLI), so this is optional for the demo itself.

**Step 3 — install prereqs and log in to VKS:**

```bash
make deps         # kind, crane, tkn, argocd, kubectl, helm + the rest of the mise toolchain
make vks-login    # validates $KUBECONFIG + context against the lab cluster
```

**Step 3b — install the Broadcom VCF/VKS lab CLIs.** You need the **licensed** `argocd-vcf` +
`vcf` binaries if **either** applies (both are the normal VKS case):

- you authenticate with `VKS_AUTH_METHOD=vcf` — `scripts/30-vks-login.sh` hard-requires `vcf`; or
- you need **`make fetch-argocd-kubeconfig`** (the Supervisor kubeconfig that lets `make gitops`
  register your guest cluster with the ArgoCD Supervisor Service) — it hard-requires `vcf` too.

They are only **optional** if you already hold a working workload-cluster kubeconfig
(`VKS_AUTH_METHOD=kubeconfig`) *and* your cluster is already registered with ArgoCD (Scenario 2,
where the platform team does it for you). The pipeline itself wires everything via `kubectl`. They install **sudo-free** to
`~/.local/bin`, and the installer picks the right archive for the jump box's **OS/arch**.

**Supply them as a folder.** Download the artifacts — however you have entitlement (the
[Broadcom support portal](https://support.broadcom.com) or an internal mirror) — on an
internet-connected box, drop them **all in one directory** (e.g. your browser's default
`~/Downloads/vcf`), and point `VCF_CLI_SRC_DIR` at it. This is the air-gap-correct path: carry
the folder in, no download client / token / network at install time.

**Just dump everything in there — the installer auto-selects.** You don't have to prune the
folder to this box's platform: it may hold every arch (`…-Linux_AMD64-…` + `…-Linux_ARM64-…`),
macOS builds, **and** the portal's multi-arch `…-Binaries-…` bundle, all at once. The installer
picks the archive matching **this jump box's OS/arch** and the **pinned versions** (from
`.env.example`) and ignores the rest — a mixed folder resolves deterministically, and if the
pinned version isn't present it errors clearly rather than ever installing a different version.

`VCF_CLI_SRC_DIR` is **required** — the installer does not guess where you dropped the files. Set
it on the command line, or uncomment it in `.env` (gitignored) so every `make` invocation picks
it up. The version pins in `.env.example` already match the current portal artifacts, so normally
you only set the folder:

```bash
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf   # argocd-vcf + vcf + vcf plugins
# or put it in .env once:  VCF_CLI_SRC_DIR=/home/you/Downloads/vcf   → then just `make install-vcf-clis`
# versions are pinned in .env.example (ARGOCD_VCF_VERSION / VCF_CLI_VERSION / VCF_PLUGINS_VERSION);
# keep them in sync with the artifacts you place in the folder.
```

**Packages this step needs** (`tar`, `gzip`/`gunzip`, `find`, `install`) — **`make deps`
already provides them** (`scripts/00-install-prereqs.sh` installs `tar`, `gzip`, `findutils`),
so if you ran the bootstrap you're covered. The installer also checks for them and errors
clearly if any is missing. On a minimal box where you skipped `make deps`:

- **Ubuntu:** present by default — nothing extra.
- **Photon OS:** `sudo tdnf install -y findutils` (`find` is not in Photon's base; its
  `gzip`/`tar` come from BusyBox-style **toybox**, which lacks `gzip -t` — the installer uses
  portable checks so it works there). `unzip` is **not** required — the artifacts are `.gz`/`.tar.gz`.

> **Fidelity vs VKS.** The local KinD stand-in faithfully reproduces the lab's
> **self-signed-TLS + CA-trust** posture (Harbor HTTPS + ArgoCD self-signed TLS on their own
> LBs). Three things differ on a VKS cluster and must be verified there: the workload cluster
> trusts the Harbor CA **declaratively** via the Cluster spec `trust.additionalTrustedCAs`
> (not per-node `certs.d`); a **private** Harbor project needs a robot account +
> `imagePullSecret`; and the lab is **FQDN**-addressed. See
> [KinD TLS fidelity → Fidelity vs a real VCF/VKS 9.1 lab](decisions/kind-tls-fidelity.md).

Because your Harbor project is a **tenant** project (typically **private**), the workload cluster
must trust the Harbor CA **declaratively** — add the CA to the Cluster spec
`trust.additionalTrustedCAs` (a request to the platform team if you don't own the Cluster
resource). The value is the CA PEM **encoded twice with base64** (VKS decodes one layer, then the
node trust store decodes the inner PEM):

```bash
# DOUBLE base64: the outer -w0 keeps it a single line for the Cluster YAML.
base64 -w 0 harbor-ca.crt | base64 -w 0
```

Reference: [William Lam — using a VKS cluster with a private container registry](https://williamlam.com/2024/06/using-a-vsphere-kubernetes-service-vks-cluster-with-a-private-container-registry.html).
(Verify the exact `trust.additionalTrustedCAs` shape against your VCF/VKS 9.1 lab — it is not
reproducible on the KinD stand-in.)

**Step 4 — Harbor projects + the image-pull secret.** Point `HARBOR_INFRA_PROJECT` /
`HARBOR_APP_PROJECT` at the project(s) you were **granted** (Step 2) — they already exist, so
`make mirror` (run in Step 6) just pushes to them (it does **not** need to create them). Because a
tenant project is typically **private** (`HARBOR_PUBLIC_PROJECTS=false`), the workload's kubelet
cannot pull the app image anonymously — so `make gitops` creates the image-pull secret
(`harbor-pull`) in **every app's namespace** from `HARBOR_USERNAME`/`HARBOR_PASSWORD`, and each
app's Deployment already references it. The pipeline's push secret (`harbor-dockerconfig` in `ci`,
Step 5) authorizes **pushes only**, never the workload's pull — two different credentials, two
different namespaces. You supply the robot you were granted; the wiring is automatic:

```bash
make harbor-robot                                  # → secrets/harbor-robot.env (if you hold project-admin)
# then copy its two lines (HARBOR_USERNAME='robot$<name>' / HARBOR_PASSWORD=…) into .env
```

Confirm the namespace the shared ArgoCD watches (for `ARGOCD_NAMESPACE`). **ArgoCD is a Supervisor
Service — it does NOT run in your guest cluster**, so this must query the ArgoCD side, not your
`KUBECONFIG`:

```bash
kubectl --kubeconfig $ARGOCD_KUBECONFIG get pods -A | grep argocd-application-controller
```

If you have no kubeconfig for it (a locked-down tenant often does not), **ask the platform team for
the namespace** — or use `ARGOCD_MECHANISM=api`, which needs no Kubernetes access there at all.

**Step 5 — verify (or create) the in-cluster registry secret.** The pipeline pushes the
built image to Harbor from inside the cluster, which needs a Docker-config secret.
`make platform` (its `configure-tekton` step, run in Step 6) creates it for you as
**`harbor-dockerconfig`** in the `ci` namespace, from `HARBOR_USERNAME` / `HARBOR_PASSWORD`.
Check whether it already exists:

```bash
kubectl -n ci get secret harbor-dockerconfig
```

<br>

Keep the secret **off argv** — build the `config.json` on disk and load it from a file; kaniko
needs the key named literally `config.json`, not `.dockerconfigjson`:

```bash
umask 077
auth=$(printf '%s:%s' "$HARBOR_USERNAME" "$HARBOR_PASSWORD" | base64 -w0)
printf '{"auths":{"%s":{"auth":"%s"}}}' "$HARBOR_URL" "$auth" > /tmp/harbor-config.json
kubectl -n ci create secret generic harbor-dockerconfig \
  --from-file=config.json=/tmp/harbor-config.json --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/harbor-config.json
```

The Kubernetes secret is built from your Harbor **login/password**; Harbor's **REST API** is
used only to create a robot account (if you self-service one) — it does not create this cluster
secret.

**Step 6 — prove your `.env` works, then install:**

Catch a wrong value in **seconds** instead of 20 minutes into the mirror. As a tenant you were *given*
most of these values, so this is exactly where a typo or a stale endpoint shows up:

```bash
make env-populate   # DISCOVER what is discoverable (Harbor / ArgoCD endpoints) instead of re-typing it
make env-check      # presence gate: is every required value set? (fast, no network)
make env-validate   # validity gate: does KUBECONFIG reach the cluster, and does Harbor really authenticate?
```

**Expect:** `env-check` → *all required values present*; `env-validate` → Harbor reachable **and
authenticated over HTTPS with your CA**. If the CA you were handed does not actually verify Harbor, it
fails **here**, not inside Kaniko an hour later.

**Then install:**

```bash
make install-all   # preflight → mirror → mirror-verify → builder-image → vks-login → platform → gitops
make psa-check     # NOW it can measure something — expect `PSA OK — … (N measured)`, not `PSA UNPROVEN`
make verify        # push a marked change → Tekton → Harbor → ArgoCD → live app serves it
make creds-show    # every URL + login for THIS context — one row per app in apps/registry.tsv
```

`install-all` deliberately does **not** install Harbor or ArgoCD — the platform team already
did. It mirrors all images into that Harbor, builds + pushes the offline Maven builder image,
installs Gitea + Tekton, and creates the ArgoCD `Application` (through the `AppProject` + RBAC you
were granted).

> **Cross-cluster ArgoCD deploy.** The shared ArgoCD runs on the **Supervisor**, so it must be
> told where your **guest** workload cluster is — and **registering a cluster is an ArgoCD-ADMIN
> operation** you cannot self-service as a tenant. Do **not** set `ARGOCD_KUBECONFIG` (you lack
> Supervisor/ArgoCD-admin access, so `make gitops`'s auto-registration would fail). Instead
> **request** that the platform team register your guest cluster as an ArgoCD destination (they
> run `make argocd-register-guest` / `argocd cluster add`, or wire it via the argocd-attach-service
> CRs), then set **`ARGOCD_DEST_SERVER`** to your guest cluster's API URL in `.env` so the
> `Application` deploys **into your guest cluster**, not onto the Supervisor. This installs no
> second ArgoCD in the guest.

**Step 7 — access the UIs.** Harbor and ArgoCD are the **shared** instances — use the endpoints
you discovered + the credentials you were granted. For **Gitea** (which you installed) and the
deployed **app**, either front them with the ingress at `*.vks.local`, or `kubectl port-forward`
(`kubectl -n gitea port-forward svc/gitea-http 3000:3000`,
`kubectl -n javawebapp port-forward svc/javawebapp 18080:80`).

> **Ingress — ASK the cluster whether a mesh is there. Do not assume.** A platform team *may* have
> shipped your cluster with the VKS Istio package (possibly at cluster-creation time) — but
> **available is not installed**, and you hold cluster-admin on your own guest cluster, so either
> answer is workable. `istio-preflight` measures it; it is sitting right there.
>
> ```bash
> make istio-preflight     # read-only: is Istio here? what does it require of me? what must I request?
> ```
>
> | It says | You run |
> |---|---|
> | **Istio is here** (the expected tenant case) | `make install-ingress INGRESS_CONTROLLER=istio-existing` — installs **nothing**, attaches routes only. **Never** the bare `make install-ingress` against a mesh you did not install: its default would **helm-install a second istiod over the platform's**. |
> | **NO Istio detected** | `make install-ingress` (installs our own; images come from your Harbor) or `INGRESS_CONTROLLER=traefik` for a lighter option. |
>
> `istio-preflight` also prints the exact `Gateway` selector the mesh requires, what your kubeconfig
> may actually do, and what (if anything) to **request from the mesh admin**. It picks the route API:
> the **Kubernetes Gateway API** when Istio is an Accepted `GatewayClass` (Istio then auto-provisions
> the proxy *and* its LoadBalancer — nothing needed from the platform team), else the classic
> `Gateway`/`VirtualService` path.
>
> ⚠️ **As a tenant you cannot install the Gateway API CRDs.** If they are absent, you are on the
> classic path — and the VKS package ships its shared gateway **off by default**, so there may be
> nothing to bind to. In that case you must **ask the mesh admin** to enable a gateway.
> `istio-preflight` says so in those words.
>
> Add the printed `INGRESS_LB_IP` line to `/etc/hosts`
> (see [Access the UIs](../README.md#access-the-uis-urls-logins-passwords)).
>
> **PSA: `make psa-check` cannot prove anything *before* you install — and it will say so.** A VKS guest
> cluster enforces the `restricted` Pod Security Standard **by default** (VKr v1.26+), which **rejects**
> our Kaniko build pods and the Istio-provisioned gateway proxy unless their namespaces are labelled
> `baseline`. The installers apply the measured labels.
>
> But run it too early and every namespace is *absent*, so it measures nothing and prints
> **`measured 0 namespace(s) … PSA UNPROVEN`**. That is the correct answer at that point, and it is
> **not a pass** — a green there would have been true before any of our code ran. The run that proves it
> is the one **after `make platform`**; look for `PSA OK — … (N measured)`.

<br>

- **No STALE state overlay when you start** (Step 0) — it is sourced after `.env` and silently forces
  kind values.
- **The shared ArgoCD must be able to deploy into your workload cluster** — i.e. your guest
  cluster must be **registered** as an ArgoCD destination. That is **admin-only** (`clusters` is
  a global ArgoCD RBAC resource), so you **request** it; the destination then becomes
  `${ARGOCD_DEST_SERVER}` instead of in-cluster (`k8s/argocd/application.yaml`).
- **You do NOT need `kubectl` access to the cluster ArgoCD runs in.** As a tenant you usually will
  not have it — and you do not need it. ArgoCD's `applications` and `repositories` are
  **project-scoped** RBAC, so `make gitops` can create the `Application` **through `argocd-server`**
  using only your `AppProject` role. `ARGOCD_MECHANISM` picks how:

  | value | what it does |
  |---|---|
  | `auto` (default) | tries `kubectl`, falls back to the API, then tells you exactly what to request |
  | `kubectl` | apply into `ARGOCD_NAMESPACE` (needs k8s RBAC there — the admin path) |
  | `api` | create via `argocd-server` — **the tenant path**. Needs `ARGOCD_SERVER` + `ARGOCD_AUTH_TOKEN`, and **no** Kubernetes RBAC in the ArgoCD namespace |
  | `request` | apply nothing; print the exact grant to ask the platform team for |

  Get a token with `argocd login <server> --sso` then
  `argocd account generate-token --account <you>`, and put it in `.env` as `ARGOCD_AUTH_TOKEN`
  (never on argv).
- **`ARGOCD_NAMESPACE` must match** where the shared ArgoCD controller watches Applications
  (Step 4), and your granted **`AppProject` + RBAC** must permit the `Application` + destination.
- **ArgoCD must be able to CLONE Gitea from whatever cluster ArgoCD runs in.** In-cluster
  (KinD, ArgoCD-in-guest) that is `GITEA_INTERNAL_URL` (`http://gitea-http.gitea.svc:3000`).
  On VKS ArgoCD is a **Supervisor Service** — a *different* cluster — and that name does
  not resolve there, so Gitea gets its **own LoadBalancer** and `make install-gitea` publishes
  `GITEA_ARGOCD_URL` (`http://<gitea-lb-ip>:3000`). The ingress hostname (`gitea.vks.local`) is
  **not** usable for this: it exists only in your `/etc/hosts`, and dialling the ingress IP sends
  `Host: <ip>`, which matches no vhost (404, not a clone). `make gitops` refuses to build an
  unreachable repoURL rather than let every Application fail silently.
- **cluster-admin** on the workload cluster is required — the flow creates namespaces
  (`gitea`, `ci`, `javawebapp`) and installs Tekton CRDs.
- **StorageClass:** Gitea uses a PVC (`GITEA_STORAGE_SIZE`, default `5Gi`). Ensure the
  cluster has a default StorageClass (or set one explicitly).
- **Harbor project(s)** you were granted must exist and you must hold **push** on them; a
  **private** project also needs the app-namespace `imagePullSecret` (Step 4).
- **Network reach (dual-homed):** the jump box must reach the **VKS cluster's** API server, the
  shared **ArgoCD server** endpoint (`ARGOCD_SERVER` — the tenant `api` path dials it; ArgoCD is a
  Supervisor Service, so that endpoint is Supervisor-side), and the lab **Harbor**. The **Supervisor**
  API itself is only needed if you have `kubectl` there (endpoint discovery, or `ARGOCD_MECHANISM=kubectl`).

---

[← back to the README](../README.md)
