# ArgoCD on VKS

**Where it runs:** the **Supervisor** — in its own vSphere Namespace (e.g. `argocd-instance-1`).
**Who installs it:** the platform team, as a **Supervisor Service** (an operator + an ArgoCD instance CR).
**What we do:** **discover** it, and — because it is in a *different cluster from your workload* —
**register the guest cluster as a destination** so the app actually lands in the guest.

> **The trap this page exists for.** An ArgoCD `Application` whose destination is
> `https://kubernetes.default.svc` deploys into **the cluster ArgoCD itself runs in**. On VKS that
> is the **Supervisor**, *not* your workload cluster. The sync goes **green** and the workload never
> appears where you expect. `make argocd-preflight` reports `TOPOLOGY OK` / `TOPOLOGY MISMATCH`
> for exactly this.

## What Broadcom ships

| Fact | Value | Confidence |
|---|---|---|
| Packaging | **Supervisor Service** (operator + an ArgoCD instance CR), on the **Supervisor** | 9.0-doc (inferred for 9.1) |
| Namespace | a vSphere Namespace, e.g. `argocd-instance-1` | 9.0-doc |
| Service | `argocd-server` (LoadBalancer, self-signed TLS) | 9.0-doc |
| **Server version** | pinned by the operator's CR at **`2.14.15+vmware.1-vks.1`** (a **2.x** line) | 9.0-doc — re-check on a lab |
| **CLI version** | the lab's `argocd` binary reported **`v3.0.19+d67e6eb90-vcf`** (a **3.x** line) | lab-verified |

> **CLI ≠ server.** Those last two rows are *different facts* and were confounded once already. A
> client/server tool's CLI version tells you **nothing** about the server. Verify each against its
> own artifact: `argocd version --client` for the CLI; the running **image tag**
> (`kubectl -n <ns> get deploy argocd-server -o jsonpath='{...containers[0].image}'`) for the server.
> `make argocd-preflight` prints **both**, plus `kubectl explain argocd.spec.version`.

## Registering the guest cluster (the cross-cluster case)

### Is it needed?

Only when ArgoCD runs **somewhere else** than your workload — i.e. the normal real-lab case
(ArgoCD on the Supervisor, app in the guest). On the KinD stand-in they are the same cluster, so
registration is skipped automatically.

### It is ADMIN-only — a tenant cannot self-service it

| Why | Confidence |
|---|---|
| ArgoCD's `clusters` is a **global** RBAC resource — only `applications`/`applicationsets`/`logs`/`exec` are grantable through a tenant AppProject role | research (adversarially verified) |
| Registration mints a **cluster-admin** ServiceAccount on the guest; Kubernetes privilege-escalation prevention only permits a caller who *already* holds cluster-admin there | KinD-verified |

A pure VKS tenant therefore **requests** registration from the platform team.

### What it actually does — all declarative `kubectl`, no `argocd` CLI

`scripts/71-argocd-register-guest.sh`:

1. **On the GUEST cluster** — create the identity ArgoCD will act through:

   ```yaml
   kind: ServiceAccount        # argocd-manager, in kube-system
   ---
   kind: ClusterRoleBinding    # argocd-manager -> ClusterRole/cluster-admin
   ---
   kind: Secret                # argocd-manager-token
     annotations: { kubernetes.io/service-account.name: argocd-manager }
   type: kubernetes.io/service-account-token     # <-- the load-bearing line: a NON-EXPIRING token
   ```

2. **Read back** the bearer token + cluster CA from that Secret (once the token controller populates it).

3. **On the ARGOCD cluster** — write the `Cluster` Secret, which is the artifact ArgoCD consumes
   (it discovers destinations by this label):

   ```yaml
   kind: Secret
   metadata:
     labels: { argocd.argoproj.io/secret-type: cluster }
   stringData:
     name:   "<dest-name>"
     server: "https://<guest-api>"
     config: '{"bearerToken":"<token>","tlsClientConfig":{"caData":"<ca>"}}'
   ```

4. **Publish `ARGOCD_DEST_SERVER`**, so the `Application` targets the guest instead of in-cluster.

