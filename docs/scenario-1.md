# VKS — Scenario 1: you install Harbor & ArgoCD

You have a **Supervisor** endpoint, a login, and a password. You install **Harbor** and **ArgoCD**
as **Supervisor Services**, provision a **guest VKS cluster**, and run the pipeline into it. The jump
box is dual-homed (internet + lab).

> **Topology.** Harbor + ArgoCD run on the **Supervisor**; Gitea, Tekton and your app run in the
> **guest cluster**. Different clusters, different kubeconfigs. Istio is a guest-cluster package, not
> a Supervisor Service (Step 11).

**Auth, in one sentence:** you use the `vcf` CLI to build the lab (Steps 3–4 and 8) and to export a
guest kubeconfig; the pipeline then runs against that kubeconfig (`VKS_AUTH_METHOD=kubeconfig`). Both
surfaces are needed and that is intentional.

**Versions here are illustrative.** The one that matters is your Supervisor's **running ArgoCD
server**, not the `argocd` CLI or this repo's KinD pin. `make argocd-version` prints all three (exits
0, no cluster needed); `make argocd-preflight` (Step 8) adds the server number once the cluster is up.

> **Broadcom links — check the version picker.** Every techdocs page carries a `CHANGE VERSION`
> control, and not every page exists at every version. The two `/9-1/` links below were fetched
> 2026-08-05 and are genuine 9.1 pages: HTTP 200, no redirect, `rel="canonical"` pointing at the
> `/9-1/` path. That grades the *page*, not its text — the body is rendered client-side, so confirm
> the picker reads **9.1** before following a procedure. Other Broadcom deep-links (the `vcf`-CLI and
> package-reference pages especially) exist only under `/9-0/`, and `/latest/` is not a safe
> substitute — the `/latest/` form of the Argo CD page below **404s**. Anything this runbook
> transcribes from a 9.0 page is labelled where it appears (Step 11).

## Downloads (each needs your Broadcom entitlement)

