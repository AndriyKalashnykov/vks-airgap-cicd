# Make targets

<br>

`make help` prints the full grouped list. The most-used targets:

| Group | Target | Purpose |
|-------|--------|---------|
| Prereqs | `deps` | Install the jump-box toolchain (mise tools incl. **kind**, crane, kubectl, helm + tkn/argocd) |
| Env | `env-init` / `env-populate` / `env-check` / `env-validate` | `.env` lifecycle: copy from `.env.example` → GENERATE the secrets we can + DISCOVER cluster values (and print what only you can provide) → presence gate → validity gate (format + KUBECONFIG/Harbor auth) |
| Env | `creds-show` (alias `creds`) / `argocd-password` | Print the access URLs + logins / the ArgoCD admin password |
| Prereqs | `install-vcf-clis` | Install the Broadcom VCF/VKS lab CLIs (argocd-vcf + vcf + plugins), sudo-free — lab-only, licensed artifacts from a folder (`VCF_CLI_SRC_DIR`) |
| Mirror | `mirror` / `mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | Pull images → Harbor (dual-homed), or the sneakernet phases |
| Mirror | `builder-image` | Build + push the deps-baked offline Maven builder image |
| Install | `vks-login` / `platform` / `gitops` / `install-all` | Auth to VKS; install Gitea+Tekton; wire ArgoCD; or all of it |
| Install | `fetch-harbor-ca` | Fetch a self-signed lab Harbor's CA cert → `HARBOR_CA_FILE` (VKS-lab convenience) |
| KinD e2e | `e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify). Runs with **`.env` ignored** (`E2E_SKIP_DOTENV`) so a local run reproduces a **fresh** box — see below |
| KinD e2e | `e2e-kind-both` | Both SSL modes: secure self-signed TLS, then insecure plain-HTTP |
| KinD e2e | `e2e-kind-istio-existing` | Attach mode: a "platform team" installs Istio under foreign naming; we attach and install nothing (+ both RED tests, both route APIs) |
| KinD e2e | `e2e-kind-cross-cluster` | Two KinD clusters: a HUB ArgoCD registers a GUEST cluster and syncs an app into it (the real-lab Supervisor→guest topology) |
| KinD e2e | `e2e-sneakernet` | Two-BOX sneakernet: bundle on the host, carry **only** the tarball into a FRESH jump-box container, reconstruct → push → integrity-verify |
| KinD e2e | `kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps (`install-istio` / `attach-istio` / `install-traefik` pick the controller) |
| Preflight | `check-tools` / `psa-check` | Required-vs-optional CLIs + versions / would a real VKS cluster (PSA `restricted` by default) even ADMIT our pods? |
| Istio | `istio-preflight` / `attach-istio` / `e2e-kind-istio-existing` | Read-only mesh discovery + what to ask the mesh admin for / attach to an Istio we did not install / its KinD regression test |
| Verify | `verify` | End-to-end smoke test on a LIVE cluster |
| Verify | `verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| Verify | `jumpbox` / `jumpbox-both` | Validate the README bootstrap on a real jump-box container — `JUMPBOX_OS=photon`\|`ubuntu`, or both (needs the KinD cluster up) |
| App dev | `app-test` / `app-build` / `app-run` | Spring Boot app tests / jar / local run |
| Gates | `ci` / `static-check` / `docs-lint` | Composite offline gate; code gate; docs gate |
| Gates | `lint` / `validate` / `test-scripts` | Shell/YAML/Dockerfile lint · manifest schema validation · offline script-logic unit tests |
| Gates | `check-image-alignment` / `check-toolchain-alignment` / `check-java-alignment` | A version that lives in >1 file must agree everywhere (image tags ↔ `images/images.txt`; kubectl pin; Java major) |
| Gates | `check-env` / `check-env-coverage` / `check-env-clobber` / `check-how-provenance` | `.env.example` is the source of truth: it exists · every var the scripts read is documented · **no uncommented value silently defeats a dynamic fallback or a per-run override** · every `# how:` command is runnable or provenance-tagged |
| Gates | `check-readme-scenarios` / `check-tools` / `psa-check` | Every scenario answers every decision in its own section · required-vs-optional CLIs · would a real VKS cluster (PSA `restricted`) admit our pods? |
| Security | `sec` / `secrets` / `trivy-fs` / `trivy-config` | gitleaks + trivy fs (app deps) / config (manifests) |
| Diagrams | `diagrams` / `diagrams-check` / `vendor-diagrams` | Render PNGs / byte-diff drift gate / re-vendor C4-PlantUML |

---

[← back to the README](../README.md)
