# Detailed steps

<br>

Legend: **[offline]** verifiable without a cluster · **[cluster]** runs against live VKS.

| # | Command | Mode | What happens |
|---|---------|------|--------------|
| 1 | `make env-init` → `make env-populate` | [offline] | `env-init` copies `.env.example`→`.env` (backs up any existing); `env-populate` mints the secrets we can (Gitea/Harbor/ArgoCD) + prints the values only you can provide (Harbor/Gitea URLs, VKS auth, CA files). `make env-check` (presence) + `make env-validate` (format + connectivity) come **later** — they require the real `HARBOR_URL` + the workload kubeconfig, so the scenario runbooks run them after the cluster + Harbor exist. |
| 2 | `make deps` | [offline] | `mise install` (kubectl, helm, crane, jq, yq, …) + `scripts/00-install-prereqs.sh` (tkn, argocd). |
| 3 | `make ci` | [offline] | toolchain/image alignment + shellcheck + yamllint + hadolint + kubeconform + gitleaks + trivy fs/config + `mvn test` + docs/diagram checks. |
| 4 | `make mirror` | [cluster] | `10-mirror-pull.sh` pulls all images (+ Tekton release manifests) then `21-mirror-push.sh` pushes them into Harbor. Resumable (cache-skip) — see the note below. Then **`make mirror-verify`** confirms every image is intact in Harbor. **Sneakernet:** `make mirror-pull && make bundle`, carry the bundle, then `make bundle-load BUNDLE_TARBALL=… && make mirror-push` inside. |
| 5 | `make builder-image` | [internet] | Builds the Maven builder image with this app's deps pre-baked and pushes it to Harbor (so in-cluster CI builds offline). |
| 6 | `make vks-login` | [cluster] | `30-vks-login.sh` writes a working `$KUBECONFIG`/context (see auth note). |
| 7 | `make platform` | [cluster] | Installs Gitea (`k8s/gitea/`), seeds the two repos + webhook, installs Tekton (images remapped to Harbor), applies the pipeline/triggers. |
| 8 | `make gitops` | [cluster] | Registers the deploy repo and creates the ArgoCD `Application` (auto-sync). |
| 9 | `make verify` | [cluster] | Pushes a marked change to `javawebapp-app`, then asserts: PipelineRun succeeds → image in Harbor → deploy tag bumped → ArgoCD Synced/Healthy → the live page shows the marker. |

> **The mirror is resumable and verifiable.** If `make mirror` / `make mirror-pull` is
> interrupted (Ctrl+C, dropped connection, an upstream-CDN reset such as ghcr.io throttling),
> **just re-run it** — every digest-pinned image already fully pulled is **skipped** (a
> per-image `.mirror-ok` completeness marker, written only on a complete pull), so it
> **resumes** from where it stopped instead of re-pulling all of them. Progress shows as
> `[i/N] (elapsed …)` so you can see it moving. `MIRROR_RETRIES` (default 5) sets per-image
> retries; `MIRROR_FORCE_PULL=1` re-pulls everything. After a Renovate image bump, the old
> digest's cache dir is auto-pruned on the next pull (`MIRROR_NO_PRUNE=1` to keep it).
>
> After pushing, run **`make mirror-verify`** to confirm every image is intact in Harbor —
> `crane validate` fetches and digests each layer (catches a corrupt/incomplete blob before
> it surfaces mid-pipeline as `MANIFEST_UNKNOWN`/`BLOB_UNKNOWN`) and cross-checks Harbor's
> digest against `images.lock`. `mirror-verify` is **read-only**, so it too is safe to
> interrupt and re-run.

## Minimum `.env` you must set

Start from `make env-init` (copies `.env.example`) + `make env-populate` (generates the secrets it
can, discovers what the cluster already knows). These are the values only **you** can supply:

```bash
HARBOR_URL=harbor.<lab-host-or-ip>       # the Harbor Supervisor Service's endpoint (discover: its LB IP/FQDN)
HARBOR_USERNAME=robot$vks-cicd           # `make harbor-robot` writes this pair to secrets/harbor-robot.env
HARBOR_PASSWORD=<robot-secret>           # never committed, never on argv
HARBOR_CA_FILE=./secrets/harbor-ca.crt   # `make fetch-harbor-ca` (self-signed lab Harbor)
GITEA_HOST=gitea.<lab-host-or-ip>        # the ingress hostname; GITEA_URL DERIVES from it
GITEA_ADMIN_PASSWORD=<you choose>        # Gitea is a component WE install
ARGOCD_NAMESPACE=argocd-instance-1       # the ns YOUR ArgoCD instance runs in (KinD uses `argocd`)
KUBECONFIG=./secrets/vks.kubeconfig      # produced by `make vks-login`
```

Once you have fetched the workload kubeconfig (`make vks-login`), run `make env-check` (presence) and
`make env-validate` (format + reachability/auth) before the mirror — both require the real `HARBOR_URL`
and the kubeconfig FILE, so they cannot pass on a bare jump box. The KinD path needs **none** of this —
it discovers and generates everything.

---

[← back to the README](../README.md)