| Artifact | Version | |
|---|---|---|
| **VCF Consumption CLI** — the Linux `_AMD64`/`_ARM64` archive for your jump box | **9.1.0.0400** | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0400&os=&servicePk=540528&language=EN&groupId=540529&viewGroup=true) |
| **VCF Consumption CLI Plugins** — the Linux `_AMD64`/`_ARM64` bundle | **9.1.0.0400** | [download](https://support.broadcom.com/group/ecx/productfiles?displayGroup=VMware%20Cloud%20Foundation%209&release=9.1.0.0400&os=&servicePk=540528&language=EN&groupId=540672&viewGroup=true) |
| **ArgoCD Service** — the `-legacy` manifest + the amd64 `argocd` CLI (`v3.0.19-vcf`) | **1.1.0** | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=ArgoCD%20Service&release=1.1.0&os=&servicePk=538499&language=EN) |
| **Harbor** — the `-legacy` manifest + its data-values file | **2.14.3** | [download](https://support.broadcom.com/group/ecx/productfiles?subFamily=vSphere%20Supervisor%20Services&displayGroup=Harbor&release=2.14.3&os=&servicePk=542081&language=EN) |

**Where each goes:**

- **CLI + Plugins + the `argocd` CLI** → one folder (e.g. `~/Downloads/vcf`); set **`VCF_CLI_SRC_DIR=<folder>`** — `make install-vcf-clis` reads it and picks your OS/arch (§1). *(arm64: the VCF `argocd` is amd64-only — use the upstream one from `make deps`; [details](vks-authentication.md#acquiring-the-licensed-vcf-cli-archives).)*
- **ArgoCD Service + Harbor** are Supervisor-Service YAMLs — uploaded in **§2**/**§3**, not via the installer.

## 1. Jump box

**Goal:** the toolchain, the licensed `vcf` CLI, and a blank `.env`. Step 3 uses `vcf`, so install it now.

```bash
make env-init                                         # a blank .env from .env.example
make deps                                             # mise toolchain (kind, crane, tkn, kubectl, helm…)
make install-vcf-clis VCF_CLI_SRC_DIR=~/Downloads/vcf # the licensed argocd-vcf + vcf + plugins (sudo-free)
make check-tools                                      # what you have, what is missing
```

> Don't have the archives yet? See [Acquiring the licensed VCF CLI archives](vks-authentication.md#acquiring-the-licensed-vcf-cli-archives) — portal source, the per-arch manifest, and the arm64 argocd fallback.

**Result:** `check-tools` lists no missing **required** CLI.

**Then edit `.env`** — these keys already exist there (commented, from `.env.example`); uncomment and set:

| key | value |
|---|---|
| `SUPERVISOR_HOST` | Supervisor Control Plane IP (vCenter → Workload Management → Supervisors). Bare host, no scheme. |
| `VKS_CONTEXT_NAME` | a name you choose for the `vcf` context, e.g. `sup` — passed positionally in Steps 3–4. |
| `VKS_NAMESPACE` | the **workload** vSphere Namespace where you create the guest cluster (Step 4). |
| `VKS_CLUSTER_NAME` | the guest cluster you create in Step 4. |
| `VKS_USERNAME` | *optional* — defaults to `administrator@wld.sso`, **loudly**, because that default is almost certainly not yours. See the note below. |
| `VKS_SSO_DOMAIN` | *optional* — your SSO domain alone (the code appends it to a bare user). Prefer this over overriding the whole `VKS_USERNAME`. |

> **Your SSO domain is a parameter, not a constant.** Two real 9.1 labs disagree: one is
> `vsphere.local`, the other `wld.sso` — the built-in default. Neither is "the" value, which is why
> `make vks-login` **warns** whenever it applies the default rather than accepting it silently. Read
> yours off vCenter (**Administration → Single Sign On → Users and Groups**, the *Domain* dropdown —
> it is the domain you already log into vCenter with) and set `VKS_SSO_DOMAIN=<that domain>`, or set
> `VKS_USERNAME=<user>@<that domain>` if you log in as someone other than the SSO administrator.
> Guessing here does not fail cleanly: a plausible-but-wrong principal takes your real password at
> an interactive prompt and then fails somewhere else.
>
> The Supervisor **password is never in `.env`** — you enter it at the `vcf context create` prompt
> (Step 3), or `export VCF_CLI_VSPHERE_PASSWORD` for the session. ⛔ **Never `vcf config set
> env.VCF_CLI_VSPHERE_PASSWORD …`** — it writes the password **plaintext** to
> `~/.config/vcf/config.yaml`, outside the repo, invisible to gitleaks, and it survives teardown.

**Ran the local KinD flow on this box before?** `make state-show` then `make kind-down` — a stale
overlay is sourced after `.env` and would silently redirect everything at a kind cluster. (It is
archived, not deleted, if it belongs to a *different* cluster — it may hold that cluster's passwords.)

## 2. Harbor — a Supervisor Service (browser)

**Goal:** the registry every image is pulled from. Browser work — not scriptable.
[Broadcom: Installing and configuring Harbor and Contour](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-harbor-as-vcf-service/installing-and-configuring-harbor-and-contour.html).

1. **Expose it** — Harbor needs an LB/ingress. Pick an **NGINX LB** or **Contour** (a Supervisor
   Service; install it *before* Harbor).
2. **Register:** Supervisor Management → Services → Add New Service → upload the Harbor manifest — `supervisor-service-harbor-legacy-*.yml` for a disconnected/air-gapped Supervisor (or the `-depot` variant if it reaches the Broadcom depot).
3. **Decide the two values that are yours, not ours.** Neither is a constant — two real 9.1 labs
   disagree on both — so nothing below hardcodes them:

   | | what it is | lab A | lab B | how to find yours |
   |---|---|---|---|---|
   | `HARBOR_FQDN` | the name Harbor will serve, and the name **the guest nodes must resolve** | *you choose* | *you choose* | you pick it; it must be a name real DNS can answer (see the DNS note below) |
   | `HARBOR_STORAGE_CLASS` | the Supervisor storage class Harbor's PVCs bind to | `wcp-vmfs` (single-host VMFS) | `vsan-default-storage-policy` (vSAN) | `kubectl get storageclass` **against the Supervisor** — or, before you have that access, the vSphere Client: the Namespace's **Storage** tab lists the policies assigned to it |

   > The `kubectl` form needs a Supervisor kubeconfig, which Steps 3 and 8 produce. If you are doing
   > §2 first (the normal order), read the value off the vSphere Client instead — but **the class
   > name is the policy name normalized**, not the string the UI shows: the policy *"vSAN Default
   > Storage Policy"* is the class `vsan-default-storage-policy`. Lowercase it and replace spaces
   > with `-`, then re-check with `kubectl get storageclass` as soon as Step 3 gives you access.
   > Pasting the UI string verbatim is not a loud failure — quoted, it is written straight through,
   > and no PVC ever binds because it is not a valid Kubernetes object name.

4. **Check the file still has the keys before editing it**, then edit:

   ```bash
   src=~/Downloads/vcf/supervisor-service-harbor-data-values-v2.14.3.yml
   HARBOR_FQDN='<the name you chose>'             # e.g. harbor.example.internal
   HARBOR_STORAGE_CLASS='<from the table above>'  # e.g. wcp-vmfs
   # Quoted on purpose: bare <angle brackets> are shell REDIRECTION and would be a syntax error.

   # PRECONDITION. `yq '.k = v'` CREATES a missing key, so if the vendor renames the expose
   # toggles, setting them APPENDS two dead top-level keys, leaves the real one untouched, and
   # ships a Harbor with NO REACHABLE INGRESS and no error — every downstream check still green.
   # (`sed` has the mirror failure: it silently changes nothing.) Verified on v2.14.3.
   yq -e 'has("enableNginxLoadBalancer") and has("enableContourHttpProxy")' "$src" >/dev/null \
     || { echo "If yq printed an error above, THAT is the cause (a missing/unreadable file), not the vendor."; \
          echo "Otherwise: this data-values file does not carry BOTH expose keys at the top level."; \
          echo "Either the vendor changed the expose mechanism, or the keys are nested."; \
          echo "Do NOT just set them — open the file and find where the toggles moved to."; \
          false; }
   # `false`, not `exit 1`: if you pasted this into your shell, `exit` would CLOSE it and take the
   # two variables you just set with it. If this trips, stop here — do not run the sed below.

   cp "$src" harbor-values.yaml
   sed -i \
     -e "s/hostname: yourdomain.com/hostname: ${HARBOR_FQDN:?set HARBOR_FQDN above}/" \
     -e 's/enableNginxLoadBalancer: false/enableNginxLoadBalancer: true/' \
     -e "s/insert-storage-class-name-here/${HARBOR_STORAGE_CLASS:?set HARBOR_STORAGE_CLASS above}/" \
     -e 's/enableContourHttpProxy: true/enableContourHttpProxy: false/' \
     harbor-values.yaml
   # the two LB toggles are mutually exclusive; set BOTH false for a plain Ingress instead.
   ```

   > ⚠️ **The `:?` guards are load-bearing.** Without them an unset variable substitutes **empty**,
   > the pattern still *matches*, and you write a `hostname:` key with nothing after it — a Harbor
   > that installs cleanly and is unreachable. This is the opposite failure to a non-matching `sed`, and the caveat about
   > non-matches does not cover it.
   >
   > ⚠️ **Three known limits of the precondition, so you can judge a red honestly.** It reads only
   > the **top level**, so a file that *nests* the toggles (`harbor: {enableNginxLoadBalancer: …}`)
   > fails it even though the file is fine — read the file, do not delete the check. On a **multi-
   > document** file it passes if *any* document carries both keys, so it can clear a file whose
   > first document does not. And it checks a key's **presence**, not the literal `key: false` the
   > `sed` matches — a quoted or re-defaulted value (`enableNginxLoadBalancer: "false"`) passes the
   > guard while the substitution silently no-ops. The first two were reproduced against `yq`
   > v4.53.3 on synthetic files; the real licensed artifact is not in this repo, so its shape is not
   > something we can gate offline.
   >
   > **So confirm the edit landed** — this is the check that covers all four substitutions, and the
   > two that are *not* preconditioned at all (`hostname`, the storage class):
   >
   > ```bash
   > diff "$src" harbor-values.yaml    # expect exactly 4 changed lines
   > ```

   Then replace **every `[Required]` secret by hand** (make them distinct): `harborAdminPassword`
   (ships the known default `Harbor12345`) · `secretKey` (**16 chars**) · `core.xsrfKey` (**32 chars**)
   · and `database.password`, `core.secret`, `jobservice.secret`, `registry.secret`. Leave
   `tls.crt`/`tls.key`/`ca.crt` empty (cert-manager self-issues); do **not** touch
   `tlsCertificate.tlsSecretLabels` (`managed-by: vmware-vRegistry`, required for VKS trust).
5. **Apply (browser):** Supervisor Management → Services → Harbor → Actions → Manage Service → pick
   version + Supervisor → paste `harbor-values.yaml` → Finish.
6. **Map `HARBOR_FQDN` with real DNS** the **guest cluster's nodes** can resolve — `kubectl get svc -n
   <harbor-ns>` (against the **Supervisor**) for the ingress IP, then create the record.

> **DNS, not `/etc/hosts`.** Every kubelet on the guest cluster pulls from `$HARBOR_URL` and cannot
> see the jump box's hosts file. With only a hosts entry, `make mirror` succeeds and every workload
> `ImagePullBackOff`s later. **No DNS?** Use Harbor's **LB IP** as `HARBOR_URL` — but the cert must
> then carry an **IP SAN** (Go rejects a DNS-only cert on an IP URL even when the CA is trusted).

**Result:** Harbor's UI answers at your FQDN. (That the guest nodes can *resolve and trust* it is
proven later, by Step 9's `make verify` pulling the app image into the guest.)

**→ `.env`:**

| key | value |
|---|---|
| `HARBOR_URL` | the `HARBOR_FQDN` you chose — **bare host, no scheme, no trailing slash** (a leading `https://` yields `https://https://…` and `curl: (6) Could not resolve host: https`; the setup strips and warns, but every other consumer would be reading your wrong value) |
| `HARBOR_USERNAME` | `admin` (or a robot — Step 7) |
| `HARBOR_PASSWORD` | your `harborAdminPassword` — `.env` only, never argv |
| `HARBOR_CA_FILE` | `./secrets/harbor-ca.crt` (fetched in Step 6) |
| `HARBOR_INFRA_PROJECT` / `HARBOR_APP_PROJECT` | `cicd` / `apps` |

## 3. ArgoCD — Operator + instance (Supervisor, `kubectl`)

**Goal:** the GitOps engine, running **on the Supervisor**.
[Broadcom: Install Argo CD Service](https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/using-argo-cd-service/install-argo-cd-service.html).

1. Install the **ArgoCD Operator** Service — same flow as Harbor (upload `supervisor-service-argocd-legacy-*.yml` for a disconnected/air-gapped Supervisor, or the `-depot` variant if it reaches the Broadcom depot).
2. Create a **vSphere Namespace** for the instance (e.g. `argocd-instance-1`) with VM + storage classes.
3. **Load `.env` into your shell** so the raw `$VAR` commands in this step and Step 4 resolve —
   `make` sources `.env` for you, an interactive shell does **not**. Re-run after any `.env` edit:

   ```bash
   set -a; . ./.env; set +a
   ```

4. **Authenticate to the Supervisor** (interactive password prompt; nothing secret on argv):

   ```bash
   # PREFER a verified CA over skipping verification — a password is submitted over this
   # connection. --ca-certificate takes the Supervisor's VMCA root (see §8 for getting it).
   vcf context create "$VKS_CONTEXT_NAME" --endpoint "$SUPERVISOR_HOST" \
       --ca-certificate ./secrets/supervisor-ca.crt --auth-type basic
   # ...only if you have no CA yet:  --insecure-skip-tls-verify   (instead of --ca-certificate)
   #    -- but see the field note below: it is NOT a reliable escape hatch.
   vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"     # note the <ctx>:<ns> COLON form
   ```

   > ⚠️ **`--ca-certificate` and `--insecure-skip-tls-verify` are an ENFORCED EXCLUSIVE PAIR** —
   > passing both fails with `[x] : … [ca-certificate insecure-skip-tls-verify] were all set`
   > (measured 2026-08-04). Pick one.
   >
   > ⚠️ **Do not plan on the insecure flag.** On one lab (2026-08-04) the run still died with an
   > x509 error after passing it. That was seen once, is not otherwise recorded in this repo, and
   > the cause was never isolated — so treat it
   > as a field note rather than a property of the flag — and note two rival explanations before
   > you blame it: `vcf context use` on the very next line carries **no TLS flag at all** and must
   > still reach the Supervisor, and a context left over from a previous lab (below) brings its own
   > TLS material with it. **Get the CA** (Step 8 names where it comes from); it is the path that
   > is known to work, and a password is submitted over this connection either way.
   >
   > ⚠️ **`vcf context create` REFUSES a duplicate context name** (`context "<name>" already
   > exists`) and its store — `~/.config/vcf/config.yaml` — lives **outside this repo and outside
   > every teardown**, so it survives a lab rebuild and then blocks you while pointing at a DEAD
   > endpoint. Delete before creating:
   > `vcf context delete "$VKS_CONTEXT_NAME" -y --skip-delete-kubeconfig-context 2>/dev/null || true`
   > (`make vks-login` does this for you.)
   >
   > ⚠️ **`vcf context create` WRITES ITS CONTEXTS INTO `$KUBECONFIG` and repoints that file's
   > current-context at the Supervisor.** If `$KUBECONFIG` is your *guest*-cluster kubeconfig, every
   > later `kubectl` — and `make platform` / `make gitops` — silently targets the **Supervisor**
   > instead of your workload cluster. Point `KUBECONFIG` at a Supervisor-only file for these two
   > commands (`KUBECONFIG=./secrets/supervisor.kubeconfig vcf context create …`), as
   > `make fetch-argocd-kubeconfig` does.
   >
   > ⚠️ **`vcf context use` can exit NON-ZERO after succeeding** — it prints
   > `Successfully activated context …` and then fails plugin discovery against a "system Harbor
   > registry" that a Supervisor only has if one is registered as such. Judge it by the artifact
   > (`kubectl … get ns`), not by the exit status. No env var or flag suppresses it.
   >
   > ⚠️ **TWO FORMS.** The form above is the one **lab-verified** on a 9.1 Supervisor (positional
   > name, bare endpoint). The repo's `make vks-login` additionally passes `--username`+`--type
   > kubernetes`, which is **not** lab-verified — if either flag is rejected, the form above is
   > known-good; confirm with `vcf context create --help`. (vSphere 8: `kubectl vsphere login
   > --server $SUPERVISOR_HOST`.)

5. **Pick a supported version and apply the CR** (`kubectl explain argocd.spec.version` lists what
   your operator supports):

   ```yaml
   apiVersion: argocd-service.vsphere.vmware.com/v1alpha1
   kind: ArgoCD
   metadata: { name: argocd-1, namespace: argocd-instance-1 }
   spec: { version: <supported-version> }
   ```

6. **Get its LB IP + admin password, and log in:**

   ```bash
   kubectl get svc -n argocd-instance-1                     # argocd-server → EXTERNAL-IP
   kubectl get secret -n argocd-instance-1 argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d
   argocd login <LB-IP>                                     # accept the self-signed cert
   argocd account update-password
   ```

**Result:** `argocd-server` has an EXTERNAL-IP and you can log in.

**→ `.env`:**

| key | value |
|---|---|
| `ARGOCD_NAMESPACE` | `argocd-instance-1` — the vSphere Namespace the instance runs in |
| `ARGOCD_SERVER` | the `argocd-server` LB IP |
| `ARGOCD_TRACK_BRANCH` | `main` |
| `ARGOCD_CA_FILE` | *optional* — `./secrets/argocd-ca.crt` (`make fetch-argocd-ca`) |

## 4. Guest VKS cluster

**Goal:** where Gitea, Tekton and your app run. You need **cluster-admin** on it.

**Already have a namespace and a cluster?** Skip to *"Export its kubeconfig"* below.

### 4a. Create the vSphere Namespace

Two mechanisms exist and they are **not** interchangeable:

| | who can run it | notes |
|---|---|---|
| **vCenter REST** (`POST /api/vcenter/namespaces/instances`) | vCenter admin — **which is this scenario's persona** (see the README: *"I am the admin"*) | creates an **unquota'd** namespace |
| `kubectl create namespace` (self-service) | any user in the namespace-template's allowlist | **cannot be your first step** — see below |

> ⚠️ **Self-service is NOT a tenant alternative to the REST call — it is downstream of it.**
> Turning it on requires a vCenter SSO-admin session, a storage-policy id, a network, a
> `namespace-templates` POST and an `activate` POST — and the network is resolved by reading an
> **existing** namespace. So on a bare Supervisor, `kubectl create namespace` returns
> `Error from server (Forbidden)`. Treat it as an optional, one-time **platform enablement** your
> admin performs, not as a step in this runbook.
>
> ⚠️ **If your platform team's template sets quotas, size them for the cluster.** MEASURED on one
> 9.1 lab: a 2-node guest cluster consumes **~48 GiB** in its namespace — 40 GiB of node root disks
> (which appear as **PVCs**, 20 GiB each) plus ~8 GiB attributed to VM Operator. A template
> defaulting to 20 GiB is under-provisioned before a single application PVC.
> *(On a stock VCF install there may be no quota at all — measured here: a self-service namespace
> came back with `appliedLimit` unlimited, identical to a REST-created one. Check yours; do not
> assume either way.)*

### 4b. Provision the guest cluster — DISCOVER, then pin

Neither the ClusterClass nor the Kubernetes version is a constant. **Read them off your own
Supervisor** and put the answers in `.env`:

```bash
# Newest READY ClusterClass (one lab had SIX: builtin-generic-v3.1.0 … v3.6.0)
kubectl get clusterclass -n vmware-system-vks-public
# TKrs that are BOTH Ready and Compatible — anything else will be rejected at admission
kubectl get kubernetesreleases
```

→ `.env`: `VKS_CLUSTERCLASS`, `VKS_K8S_VERSION`, `VKS_VM_CLASS`, `VKS_STORAGE_CLASS`,
`VKS_CONTROL_PLANE_COUNT`, `VKS_NODE_COUNT`.

Then create it, and wait for it properly:

```bash
make vks-cluster-create   # renders k8s/vks/cluster.yaml from those keys and applies it
make vks-cluster-status   # conditions + observedGeneration + NODES (see the readiness note below)
```

> **These six keys are now READ** — `make vks-cluster-create` is their reader (they had none when
> this runbook was written). Three of them default in code if you leave them unset:
> `VKS_CLUSTERCLASS` → `builtin-generic-v3.6.0`, `VKS_CONTROL_PLANE_COUNT` → `1`,
> `VKS_NODE_COUNT` → **2** (the measured floor below, not the `1` the example line shows).
>
> ⚠️ **`VKS_K8S_VERSION` is a PREFIX, not an exact version, and admission REWRITES it.** MEASURED
> 2026-08-08 with four server-side dry-runs: `v1.32.10+vmware.1-fips-vkr.2`, `v1.32.10+vmware.1-fips`
> and even a bare `v1.32` are **all accepted** and all store as `v1.32.10+vmware.1-fips`; only a
> version no TKr matches is denied, and the denial names the mechanism (`k8sVersionPrefix`). Three
> consequences: a value **absent from `kubectl get kubernetesreleases`' Ready+Compatible list can
> still be perfectly admissible** (so do not gate on that list); a bare prefix **floats** to the
> newest matching patch, which an air-gap repo does not want; and the ground truth for *which* TKr
> you got is the `run.tanzu.vmware.com/tkr` **label on the created object**, never
> `spec.topology.version`.
>
> `vks-cluster-create` validates with **`kubectl apply --dry-run=server`** before applying — that
> runs the real webhooks and rejects a misspelled variable, a VM/storage class that does not exist
> in *your* namespace, and an unresolvable version, with the server's own wording. The one thing it
> does **not** catch is an *empty* value (measured: an empty `replicas` is accepted silently), so the
> script checks the rendered manifest for empty substitutions itself.
>
> 🔴 **SIZING — provision at least TWO workers.** The platform install requests **~1.9 CPU** on a
> worker, and a single 2-CPU node (`best-effort-small`) **will not fit it**. MEASURED 2026-08-05 on
> a real 9.1 lab:
>
> | | |
> |---|---|
> | worker allocatable | **1930m** (a 2-CPU node after system reserve) |
> | requested by the platform | **1840m (95%)** |
> | `tekton-pipelines-webhook` wants | **100m** |
> | → | **short by 10m**, `FailedScheduling` |
>
> The control plane does **not** help: the platform's pods carry no control-plane toleration, so a
> 2-node cluster gives you exactly **one** schedulable node. And 95% was measured *before any
> pipeline ran* — Tekton tasks need burst capacity, not just steady-state fit.
>
> Prefer **more workers** over a larger `VKS_VM_CLASS`: you cannot be sure a given VM class is
> offered in your namespace, but a node count always works. If you get this wrong the install
> proceeds for ~20 minutes and then fails at `install-tekton` — and it will report **four** timed-out
> deployments when only **one** is genuinely stuck, because the other three come up after
> `kubectl wait` gives up. Scaling afterwards is cheap (a second node went Ready in 19 s), but the
> 20 minutes are not.
>
> ⚠️ **`.status.phase == Provisioned` is NOT readiness.** A cluster reports `Provisioned` before its
> nodes join, and a real one has been observed sitting there with **zero** available nodes. Gate on
> the conditions instead, then on nodes:
>
> ```bash
> kubectl -n "$VKS_NAMESPACE" get cluster "$VKS_CLUSTER_NAME" \
>   -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
> # require ControlPlaneInitialized=True AND RemoteConnectionProbe=True, then:
> kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes
> ```

### Export its kubeconfig

```bash
vcf context use "$VKS_CONTEXT_NAME:$VKS_NAMESPACE"    # Step 3 left the context on the ArgoCD ns; switch it
vcf cluster kubeconfig get "$VKS_CLUSTER_NAME" --export-file ./secrets/vks.kubeconfig
kubectl --kubeconfig ./secrets/vks.kubeconfig get nodes -o wide
```

> ⚠️ **UNVERIFIED-COMMAND** — `vcf cluster kubeconfig get` is the doc-inferred 9.1 form; confirm with
> `--help` if it errors. Also: **`-n` means different things across `vcf` subcommands** (`vcf package`
> → a guest-cluster namespace; `vcf addon` → the vSphere Namespace) — never copy one's `-n` into another.

**Result:** nodes listed.

> ✅ **PREFER the Supervisor secret — it is self-contained and needs no `vcf` CLI:**
>
> **`make vks-cluster-status` already does this for you** — it writes
> `./secrets/<cluster>.kubeconfig` from that Secret every time it runs. By hand:
>
> ```bash
> # NOTE the --kubeconfig and the temp file. Both are load-bearing, and the obvious one-liner
> # (ambient kubectl, redirecting straight onto ./secrets/vks.kubeconfig) DESTROYS the kubeconfig
> # it is meant to produce: the Secret lives on the SUPERVISOR while .env points KUBECONFIG at the
> # GUEST, and the shell TRUNCATES a redirect target before kubectl ever runs. You end up with
> # neither the old file nor a new one, and secrets/ is gitignored, so it is unrecoverable.
> t=$(mktemp)
> kubectl --kubeconfig ./secrets/supervisor.kubeconfig \
>   -n "$VKS_NAMESPACE" get secret "${VKS_CLUSTER_NAME}-kubeconfig" \
>   -o jsonpath='{.data.value}' | base64 -d > "$t"
> [ -s "$t" ] || { rm -f "$t"; echo "extracted nothing — NOT overwriting your kubeconfig"; false; }
> chmod 0600 "$t" && mv "$t" "./secrets/${VKS_CLUSTER_NAME}.kubeconfig"   # 0600: it is a CREDENTIAL
> ```
>
> MEASURED 2026-08-04: this yields a kubeconfig with **inline `certificate-authority-data`** and
> **zero** file references, so it can be copied anywhere. It is also minted fresh by CAPI, so it
> cannot be a stale on-disk copy.
>
> ⚠️ **A kubeconfig written by the login flow is NOT portable by copying.** That one references its
> CAs by **relative** path (measured: `certificate-authority: vmca-root.pem` and `ca-lab-gc1.pem`),
> which `kubectl` resolves against **the kubeconfig's own directory**. Copy it without those PEMs
> beside it and every command fails with
> `unable to read certificate-authority …/ca-<cluster>.pem: no such file or directory` — which reads
> like a broken cluster, not a missing file. Carry the PEMs with it, or flatten it
> (`kubectl config view --flatten --raw`). The secret above avoids the problem entirely.

**→ `.env`:**

| key | value |
|---|---|
| `KUBECONFIG` | `./secrets/vks.kubeconfig` |
| `VKS_CONTEXT` | the context name **as it appears inside that kubeconfig** — check with `kubectl --kubeconfig ./secrets/vks.kubeconfig config get-contexts -o name`. ⚠️ The built-in default is `vks-workload`, which **nothing creates**; leave it wrong and `make vks-login` warns `context 'vks-workload' not found … using current context` and silently proceeds against whatever that is. |
| `VKS_AUTH_METHOD` | `kubeconfig` — the pipeline runs against the kubeconfig you just exported |
| `GITEA_ADMIN_PASSWORD` | you choose it — Gitea is ours to install |

## 5. Preflight — will this cluster accept our install?

**Goal:** catch the four things that each kill the run *after* a 20-minute mirror.

```bash
make vks-login       # validates KUBECONFIG + context
make lab-preflight   # CRD-create · a DEFAULT StorageClass · a working LoadBalancer provider
make psa-check       # (see below)
```

**Result:** `lab-preflight` → **`LAB PREFLIGHT OK`**.

`psa-check` gives one of two answers, and **both are correct here**:

| you see | when | meaning |
|---|---|---|
| **`PSA UNPROVEN`** | a bare cluster — none of our namespaces exist yet | the expected answer, **not** a pass |
| **`PSA OK — … (N of ours measured)`** | the cluster already runs something we label (e.g. a pre-installed Istio) | also fine — it measured what was there |

> ⚠️ **`PSA OK` at this step does NOT mean our namespaces are proven.** It means every namespace
> *we* create that currently exists is labelled correctly — which on a bare cluster is none, and on
> a cluster with Istio already installed may be one. The real proof is after `make platform`
> (Step 9), where `psa-check` is wired into `make preflight`.
>
> **PSA.** VKS enforces the `restricted` Pod Security Standard by default (VKr v1.26+), which rejects
> our Kaniko build pods unless their namespaces are labelled `baseline`. Our installers apply the
> measured labels.
>
> *Measured 2026-08-04 on a VCF 9.1 Supervisor with Istio pre-installed: `PSA OK … (1 of ours
> measured)`, listing `istio-system` as `privileged` with its per-pod reasons. An earlier revision
> of this doc promised only `PSA UNPROVEN`, which is right for a bare cluster and wrong for a real one.*

## 6. Harbor's CA

**Goal:** Harbor is self-signed; `crane` (jump box) and Kaniko (in-cluster) must trust it.

```bash
# Ask whoever operates Harbor for the CA's SHA-256 first — by a channel that is NOT this
# connection. Without it this is trust-on-first-use, and it says so.
make fetch-harbor-ca HARBOR_CA_SHA256='<digest>'   # HARBOR_URL → HARBOR_CA_FILE
```

**Result:** `$HARBOR_CA_FILE` exists, is world-readable (`0644`), and its SHA-256 is printed and
matched against your digest. `make mirror` and `make platform` then wire it into `SSL_CERT_FILE` and
the in-cluster `harbor-ca` ConfigMap for you. (Publicly-trusted cert? Leave `HARBOR_CA_FILE` empty.)

> 🔴 **The digest is the only thing that authenticates anything here.** This command takes the CA off
> the very connection the CA is meant to protect, and an interceptor's chain is self-consistent **by
> construction** — so "the CA validates the leaf" is a check on our own extraction, not on who you
> are talking to. What that connection then carries is not just images: your Harbor **admin
> credential** is submitted over it, and the robot account in Step 7 is minted on it.
>
> With `HARBOR_CA_SHA256` set it compares and refuses on a mismatch. Without it:
>
> | | |
> |---|---|
> | when **stdin** is a terminal | it prints the digest, tells you it is not authenticated, and **asks** |
> | when stdin is **not** a terminal — cron, CI, `< /dev/null` | it **refuses** rather than pin whatever answered |
> | on any refusal, including a **mismatched** pin | **`$HARBOR_CA_FILE` is not touched** — a refusal writes nothing and destroys nothing, so an anchor you already had survives |
>
> ⚠️ **`>log` and `| tee` do NOT make it unattended.** The check is on **stdin**; those redirect
> stdout. Run from your shell with either and it still prompts — and, because the question goes to
> stderr, you will see it. Only removing the terminal from *stdin* (`< /dev/null`, cron, a CI
> runner) reaches the refusing path.
>
> Set it per run (`make fetch-harbor-ca HARBOR_CA_SHA256=<digest>`) or in `.env`; both reach the
> script. It is left **commented** in `.env.example` on purpose — an uncommented value there would
> be sourced *after* your command line and would clobber the per-run form.
>
> ⚠️ **This only works if your Harbor SERVES its issuer.** A Harbor installed as a **Supervisor
> Service** does not — MEASURED 2026-08-04: it presents **one** certificate (`subject=CN = harbor`,
> `issuer=CN = Harbor CA`, `Verify return code: 21`). Its CA is simply not on the wire, so it cannot
> be fetched from there by any tool. `fetch-harbor-ca` detects exactly this — the message names the
> host and says it `presents ONE certificate` that is not self-signed — and refuses, writing nothing.
> It then names the routes below, cheapest first.
>
> **That refusal is correct, not a bug** — deriving a "CA" from a leaf would install a trust anchor
> that verifies nothing. Get the CA out-of-band instead (either route below), then set
> `HARBOR_CA_FILE` and continue; everything downstream works unchanged.

**Getting the CA when it is not on the wire** — route B is automated:

```bash
make harbor-ca-from-cluster   # scenario-1 §6 route B, with the four safety properties below baked in
```

⚠️ It costs the **admin-level grant** described in route B (the Secret also carries the CA's private
signing key). Route A — the Harbor UI download — needs only a Harbor login and no Kubernetes access;
prefer it when you can. Either way, `make env-validate` afterwards is what proves the anchor
actually verifies the live endpoint.

Or by hand — pick either:

```bash
# A. From the UI — PREFER THIS. Harbor → project → Registry Certificate downloads ca.crt.
#    It needs only a Harbor login: NO Kubernetes access, and no admin grant (see B).
#    Strip any trailing <CR> — it breaks the PEM parse.

# B. From the cluster (scriptable) — but read the grant it costs, first.
#
#    🔴 `get secret harbor-ca-key-pair` ALSO RETURNS THE CA's PRIVATE SIGNING KEY.
#       MEASURED: it is type kubernetes.io/tls with keys ca.crt / tls.crt / tls.key, and
#       tls.crt is byte-identical to ca.crt (self-signed, CA:TRUE). Kubernetes RBAC has no
#       field-level read, so whoever can run this can MINT a certificate for anything that
#       every HARBOR_CA_FILE consumer (crane, podman, Kaniko) trusts. That is an admin-level
#       grant, not a read-only one. Route A above needs none of it.
#
#    ⚠️ Three things below are load-bearing; the naive one-liner gets all three wrong and
#       TRUNCATES A WORKING CA TO 0 BYTES AT rc=0 (measured, twice — see the notes).
t=$(mktemp)
ns=$(kubectl --kubeconfig ./secrets/supervisor.kubeconfig \
       get ns -l appplatform.vmware.com/serviceId=harbor -o name)   # 1. authoritative selector,
[ "$(printf '%s\n' "$ns" | wc -l)" = 1 ] || { echo "expected exactly ONE harbor namespace, got: $ns"; }
kubectl --kubeconfig ./secrets/supervisor.kubeconfig \
        -n "${ns#namespace/}" get secret harbor-ca-key-pair \
        -o jsonpath='{.data.ca\.crt}' | base64 -d > "$t" \
  && [ -s "$t" ] \
  && openssl x509 -in "$t" -noout -subject >/dev/null \
  && chmod 0644 "$t" \
  && mv "$t" "$HARBOR_CA_FILE"                                      # 3. validate, set mode, THEN move
rm -f "$t"
#    1. `kubectl get ns | grep harbor` is enumerated-list rot: 0 matches yields an EMPTY
#       namespace and kubectl silently runs against `default`; 2+ matches (a tenant namespace
#       called my-harbor-apps, a second Harbor) feeds it a multi-line value. Neither is
#       detected. The label is authoritative and returns exactly one.
#    2. `--kubeconfig ./secrets/supervisor.kubeconfig` is REQUIRED. Harbor runs on the
#       SUPERVISOR, but .env sets KUBECONFIG to the GUEST cluster, which has no harbor
#       namespace at all. MEASURED: ambient kubectl gives "Error from server (NotFound)"
#       with rc=0, so the redirect below would truncate your working CA to 0 bytes.
#    3. NEVER `> "$HARBOR_CA_FILE"` directly. A jsonpath miss on an EXISTING secret yields
#       rc=0 and empty output; `base64 -d` on empty yields rc=0 and a 0-byte file; the whole
#       pipeline under `set -euo pipefail` is rc=0. So a renamed key, a different Harbor
#       version, or the wrong cluster REPLACES a good CA and reports success.
#    4. `chmod 0644` BEFORE the mv, and it is not cosmetic. `mktemp` creates the file 0600 and
#       `mv` PRESERVES the mode, so without it this recipe deterministically produces a 0600
#       trust anchor — while everything else in this repo that writes a CA makes it 0644,
#       because a CA is PUBLIC material and every consumer must be able to read it whatever uid
#       it runs as. Do the chmod on the TEMP file: that keeps the final step an atomic rename,
#       so a half-written CA is never visible at $HARBOR_CA_FILE. (A 0600 anchor fails with an
#       error naming TRUST, not permissions, which is why it is worth getting right up front.)

# VERIFY it either way — a file that exists is not a trust anchor that works:
openssl s_client -connect "$HARBOR_URL:443" -servername "$HARBOR_URL" </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > /tmp/leaf.pem
openssl verify -CAfile "$HARBOR_CA_FILE" /tmp/leaf.pem      # must print: OK
curl -sS --cacert "$HARBOR_CA_FILE" -o /dev/null -w '%{http_code}\n' \
  "https://$HARBOR_URL/api/v2.0/systeminfo"                 # must print: 200
```

*Measured 2026-08-04: route A yielded a self-signed `CN = Harbor CA`; `openssl verify` → `OK` and
the `curl` → `200`.*

<details><summary><b>If Harbor is on a DIFFERENT Supervisor, or its project is PRIVATE</b></summary>

Same-Supervisor guest clusters auto-trust Harbor's cert. Otherwise add the CA to the Cluster spec
`trust.additionalTrustedCAs`, **double**-base64 encoded: `base64 -w0 harbor-ca.crt | base64 -w0`
([William Lam](https://williamlam.com/2024/06/using-a-vsphere-kubernetes-service-vks-cluster-with-a-private-container-registry.html); verify on your 9.1 lab — not reproducible on KinD).
</details>

## 7. A least-privilege Harbor robot (recommended)

**Goal:** CI pushes with a scoped credential instead of `admin`.

```bash
make harbor-robot     # → secrets/harbor-robot.env (0600, never printed); copy its two lines into .env
```

**Result:** a `robot$vks-cicd` account scoped to the `cicd` + `apps` projects. `make harbor-robot`
(and `make mirror`) create those projects if you may — public by default (`HARBOR_PUBLIC_PROJECTS=false`
for private). `make gitops` creates the `harbor-pull` secret in each app namespace either way, and
`make check-pull-secret-alignment` gates that the Deployment asks for the secret the flow creates.

## 8. The Supervisor kubeconfig ArgoCD needs

**Goal:** `make gitops` talks to **both** clusters — ArgoCD on the Supervisor, your app in the guest.
Step 4 gave you the guest one; this gives you the Supervisor one.

**→ `.env` FIRST** (both commands below consume these):

| key | value |
|---|---|
| `ARGOCD_KUBECONFIG` | `./secrets/argocd.kubeconfig` — where `fetch-argocd-kubeconfig` writes; `make gitops` reads it. **Unset, it defaults to the *guest* kubeconfig → `gitops` deploys onto the Supervisor.** |
| `VKS_INSECURE_SKIP_TLS_VERIFY` | `true` — or set `VKS_CA_CERT_FILE=./secrets/supervisor-ca.crt` (**preferred**; it is the Supervisor's VMCA root). `fetch-argocd-kubeconfig` **dies** without one. ⚠️ They are an **enforced exclusive pair** — setting both fails with `[x] : … [ca-certificate insecure-skip-tls-verify] were all set`. |
| `ARGOCD_NAMESPACE` | **the vSphere Namespace your ArgoCD INSTANCE runs in — DISCOVER it, do not assume.** The default (`argocd`) and §3's suggested `argocd-instance-1` are both just examples; an instance may equally live in your *workload* namespace. Find it with `kubectl get argocd -A` (measured on one 9.1 lab: `lab/argocd-1`, i.e. `ARGOCD_NAMESPACE=lab`). Get this wrong and `fetch-argocd-kubeconfig` writes the file, then fails with `argocd-server is NOT visible in ns/<x>`. |

```bash
make fetch-argocd-kubeconfig    # interactive: prompts for your password
make argocd-preflight           # CLI vs SERVER versions + can ArgoCD actually deploy to your cluster?
```

**Result:** `$ARGOCD_KUBECONFIG` is written, and `argocd-preflight` prints **`PREFLIGHT OK`** and
**`ArgoCD is OFF-CLUSTER (the real-lab shape)`** — the line that proves the two-cluster topology was
detected.

## 9. Validate `.env`, then install

**Goal:** catch a wrong value in seconds, not 20 minutes into the mirror.

```bash
make env-populate   # mint the Gitea secret; discover any endpoint you left blank
make env-check      # presence gate — every required value set? (fast, no network)
make env-validate   # validity gate — does KUBECONFIG reach the cluster, does Harbor authenticate?
```

**Result:** `env-check` → all required present; `env-validate` → Harbor reachable **and authenticated
over HTTPS with your CA** (the honest check on Step 6 — a bad CA fails here, not inside Kaniko later).

> 🔴 **Coming back to a REBUILT lab? Several files under `secrets/` are now silently invalid.** A
> destroyed-and-rebuilt Supervisor mints new certificate authorities, and nothing in this repo
> re-fetches them for you. The files stay exactly where they were, so everything *looks* configured.
> At minimum:
>
> | file | what a rebuild did to it | fix |
> |---|---|---|
> | `secrets/harbor-ca.crt` | Harbor minted a new CA | **Step 6's out-of-band routes** — for a Supervisor-Service Harbor `make fetch-harbor-ca` correctly *refuses* (its CA is not on the wire) |
> | `secrets/supervisor-ca.crt` | the Supervisor minted a new VMCA | re-obtain it (Step 8) |
> | `secrets/vks.kubeconfig` | the guest cluster's embedded CA belongs to the destroyed cluster — and the **address still matches**, because the LB IPs repeat across a rebuild | re-export it (Step 4) |
> | `secrets/supervisor.kubeconfig` · `secrets/argocd.kubeconfig` | embedded CA + credential from the destroyed Supervisor | re-run Steps 3 and 8 |
> | `secrets/argocd-ca.crt` | the ArgoCD server's cert was reissued | `make fetch-argocd-ca` |
> | `secrets/harbor-robot.env` | the robot was minted against the destroyed Harbor | `make harbor-robot` (Step 7) |
>
> The reason to run `env-validate` *before* the install is that each of these otherwise surfaces as
> `x509: certificate signed by unknown authority` — a message naming TLS, which sends you hunting a
> certificate or network fault when the cause is simply that the lab was rebuilt. `env-validate`
> separates the cases and names the remedy: a **stale** anchor (re-fetch), an **unreachable**
> endpoint (retry — this is *not* evidence the anchor is bad), the **right anchor with the wrong
> name** in the certificate (do **not** re-fetch; fix `HARBOR_URL` or reissue with the right SAN),
> an endpoint serving **no TLS at all**, and an **empty** CA file. Also re-check `~/.config/vcf/`
> (Step 3): the `vcf` CLI's contexts live outside this repo and survive every teardown.

**One fork — can this jump box reach BOTH the internet and Harbor?** `make install-all` runs
`make mirror`, which pulls from the internet and pushes to Harbor in one command.

| your jump box | what you run |
|---|---|
| reaches the internet **and** Harbor (**dual-homed**) | `make install-all` below |
| reaches the **internet only** | **[the sneakernet flow](sneakernet.md)** — two boxes; it replaces `install-all`. Do not come back here. |

> **Lab has internet everywhere (guest cluster too)?** Scenario 1 runs **unchanged** — Harbor is
> still the pipeline's registry and the mirror still runs; the air gap is simply **not exercised**.
> `make verify-gateway-image` (Step 11) still proves the mirror was actually used.
> *(inferred-from-code; not lab-verified.)*

```bash
make install-all   # preflight → mirror → mirror-verify → builder-image → vks-login → platform → gitops
make psa-check     # NOW it measures — expect `PSA OK — … (N measured)`, not `PSA UNPROVEN`
make verify        # push a marked change → Tekton → Harbor → ArgoCD → the live app serves it
```

**Result:** `make verify` exits **0** — the app serves the new version. `make gitops` **registers
your guest cluster** as an ArgoCD destination and points the `Application` at it; it never installs a
second ArgoCD and never deploys onto the Supervisor.

> **Real-lab caveats.** If ArgoCD reaches your guest by a VIP that differs from your kubeconfig's
> server URL, `make gitops` stops rather than guess — set `ARGOCD_DEST_CLUSTER_NAME=<the name ArgoCD
> registered>` and re-run. And run `make mirror` **alone** (it mutates a shared cluster + registry, so
> parallel work makes any failure unattributable); it ends in `mirror-verify` — an unverified push is
> not a mirror.

## 10. Access the UIs

**Goal:** every URL and login for this context, without re-typing a value you already set.

```bash
make creds-show
```

**Result:** a table of Harbor, ArgoCD, Gitea, the Tekton dashboard **and one row per app** (generated
from `apps/registry.tsv`, so it lists every app the repo ships), plus the exact `/etc/hosts` line for
the ingress hosts. Prefer port-forward?

```bash
kubectl -n gitea port-forward svc/gitea-http 3000:3000
kubectl -n <app> port-forward svc/<app> 18080:80     # <app>: any name in apps/registry.tsv
```

## 11. Ingress (optional)

**Goal:** reach Gitea, Tekton and the app at `*.vks.local` instead of port-forwarding.

You own this cluster, so unless you installed Istio yourself it has none (Istio is *available* as a
VKS package — available is not installed). **Ask the cluster:**

```bash
make istio-preflight     # read-only; on a fresh cluster: "NO Istio detected → INSTALL it"
```

| It says | You run |
|---|---|
| **NO Istio detected** (normal) | `make install-ingress` — installs Istio (control plane + one gateway LB) from **your Harbor**, and `make verify-gateway-image` proves it by reading each running Istio image. Worth it on a dual-homed box, where a silently-ignored `--set global.hub` (helm accepts an unknown key, rc=0) would otherwise leave the air gap unproven. `INGRESS_CONTROLLER=traefik` for a lighter option. |
| **Istio already here** | `make install-ingress INGRESS_CONTROLLER=istio-existing` — installs nothing, attaches routes only. |

Add the printed `INGRESS_LB_IP` to `/etc/hosts` (see [Access the UIs](access-uis.md)).
`make install-ingress` is a **demo ingress**, not the Broadcom-supported mesh, and needs **no internet
once `make mirror` has run** — `mirror-pull` carries the Istio charts into `bundle/charts`:

| `bundle/charts` state | behaviour |
|---|---|
| charts carried | installs from them, **no network** |
| bundle exists, no charts | **dies** — re-cut with `make mirror-pull && make bundle` (it will not silently reach the internet) |
| no bundle | fetches from `istio-release.storage.googleapis.com` (needs internet, says so) |

<details><summary><b>Alternative: install the VKS Istio package, then attach (VKS-faithful — NOT validated by us)</b></summary>

Transcribed from Broadcom's **9.0** docs — **never run verbatim on a 9.1 lab.** Grade:
**9.0-doc (inferred for 9.1)** — the package-reference and `vcf`-CLI pages resolve only to the
`/9-0/` tree, so this is 9.0 content being assumed to hold at 9.1. Two CLI surfaces exist; check
`vcf addon available list` first.

- **Legacy package CLI:** `vcf package repository add …` → `vcf package available get
  istio.kubernetes.vmware.com -n tkg-system` → `… --default-values-file-output istio-data-values.yaml`
  → `kubectl create ns istio-installed` → `vcf package install istio -p istio.kubernetes.vmware.com -v
  <ver> --values-file istio-data-values.yaml -n istio-installed`. Here `-n` = a **guest-cluster** ns.
- **Add-on CLI** (9.1 / VKS 3.7+): `vcf addon install create istio --cluster-name <cluster> …`. Here
  `-n` = the **vSphere Namespace** — opposite meaning; do not copy the flag across.

⚠️ **UNVERIFIED and load-bearing:** the package's own istiod/proxy images come from Broadcom's
registry, which an air-gapped guest cannot reach; this repo does not mirror or repoint them. The
package's shared ingress gateway is **off by default** (correct — `istio-existing` routes with the
Kubernetes Gateway API and lets Istio provision the proxy + LB), which needs the Gateway API CRDs
present (`kubectl get crd httproutes.gateway.networking.k8s.io`). See
[the decision record](decisions/istio-via-vks-package.md) for why we do not install this way.
</details>

## 12. Removing it again

**Goal:** put the lab back. Until now this runbook had no teardown at all — `make clean` removes
only local build output, and `make kind-down` is KinD-only and deliberately refuses to touch
real-lab state.

```bash
make lab-down CONFIRM=<your VKS_CLUSTER_NAME>    # the cluster name is the confirmation
```

**What it removes, and what it will not.** Deleting the guest cluster removes everything *inside*
it in one step, so `lab-down` does **not** walk the guest cluster's namespaces or CRDs — that is
pure risk for no benefit, and on a mesh you attached to (`istio-existing`) deleting `istio-system`
would remove the platform team's mesh. What survives a cluster deletion is the half that lands on
**shared** infrastructure, and that is what it targets: your ArgoCD Applications, the repo
credential, the guest-cluster registration, and then the Cluster CR itself, in that order —
Applications first, because an Application's `resources-finalizer` can only complete while ArgoCD
can still reach the destination.

> 🔴 **It deletes ONLY objects carrying our ownership label, and REFUSES anything that lacks it.**
> That is not fastidiousness. On a real lab `ARGOCD_NAMESPACE` is frequently the *same* namespace as
> `VKS_NAMESPACE` — measured on one 9.1 lab, it held the ArgoCD instance itself, the lab's own
> cluster, a **foreign Application**, and a cluster Secret bearing a *different tool's* ownership
> label. Our Applications are named from `apps/registry.tsv` (`javawebapp`, `gowebapp`) and carry
> `prune: true`, so a delete-by-name teardown could **cascade-delete another tenant's running
> workloads**. Anything unlabelled is listed and left alone.
>
> **Harbor is deliberately manual.** Harbor refuses to delete a project that still holds
> repositories, and that refusal is the only thing standing between a stale `HARBOR_*_PROJECT` and
> someone else's images. `lab-down` prints the exact API calls rather than forcing them.
>
> It ends by printing **what it deliberately left alone** — a half-done teardown you can see beats a
> clean-looking one that quietly skipped things.

## Measured timings (§4b onward)

MEASURED 2026-08-08 against a real VCF 9.1 lab. **§1–§3 are not timed here** — the jump box, and
Harbor and ArgoCD as Supervisor Services, are largely browser and one-time platform work; do not
budget the whole runbook from this table.

⚠️ **WHAT THESE NUMBERS ARE OF.** The mirror ran with a **WARM** cache (34 of 44 images already in
`bundle/images`) against a Harbor that **already held those images**, so `crane` skipped most blob
uploads. A first run on an empty Harbor with a cold cache is bounded by your bandwidth, not by this
box, and is not represented here at all.

Hardware: i9-14900KF (24C/32T), 188 GiB, NVMe — **running the nested ESXi lab on the same box**, so
every number is under self-contention. Guest: 1 CP + 2 workers of `best-effort-small` on a single
nested host already running the Supervisor and another 3-VM cluster.

| Step | Command | Measured | |
|---|---|---|---|
| §5 | `make preflight` | 2 s | |
| §9 | `make env-check`, `make env-validate` | <1 s each | |
| §4b | `make vks-cluster-create` | <1 s | it APPLIES and returns; provisioning is asynchronous |
| §4b | cluster → all 3 nodes `Ready` | **3 m 45 s** | budget this, not the row above |
| §6 | `make harbor-ca-from-cluster` | <1 s | |
| §9 | `make install-all` | **10 m 26 s** | WARM — see above |
| ↳ | `mirror-pull` | 22 s | WARM: 34/44 cache-skipped |
| ↳ | `mirror-push` | 2 m 38 s | WARM: Harbor already held most blobs |
| ↳ | `mirror-verify` | 5 m 46 s | re-fetches every blob |
| ↳ | `builder-image` + `platform` + `gitops` | ≈1 m 40 s | |
| §9 | `make psa-check` | 1 s | the `ci` row measures; the gateway row is absent until §11 |
| §9 | `make verify` | **3 m 6 s** | sum of 2 apps, sequential; the Java Kaniko build dominates |
| §12 | `make lab-down` | 1 m 12 s | |
| — | `make static-check` | 55–67 s | composite code gate; warm `~/.m2` + warm trivy DB |

`mirror-verify` is the one row a warmer run would **not** improve — it re-fetches every blob rather
than skipping. It still scales with the image count (44 here) and your Harbor's throughput, and
`MIRROR_VERIFY_FAST=1` trades layer verification for speed.

Two rows carry warmth this table cannot see: the cluster's 3 m 45 s assumes the Supervisor already
has the TKr image cached (a first-ever cluster from a cold content library is a different number),
and `static-check` assumes a populated `~/.m2` and a current trivy DB.

### A SECOND full run, same box, same day — where it differed and why

The walk was run end to end **twice**. Quoting only one set of numbers would present a single
operating point as "the" figure, and the two runs disagree in *both* directions:

| | run 1 | run 2 | why |
|---|---|---|---|
| cluster → all nodes `Ready` | 3 m 45 s | **≈ 6 m** | run 2 provisioned **beside** the lab's own 3-VM cluster; more contention |
| `make install-all` | 10 m 26 s | **8 m 14 s** | Harbor was warmer still — fewer blobs moved |
| `make verify` (2 apps) | 3 m 6 s | **3 m 27 s** | |
| `make lab-down` | 1 m 12 s | **1 m 12 s** | identical |

So **provisioning is the variable row, not the mirror** — the opposite of the intuition, because the
mirror gets monotonically warmer while the host gets busier. Budget the cluster generously.

### ⚠️ Do NOT recreate a guest cluster under a NAME YOU JUST DELETED

MEASURED across four incarnations on this lab: a cluster recreated under a recently-deleted name
advertises the **previous** incarnation's control-plane VIP — `spec.controlPlaneEndpoint.host` lags
by exactly one allocation — and then **never converges**, because CAPI dials an address nothing
serves. It does not self-heal.

| | advertised | its load balancer |
|---|---|---|
| 1st (fresh lab) | .134 | **.134** — agreed, Ready in 3 m 45 s |
| 2nd, same name | .134 | .136 — never converged in 25 min |
| 3rd, same name | .136 | .137 — never converged |
| 4th, same name | .137 | .138 — predicted from the pattern, then confirmed |
| **5th, a NEW name** | **.139** | **.139** — agreed, Ready, walk completed |

`make vks-cluster-status` now reports this directly (`endpoint : *** DIVERGENT ***`, naming both
addresses) instead of leaving you to watch conditions that cannot go True. If you hit it, **use a
different cluster name** — that is the remedy that was measured to work.

## Preconditions, in one place

- **cluster-admin** on the guest cluster (we create namespaces and install Tekton CRDs).
- A **default StorageClass** (Gitea's PVC) and a working **LoadBalancer** provider.
- **Network reach from the jump box:** the internet, the **Supervisor** API, the **guest** API, and **Harbor**.
- **ArgoCD must be able to clone Gitea.** ArgoCD is on the Supervisor, so `gitea-http.gitea.svc` does
  not resolve there — Gitea gets its **own LoadBalancer** and `make install-gitea` publishes
  `GITEA_ARGOCD_URL`. The ingress hostname is not usable for this. `make gitops` refuses a repoURL
  ArgoCD cannot reach.
- **No stale state overlay** at the start (Step 1).

---

[← back to the README](../README.md)
