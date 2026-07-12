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

> **⚠️ Where does `ARGOCD_KUBECONFIG` come from? Nothing in this repo creates it for a real lab —
> and the exact command is UNVERIFIED.** This is a genuine gap, stated rather than papered over:
>
> | | |
> |---|---|
> | **Two-KinD e2e** | produced automatically (`kind get kubeconfig --name <hub>`) — that path needs no manual step |
> | **`make vks-login`** | writes only the **guest/workload** kubeconfig — never a Supervisor one |
> | **Real lab** | **you must supply it.** No target, no script. |
>
> What *is* established: ArgoCD is a **Supervisor Service**, so this must be a kubeconfig for the
> **Supervisor** (with access to the vSphere Namespace the instance runs in, e.g.
> `argocd-instance-1`). The Supervisor is reached through the `vcf` CLI **context** flow —
> `vcf context create --endpoint https://$SUPERVISOR_HOST --username <u>@$VKS_SSO_DOMAIN --auth-type basic`
> then `vcf context use <ctx>:<ns>` — **not** `vcf cluster kubeconfig get`, which fetches a
> *workload-cluster* kubeconfig (that is `KUBECONFIG` / `GUEST_KUBECONFIG`, not this one).
>
> **Open:** how to export that Supervisor context to a standalone kubeconfig file. Verify on a real
> 9.1 lab, then replace the note in `.env.example` with the actual command — and add a `make` target
> if it is scriptable. *(An earlier version of this page guessed a command here. It was wrong, and is
> recorded as a correction rather than silently fixed.)*

then run **one** target — no manual `kubectl`:

```bash
make gitops        # auto-invokes `make argocd-register-guest` when ARGOCD_KUBECONFIG is set
```

| Command | Does |
|---|---|
| `make argocd-preflight` | CLI vs **server** version, and `TOPOLOGY OK / MISMATCH` (is ArgoCD even in a position to deploy to your cluster?) |
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

- **How to obtain `ARGOCD_KUBECONFIG` (the Supervisor kubeconfig) as a file on a real lab** — see the
  warning above. Nothing in the repo produces it; the exact `vcf` command is unverified. This is the
  single blocking unknown for the real-lab cross-cluster path.
- The **real-lab** run of the cross-cluster path. The mechanic is KinD-verified end-to-end (two
  clusters), but these stay lab-only: whether the guest API is **routable from the Supervisor**, the
  guest API's **TLS/CA trust** from there, and any Supervisor-side admission policy on cluster-admin RBAC.
- Exact 9.1 server version (the 9.1 docs redirect to the 9.0 tree).

## Sources

- Broadcom TechDocs — *Install the Argo CD Operator / Instance* (9.1 URLs → 9.0 tree)
- `argoproj/argo-cd#13175` — `cluster add` stores an expiring cert with x509 kubeconfigs
- This repo: `scripts/71-argocd-register-guest.sh`, `make e2e-kind-cross-cluster`
