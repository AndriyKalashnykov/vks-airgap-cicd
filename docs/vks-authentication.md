# VKS authentication (VCF 9 + Supervisor) — not needed for KinD

How `$KUBECONFIG` is produced. This is the same for **both** VKS scenarios — the mechanism does
not depend on whether you install Harbor/ArgoCD or inherit them, so it lives here once.

**What DOES differ per scenario is how many kubeconfigs you need**, and each scenario says so in its
own body:

| | guest / workload (`KUBECONFIG`) | ArgoCD cluster (`ARGOCD_KUBECONFIG`) |
|---|---|---|
| **Scenario 1** (you install ArgoCD) | yes — `make vks-login` | **yes** — `make fetch-argocd-kubeconfig`. ArgoCD is a Supervisor Service, so the Applications are created *there*, not in your guest cluster. |
| **Scenario 2** (tenant) | yes — `make vks-login` | only if you were granted access. Otherwise use the **tenant write path** (`ARGOCD_MECHANISM=api`), which goes through argocd-server and needs no Kubernetes RBAC in the ArgoCD namespace. |

<br>

`scripts/30-vks-login.sh` (`make vks-login`) is the single pluggable step that produces a
working `KUBECONFIG` and context; everything downstream is auth-agnostic. Select the method
with `VKS_AUTH_METHOD`:

| Method | Use it when | Inputs (`.env`) |
|--------|-------------|-----------------|
| `kubeconfig` (default) | You already have the lab's exported kubeconfig | `KUBECONFIG`, `VKS_CONTEXT` |
| `vcf` | Real VCF 9 lab, via the VCF Consumption CLI | `SUPERVISOR_HOST`, `VKS_USERNAME` (+ `VKS_SSO_DOMAIN`), `VKS_NAMESPACE`, `VKS_CLUSTER_NAME`, `VKS_CONTEXT_NAME`, `VKS_INSECURE_SKIP_TLS_VERIFY` |
| `vsphere` | Pre-9 Supervisor, via the kubectl-vsphere plugin (legacy) | `SUPERVISOR_HOST`, `VKS_NAMESPACE`, `VKS_CLUSTER_NAME`, `VKS_USERNAME`, `VKS_PASSWORD` |

**`vcf` method — the real VCF Consumption CLI flow.** `.env` inputs:

```bash
VKS_AUTH_METHOD=vcf
SUPERVISOR_HOST=<supervisor-IP-or-FQDN>   # no scheme; vCenter → Workload Management → Supervisors → Control Plane IP
VKS_USERNAME=administrator@WLD.SSO        # 'user@SSO.DOMAIN' (or set VKS_SSO_DOMAIN and give the bare user)
VKS_NAMESPACE=<vsphere-namespace>         # the <ns> in `vcf context use <name>:<ns>`
VKS_CLUSTER_NAME=<vks-cluster-name>       # the workload cluster to fetch the kubeconfig for
VKS_CONTEXT_NAME=sup66                    # the vcf context NAME you type at the create prompt
VKS_INSECURE_SKIP_TLS_VERIFY=true         # skip verifying the Supervisor's self-signed cert
```

`make vks-login` then runs (interactively — the CLI **prompts** for the context name and the
password, so no secret ever touches argv):

```bash
vcf context create --endpoint https://<SUPERVISOR_HOST> --username <user>@<SSO-DOMAIN> \
    --insecure-skip-tls-verify --auth-type basic     # enter the context name (VKS_CONTEXT_NAME) + password when prompted
vcf context use <VKS_CONTEXT_NAME>:<VKS_NAMESPACE>   # note the <ctx>:<ns> COLON form
vcf cluster kubeconfig get <VKS_CLUSTER_NAME> --export-file <KUBECONFIG>   # write the workload-cluster kubeconfig to $KUBECONFIG
```

`vcf cluster kubeconfig get` is the **primary** VKS 9 way to obtain the **workload-cluster**
kubeconfig (verify the exact 9.1 flags on your lab). The legacy `kubectl vsphere login --server
<ip> --vsphere-username <u> --tanzu-kubernetes-cluster-name <c> --tanzu-kubernetes-cluster-namespace
<ns> [--insecure-skip-tls-verify]` form (the `vsphere` method) is the **vSphere-with-Tanzu 7/8
fallback** — present only where the `vcf` CLI is unavailable.

If the workload cluster needs the kubectl-vsphere plugin, fetch it from the Supervisor:

```bash
wget --no-check-certificate https://<SUPERVISOR_HOST>/wcp/plugin/linux-amd64/vsphere-plugin.zip
```

> **Not yet lab-validated.** The `vcf` flow is written to the command **shape** verified from
> primary sources (the ogelbric/LAB VCF-CLI transcript and Broadcom's "Install the Argo CD
> Service" techdoc), but it has **not** been run end-to-end against a VKS cluster in this repo.
> The login is interactive today: no non-interactive/stdin password mechanism is confirmed for
> `vcf context create`, so `30-vks-login.sh` carries a `TODO(verify on a VKS cluster)` to
> confirm one before automating further. A password is never placed on argv either way.
> `kubeconfig` (bring the lab's exported kubeconfig) is the simplest working method.

---

[← back to the README](../README.md)