**Why not `argocd cluster add`?** It does exactly the same thing internally — but it stores an
**expiring** credential when the source kubeconfig authenticates with an **x509 client cert**
([argo-cd#13175](https://github.com/argoproj/argo-cd/issues/13175)), which is precisely the shape of
a `vcf cluster kubeconfig get` kubeconfig. The registered cluster then silently flips to `Unknown`
later. Creating the `type: kubernetes.io/service-account-token` Secret explicitly sidesteps that.
Secondary benefit: the token never touches `argv` (it goes in over stdin), and the `argocd` CLI is
not required at all.

It **never** installs a second ArgoCD in the guest.

### How you make it happen

Set this in `.env` (all documented in `.env.example`):

```bash
ARGOCD_KUBECONFIG=./secrets/argocd.kubeconfig   # the cluster ArgoCD RUNS IN (the Supervisor).
                                                # Leave UNSET when ArgoCD and the workload share a
                                                # cluster (KinD) -> registration is skipped.
# optional:
GUEST_API_SERVER=https://<guest-api-vip>:6443   # only if the guest API address in your kubeconfig
                                                # is NOT routable FROM the ArgoCD cluster
ARGOCD_DEST_CLUSTER_NAME=vks-guest              # name the destination appears under
```

> **Where does `ARGOCD_KUBECONFIG` come from?** `make fetch-argocd-kubeconfig` — and it is worth
> understanding why it is a *Supervisor* kubeconfig, not a workload one.
>
> | | |
> |---|---|
> | **Two-KinD e2e** | produced automatically (`kind get kubeconfig --name <hub>`) — no manual step |
> | **`make vks-login`** | the **guest/workload** kubeconfig (`vcf cluster kubeconfig get`) → `KUBECONFIG` |
> | **`make fetch-argocd-kubeconfig`** | the **Supervisor** kubeconfig (where ArgoCD actually runs) → `ARGOCD_KUBECONFIG` |
>
> Per Broadcom (*Connect to the Supervisor as a vCenter SSO User* + *VCF CLI Context, Architecture,
> and Configuration*): `vcf context create --endpoint https://<SUPERVISOR> --username <u>@<domain>
> --ca-certificate <ca>` creates a **Supervisor** context — *"you can view the cluster context in the
> file `.kube/config` in the user's home directory"*, and *"the VCF CLI respects the `KUBECONFIG`
> environment variable for writing to alternate locations"*. So the target points `KUBECONFIG` at
> `ARGOCD_KUBECONFIG` while creating the context, and the Supervisor kubeconfig lands in its own file
> instead of polluting `~/.kube/config`. Creating a Supervisor context also auto-creates the
> per-vSphere-Namespace contexts (`<ctx>` and `<ctx>:<namespace>`), so the target then selects
> `<ctx>:$ARGOCD_NAMESPACE`, and finally **proves** the kubeconfig works (`argocd-server` must be
> visible) rather than trusting that a file exists.
>
> ⚠️ **Provenance: INFERRED**, and we have never run this on a lab. The flow is also **interactive** —
> the VCF CLI prompts for the password (no documented non-interactive flag, and a password on argv is
> forbidden). Re-verify on a real 9.1 lab and upgrade this grade.
>
> **Which techdoc URLs are actually 9.1 (the earlier blanket "all 9.1 URLs redirect to 9.0" claim was
> WRONG).**
>
> - **VERIFIED 2026-07-13** (`curl -L`): the **explicit `/9-1/` URLs return HTTP 200 with NO redirect**
>   — the final URL is still `/9-1/`. So a `/9-1/` page **may be cited as 9.1**.
> - **NOT reproduced**: a prior session reported that the *older* doc-set path
>   (`vsphere-supervisor-services-and-standalone-components/…`) 301-redirects to the 9.0 tree. Probing
>   a guessed URL on that path returned **404**, not a redirect, so this half is **UNVERIFIED** — do
>   not repeat it as fact. To settle it, `curl -sSL -o /dev/null -w '%{url_effective}'` a *real* URL
>   from that doc set and see where it lands.
>
> Either way, the **version-specific pins** (the `2.14.15` server example) are **not stated by the doc
> at all** — the server version is pinned by the **operator's CR**. Only the cluster can answer it:
> `make argocd-preflight`.
>
> *(An earlier version of this page said "nothing creates this file and the command is unknown". That
> was true of the repo but false of the world: the flow is documented, and was found by actually
> searching. Recorded as a correction rather than silently fixed.)*

then run **one** target — no manual `kubectl`:

```bash
make gitops        # auto-invokes `make argocd-register-guest` when ARGOCD_KUBECONFIG is set
```

| Command | Does |
|---|---|
| `make argocd-preflight` | CLI vs **server** version, and `TOPOLOGY OK / MISMATCH` (is ArgoCD even in a position to deploy to your cluster?) |
| `make fetch-argocd-kubeconfig` | obtain the **Supervisor** kubeconfig (where ArgoCD runs) → `ARGOCD_KUBECONFIG`, and prove it reaches `argocd-server` |
| `make argocd-register-guest` | the registration above (admin-only). Auto-invoked by `make gitops`. |
| `make gitops` | register (if needed) → create/point the `Application` |
| `make fetch-argocd-ca` | fetch the self-signed server CA → `ARGOCD_CA_FILE` |
| `make argocd-password` | print the admin password (context-aware) |
| `make e2e-kind-cross-cluster` | the standing regression: **two** KinD clusters (ArgoCD in one, workload in the other) |

Verify a registration by hand:

```bash
kubectl --kubeconfig $ARGOCD_KUBECONFIG -n $ARGOCD_NAMESPACE \
  get secret -l argocd.argoproj.io/secret-type=cluster
```

## Open / unverified

- **`make fetch-argocd-kubeconfig` has never been run on a real lab** — it implements the documented
  (9.0-tree) `vcf context create` + `KUBECONFIG` flow. Confirm it, and upgrade the grade to
  lab-verified. In particular confirm: the Supervisor context really lands in `$KUBECONFIG`; the
  `<ctx>:<vsphere-namespace>` context name; and that `ARGOCD_NAMESPACE` is the vSphere Namespace the
  ArgoCD instance runs in.
- The **real-lab** run of the cross-cluster path. The mechanic is KinD-verified end-to-end (two
  clusters), but these stay lab-only: whether the guest API is **routable from the Supervisor**, the
  guest API's **TLS/CA trust** from there, and any Supervisor-side admission policy on cluster-admin RBAC.
- Exact 9.1 server version. (Not because "the 9.1 docs redirect" — the `/9-1/` pages are real 9.1; see
  the provenance note above. The server version is pinned by the **operator's CR**, not stated in the
  doc, so only the cluster can answer it: `make argocd-preflight`.)

## Sources

- Broadcom TechDocs — *Install the Argo CD Operator / Instance* (9.1 URLs → 9.0 tree)
- `argoproj/argo-cd#13175` — `cluster add` stores an expiring cert with x509 kubeconfigs
- This repo: `scripts/71-argocd-register-guest.sh`, `make e2e-kind-cross-cluster`
