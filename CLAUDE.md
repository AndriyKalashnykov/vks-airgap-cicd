# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An **air-gapped VKS CI/CD demo**: from an internet-connected jump box (Ubuntu or
PhotonOS), mirror all required images into **Harbor**, install and wire **Gitea +
Tekton**, and demonstrate GitOps CD via **ArgoCD**. On a real VKS lab Harbor and ArgoCD
are installed as **VCF Supervisor Services** (the README real-lab flow documents that,
Part A); we then install Gitea + Tekton and the demo app. The KinD stand-in installs
Harbor + ArgoCD locally to mimic that.

End-to-end flow: `git push (Gitea) → Tekton (test/build/kaniko→Harbor/tag write-back) → ArgoCD sync → web UI`.

## Common commands

| Command | What it does |
|---------|--------------|
| `make help` | List all targets (grouped) |
| `make deps` | Install jump-box toolchain (mise + `scripts/00-install-prereqs.sh`) |
| `make ci` | Offline gate: `static-check` + `docs-lint` |
| `make static-check` | `check-toolchain-alignment` + `check-java-alignment` + `check-env` + `check-image-alignment` + `lint` + `validate` + `sec` + `app-test` |
| `make sec` | Security scans: `secrets` (gitleaks) + `trivy-fs` (built-jar deps) + `trivy-config` (manifests) |
| `make app-test` / `app-build` / `app-run` | Spring Boot app dev (in `apps/java/webui/`, uses `./mvnw`) |
| `make mirror` | (dual-homed) pull images → push to Harbor. **Resumable:** a re-run cache-skips digest-pinned images already fully pulled (`.mirror-ok` sentinel), so an interrupted/CDN-flaky mirror resumes in seconds. `MIRROR_RETRIES` (default 5), `MIRROR_FORCE_PULL=1` |
| `make mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | sneakernet phases |
| `make mirror-verify` | Verify every mirrored image is INTACT in Harbor (`crane validate` blobs + `images.lock` digest match) — read-only; run after `make mirror` |
| `make builder-image` | build+push the offline Maven builder image (deps pre-baked) |
| `make vks-login` | Authenticate to VKS → writes `$KUBECONFIG` + context |
| `make install-vcf-clis` | On a real-VKS-lab jump box: install the Broadcom lab CLIs (`argocd-vcf` + `vcf` + plugins), OS/arch-aware + sudo-free, from operator-supplied licensed archives in `VCF_CLI_SRC_DIR=<dir>`. (The local KinD e2e doesn't need these — it uses the upstream `argocd` from `deps`.) Granular: `install-argocd-vcf` / `install-vcf-cli` / `install-vcf-plugins` |
| `make platform` | Install + wire Gitea and Tekton |
| `make gitops` | Create the ArgoCD Application |
| `make creds` / `make argocd-password` | Print access URLs+logins / the ArgoCD admin password (context-aware, self-resolves kubeconfig) |
| `make install-ingress` | Install the ingress (`INGRESS_CONTROLLER=istio` default / `traefik`) fronting the UIs at `*.vks.local` |
| `make install-istio` / `install-traefik` | Install a specific ingress controller directly |
| `make install-all` | Full air-gap install: `mirror → builder-image → vks-login → platform → gitops` |
| `make verify` | End-to-end smoke test (LIVE cluster) |
| `make verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| `make e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify) |
| `make kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps |
| `make jumpbox` / `jumpbox-both` | Validate the README jump-box bootstrap on a real jump-box container — `JUMPBOX_OS=photon` (default, `photon:5.0`) or `JUMPBOX_OS=ubuntu` (`ubuntu:26.04`); rootless podman, joined to the kind network: runs `make deps` + engine + cluster/Harbor reach. `jumpbox-both` runs the OS matrix. Needs the KinD cluster up |

Run a single app test: `cd apps/java/webui && ./mvnw -B -Dtest=<ClassName>#<method> test`.

## Architecture / big picture

- **Scripts are numbered by execution order** (`scripts/NN-*.sh`) and all source
  `scripts/lib/os.sh` — the shared library providing OS detection (Ubuntu `apt` /
  PhotonOS `tdnf`), `pkg_install`, logging, `load_env`, and `trust_ca`. Add new OS
  support in `lib/os.sh`, not in individual scripts.
- **`.env.example` is the single source of truth** for every tunable. The Makefile
  `-include .env` + `?=` defaults and every script's `load_env` both read it. Never
  hardcode a host/port/timeout/version — add it to `.env.example`.
- **`RUN_MODE`** selects dual-homed (default, jump box routed to ESXi/Harbor) vs
  sneakernet (bundle carried inside).
- **Two Git repos** in Gitea: `webui-app` (source + Dockerfile + trigger binding)
  and `webui-deploy` (kustomize manifests ArgoCD watches). CI writes the new image
  tag back to `webui-deploy`; ArgoCD deploys from it.
- **VKS auth is isolated in `scripts/30-vks-login.sh`** — the only auth-aware step;
  everything else consumes `$KUBECONFIG`/context.
- **Internal CA trust** (self-signed Harbor) is wired **sudo-free** per consumer — jump-box
  `crane`/`curl` via `SSL_CERT_FILE` (a system-store + our-CA bundle from `lib/tls.sh`), the
  builder push via podman `--cert-dir`, each kind node's containerd via `certs.d/<ip>/ca.crt`,
  and in-cluster Kaniko via the `harbor-ca` ConfigMap. No root-owned system-store change. See
  `docs/decisions/kind-tls-fidelity.md`.
- **Air-gap Maven builds**: an in-cluster `mvn`/Kaniko build cannot reach Maven
  Central, so `scripts/15-build-push-builder.sh` builds `apps/java/webui/Dockerfile.builder`
  on the internet side (bakes the full `~/.m2` via `mvn verify`) and pushes it to
  Harbor. The app `Dockerfile` (`BUILDER_IMAGE` + `MVN_OFFLINE=-o` args) and the
  Tekton `maven-test` task both consume it and build **offline**. Rebuild + bump
  `BUILDER_IMAGE_TAG` when `apps/java/webui/pom.xml` deps change.
- **KinD local e2e**: `kind/kind-config.yaml` enables containerd `config_path`;
  `05-kind-up.sh` runs cloud-provider-kind (LoadBalancer) and writes `KUBECONFIG` +
  `VKS_AUTH_METHOD=kubeconfig` to `.env.kind`; `06-install-harbor.sh` exposes Harbor as a
  **self-signed-HTTPS LoadBalancer on the LB IP** (default; two-phase: install TLS-off →
  discover LB IP → mint CA+leaf with SAN=IP → upgrade to TLS), wires each node's containerd
  with the CA (`certs.d/<ip>/`), and writes `HARBOR_URL`(LB IP)+`HARBOR_INSECURE=0`+
  `HARBOR_CA_FILE` to `.env.kind` (`HARBOR_INSECURE=1` selects the original plain-HTTP mode).
  `07-install-argocd.sh` exposes ArgoCD on its **own** LB with self-signed TLS (default) and
  publishes `ARGOCD_LB_IP`. That overlay (loaded last by `load_env` / `-include`) makes the
  normal flow run against kind unchanged. `kind-down.sh` prunes cloud-provider-kind + `kindccm-*` orphans.
- **Manifest rendering**: k8s/Tekton/ArgoCD YAML carry `${VAR}` tokens rendered by
  the configure scripts with a RESTRICTED `envsubst` allowlist (so step-script
  `$(...)`/`${}` are untouched). Tekton install rewrites upstream image hosts
  (`gcr.io/…` → Harbor) via `sed`, matching `lib/mirror.sh`'s mapping.
- **Pluggable ingress**: `INGRESS_CONTROLLER` (`istio` default / `traefik`) selects the
  controller. `scripts/44-install-ingress.sh` dispatches to `46-install-istio.sh` (helm
  control plane + gateway LB; istio images from Harbor via the `global.hub` override) or
  `45-install-traefik.sh` (single-binary LB). Both expose the SAME `*.vks.local` hosts
  (`GITEA_HOST`/`WEBUI_HOST`/`TEKTON_DASHBOARD_HOST` — **not** ArgoCD, which has its own LB) behind ONE LoadBalancer and
  publish `INGRESS_LB_IP` + the chosen `INGRESS_CONTROLLER` to `.env.kind`. `44-install-ingress.sh`
  lets an explicit `INGRESS_CONTROLLER` override win over the persisted `.env.kind` value (so
  `verify-ingress-both` actually flips controllers). Hostnames resolve via
  `/etc/hosts` → the LB IP (no internet DNS). **Harbor and ArgoCD each keep their OWN direct LB**
  — Harbor's LB IP is load-bearing for the containerd registry pull path (self-signed HTTPS +
  node CA by default) and ArgoCD's own self-signed-TLS LB mirrors the VKS lab; neither is routed
  through the ingress. `make verify-ingress` (in `e2e-kind`, after `verify`) route-checks
  each host through the LB with a K1.5 readiness poll (cloud-provider-kind wires the LB
  Envoy 5–60s after the IP is assigned) and asserts each host serves its own body marker;
  `verify-ingress-both` runs the istio+traefik matrix.
- **Tekton Dashboard**: `TEKTON_DASHBOARD_VERSION` (Renovate `github-releases`) pins the
  read-only `tektoncd/dashboard` web UI; `10-mirror-pull.sh` fetches its release manifest (its
  ghcr.io image auto-mirrors to Harbor), `41-install-tekton.sh` applies it (host-rewritten)
  into `tekton-pipelines`, and the ingress fronts it at `TEKTON_DASHBOARD_HOST`
  (`tekton.vks.local`). No built-in auth — network/ingress-gated (no login).
- **Security + alignment gates** (`static-check`, internet/CI side): `check-toolchain-alignment`
  (kubectl pin in `.mise.toml` == `.env.example` `KUBECTL_VERSION`), `check-java-alignment`
  (Java major identical across `apps/java/webui/pom.xml`, `.mise.toml`, `ci.yml`, the `apps/java/webui/Dockerfile`
  build+runtime images, and `images/images.txt` — Renovate tracks the maven build image and
  the eclipse-temurin runtime image separately, so it can split them; the build once compiled
  for 21 but ran on 25), `sec` (gitleaks +
  trivy fs on the built jar + trivy config on manifests; `.trivyignore` documents the two
  accepted-by-design misconfigs — gitea RO-rootfs, Traefik secrets RBAC). trivy/gitleaks/shellcheck
  are `.mise.toml`-provided (pinned) so local `make static-check`/`make lint` use the SAME versions as
  CI — an unpinned system shellcheck drifts and flags SC2015 that a newer local build doesn't
  (green-local/red-CI).

## Conventions

- **Version manager:** mise (`.mise.toml`) on the jump box — including `crane`
  (the image-mirror engine, a static Go binary). Air-gap exception:
  `tkn`/`argocd` come from OS packages / pinned releases via
  `00-install-prereqs.sh`; the air-gapped host gets binaries from the bundle.
- **Secrets never in argv** — PATs/registry creds via stdin / `--password-stdin` /
  env-by-name (see `.env.example` commented secret placeholders).
- **Java app:** Spring Boot 4 + JUnit/`@SpringBootTest`; Dockerfile follows the
  multistage temurin / non-root / actuator-`HEALTHCHECK` template.
- **Manifests:** Kustomize; validated with `kustomize build | kubeconform`.
- **Container engine split:** `CONTAINER_ENGINE` (podman-preferred, docker fallback)
  drives image ops — mirror, builder image, diagrams. The **KinD local e2e path
  requires Docker**: `05-kind-up.sh` (`require_cmd docker`) + cloud-provider-kind use
  the `kind` Docker network/socket, so node interactions (`crictl` via
  `docker exec <node>`) use Docker even in this podman-default repo.
- **Image tag alignment:** every mirrored image's tag is duplicated between
  `images/images.txt` (the Renovate-tracked mirror source of truth) and its consumers
  (k8s/tekton manifests, `.env.example` `TEMURIN_*_TAG`, the app `Dockerfile`). `make
  check-image-alignment` (in `static-check`) fails CI on any drift; a general Renovate
  customManager bumps the consumers in lockstep.

## Skills

Use the following skills when working on related files:

| File(s) | Skill |
|---------|-------|
| `Makefile` | `/makefile` |
| `renovate.json` | `/renovate` |
| `README.md` | `/readme` |
| `.github/workflows/*.{yml,yaml}` | `/ci-workflow` |
| `docs/diagrams/*.puml` | `/architecture-diagrams` |

When spawning subagents, always pass conventions from the respective skill into the agent's prompt.

## Verification honesty

Offline-verifiable (no cluster): app tests, manifest/Tekton YAML validation, script
lint, Makefile targets, mirror pull mechanics. The **air-gap end-to-end runs on the
live VKS cluster** (`make verify`) and is the demo itself — do not report it
"verified" without running it against real infrastructure.

**CI runs only the offline gates** (`static-check` + `docs-lint`); the KinD end-to-end
(`make e2e-kind`, which now includes `verify-ingress`) is deliberately **local-only**.
A full-stack KinD e2e in GitHub Actions (Harbor via helm + cloud-provider-kind LB +
ArgoCD + Gitea + Tekton + offline builder + pipeline + ingress) is heavy and flaky, and
the real demo is the live VKS run — so the KinD e2e stays a local `make` target rather
than a CI job. Run it locally (and both ingress controllers via `make verify-ingress-both`)
when changing the pipeline, ingress, or manifests.

## Backlog / resume state

> ### ⏳ SESSION HANDOFF 2026-07-11b (READ FIRST — resume here)
>
> `main` GREEN. This session merged **13 PRs** (#93–#107) and validated the full KinD
> e2e end-to-end.
>
> - **Backlog cleared:** bootstrap curl|bash + bare-OS harness (#95), SIGPIPE robustness
>   sweep (#94), diagram layout + proportions (#93/#105), README readability + collapses
>   (#96/#104), maven-image full-tag alignment (#97), hadolint-builder + prose-secret gate
>   (#99), runtime apt-upgrade CVE fix (#100), offline unit tests for resolve + mirror-cache
>   (#101), real `vcf context` login flow replacing the fictional stub (#103).
> - **`.env`/README real-lab ergonomics redesign (#107):** every operator-supplied var now
>   carries a stage tag + `# how:` acquisition command (reusing the same var names); README
>   has TWO real-lab scenarios (**Scenario 1** install / **Scenario 2** already-installed
>   tenant), a staged `.env` fill distributed across the install steps, a Quick-Start Step 0,
>   the VKS-auth section moved up, and the KinD zero-`.env` auto-discovery note.
> - **e2e-kind VALIDATED** end-to-end (kind → Harbor → ArgoCD → mirror-34 → builder
>   [apt-upgrade] → platform → gitops → ingress → pipeline → live app). The one flake found —
>   the Tekton EventListener crash-loops on the clusterInterceptor CaBundle race, so a
>   one-shot webhook pushed during that window is lost — is fixed in `99-verify.sh` (wait for
>   the EL POD Ready + empty-commit re-fire; #106). Codified as `/ci-workflow` K1.6.
>
> **Corrected real-lab facts (from research; all Broadcom pages are 9.0-via-redirect → 9.1
> inferences — verify on a lab):**
>
> - Workload-cluster kubeconfig on VCF 9 = **`vcf cluster kubeconfig get <cluster>
>   --export-file <path>`** (NOT `kubectl vsphere login`, which is legacy vSphere-with-Tanzu 7/8).
> - Harbor & ArgoCD Supervisor Services run **on the Supervisor** (each in its own vSphere
>   Namespace) — installing them needs Supervisor access; the workload kubeconfig is only
>   needed at `make gitops` deploy time. ArgoCD: svc `argocd-server`, ns `argocd-instance-1`,
>   server `2.14.15+vmware.1-vks.1` (2.x; the CLI `3.0.19-vcf` is 3.x — do NOT infer one from
>   the other).
> - Shared-lab tenant: a Harbor **project-admin** (direct, not via an SSO group) self-services
>   a robot; the ArgoCD tenant needs an **AppProject** + RBAC (generic ArgoCD — verify on lab).
>
> **HELD PRs — need a LIVE run before merge (not validated this session):**
>
> - **#98** — non-blocking dispatch+weekly KinD smoke workflow (net-new; needs one live
>   `workflow_dispatch` on `main` to confirm green).
> - **#102** — `make e2e-sneakernet` + mirror-verify-in-e2e + integrity RED test +
>   `e2e-kind-both`; statically validated (lint + `make -n`), needs a live
>   `make e2e-sneakernet` / `make e2e-kind-both` run.
>
> **Skill lessons captured this session** (in `~/projects/claude-config`, uncommitted — commit
> that repo separately): diagram render-scale (`architecture-diagrams`), robust background-job
> detect/kill (`git-workflow`), worktree-agents pollute tree-walking gates (`agents`),
> multi-stage `.env` runbook (`configuration`), K1.6 EventListener-CaBundle webhook race
> (`ci-workflow`).
>
> **Next:** merge #98/#102 after a live run; the `vcf`-login flow + the real-lab `.env`
> guidance are written to the verified shape but NOT lab-validated — see the vcf-CLI research
> block in "Deferred — real-lab-only" below (confirm the interactive/stdin password mechanism
> and the exact 9.1 CLI flags on a real VCF/VKS lab).
>
> ---

`main` is GREEN. KinD self-signed-TLS fidelity + VCF/VKS lab-CLI + **real-lab install runbook &
helpers** are merged. Design rationale: `docs/decisions/kind-tls-fidelity.md`; real-lab flow:
README §"Run against a real VKS lab" (Part A install Harbor+ArgoCD as Supervisor Services / Part B wire+run).

**✅ COMPLETED 2026-07-11 — the full validation sweep ran GREEN end-to-end (both modes):**

1. `make ci` (offline gate) — green (rc=0).
2. **Secure e2e-kind** (default, self-signed TLS): full loop green — git push → Tekton PipelineRun →
   Harbor → tag write-back → ArgoCD sync (`webui:0.1.0`→`:96e22fc`) → rollout → deployed page shows
   the new marker → end-to-end verified; `verify-ingress` all 3 `*.vks.local` UIs 200 + body markers.
   - **All 5 README UIs walked to real content** (7 checks): Gitea, App greeting, Tekton Dashboard
     (via ingress); **Harbor UI portal HTML over CA-trusted HTTPS** (no `-k`, systeminfo `auth_mode`);
     and **ArgoCD UI SPA + API `v3.4.5`** (own LB, self-signed TLS).
   - **3 helpers verified:** `argocd-preflight` → TOPOLOGY OK (reads running server image
     `quay.io/argoproj/argocd:v3.4.5`, not the CLI); `fetch-argocd-ca` → fetches the exact server cert
     (byte-identical), verifies against a covered SAN (`argocd-server`); the raw-LB-IP gap is ArgoCD's
     default cert not listing the IP → documented `--insecure` posture. `harbor-robot` → creates
     `robot$vks-cicd`, creds **authenticate** to the registry and list `apps/webui:96e22fc` (pull scope).
   - `make jumpbox-both JUMPBOX_VCF_SRC=/home/andriy/Downloads/vcf` — Photon **and** Ubuntu `JUMPBOX_OK`
     (mise toolchain, rootless podman, Harbor reach 200, VCF CLIs `argocd v3.0.19-vcf` / `vcf v9.1.0.0`
     and its 6 plugins). Photon `shellcheck` not-packaged is handled gracefully (WARN, lint skips it).
3. **Insecure e2e-kind** (`HARBOR_INSECURE=1 ARGOCD_INSECURE=1`, plain HTTP): `kind-down` (which also
   clears `.env.kind`, so the toggle is deterministic) → full loop green, **install-mode log confirmed
   `Harbor mode: INSECURE` + `ArgoCD mode: INSECURE`** (not silently secure); marker `…1783733627`,
   image `:4619fa4`. **All 5 UIs 7/7** over plain HTTP. `make jumpbox-both` (no VCF src) — both OSes
   `JUMPBOX_OK`, Harbor reach `http://…` 200; VCF step correctly SKIPPED.
4. Ran **sequentially** (no-concurrent-load-during-mirror honored). mirror engine = **crane** (mise).

Re-validated the prior session's changes (lib/harbor.sh refactor, HARBOR_PUBLIC_PROJECTS, the 3 helpers)
end-to-end. Cluster torn down after the sweep.

**✅ COMPLETED 2026-07-11 (same session, follow-on enhancements — all merged, `main` GREEN):**

- **Traefik ingress matrix** — validated `INGRESS_CONTROLLER=traefik` in BOTH SSL modes (secure self-signed
  TLS + insecure plain-HTTP), 7/7 UIs each; completes the full istio/traefik × secure/insecure 2×2.
- **Resumable + verifiable mirror** (PR #87): `make mirror-verify` (crane validate blobs + `images.lock`
  digest match; proven GREEN 34/34 and RED rc≠0 on a deleted image); `images.lock`; **cache-skip** (a
  digest-pinned image already fully pulled via a `.mirror-ok` sentinel is skipped → interrupted mirror
  RESUMES, proven 25/34 skipped in 21s vs ~20min); `MIRROR_RETRIES`/`MIRROR_FORCE_PULL`; `lib/progress.sh`
  reusable `[i/N] (elapsed)` progress + completion signal. cache-skip composes safely with Renovate
  (content-addressed refs → a version bump always pulls the new digest).
- **Interruption-safety / idempotency** (PR #88): `05-kind-up.sh` health-checks an existing cluster and
  recreates a partial/broken one (name-only guard would skip a dead cluster); `50-seed-gitea-repos.sh`
  webhook is now idempotent (GET-then-skip; a re-run no longer creates a duplicate hook → proven count=1);
  **shellcheck pinned via `.mise.toml`** so local `make lint` == CI (fixed an SC2015 green-local/red-CI drift).
- **Diagram** (PR #86): neutralized the ingress namespace label (`istio-ingress | traefik`).
- Docs: README documents the mirror interrupt/resume + `mirror-verify`; this file's Common-commands +
  gates updated.

**⏳ PENDING next — approved follow-ups (own PRs):**

- `bootstrap.sh` — curl|bash jump-box entrypoint: OS-gate (Photon/Ubuntu) → check→install-if-missing→verify→report,
  tag-pinned, dual-homed only, never curls licensed VCF CLIs; validate in the jumpbox harness.
- `make mirror-prune` — drop orphaned old-digest cache dirs (bundle/ hygiene after Renovate bumps).

**Merged this session (real-lab prep):** helpers `make harbor-robot` + `fetch-argocd-ca` +
`argocd-preflight` (+ `lib/harbor.sh` extraction, `HARBOR_PUBLIC_PROJECTS` toggle, fetch-harbor-ca
port fix); README merged into ONE install-first real-lab flow with distilled Broadcom Harbor+ArgoCD
Supervisor-Service steps; CLAUDE.md premise fixed (installed-as-Services, not pre-provided). All
helpers verified against the (now-torn-down) KinD stand-in.

**Deferred — real-lab-only, NOT KinD-reproducible (verify on a VCF/VKS 9.1 lab):**

- Workload cluster trusts the Harbor CA **declaratively** (Cluster spec `trust.additionalTrustedCAs`
  plus a double-base64 secret) — and, same-Supervisor, **auto-trusts** it (simpler than KinD `certs.d`);
  a **private** Harbor project needs `make harbor-robot` creds + an app-namespace `imagePullSecret`
  (`HARBOR_PUBLIC_PROJECTS=false`); the lab is **FQDN**-addressed (KinD uses LB IP + SAN=IP).
- **ArgoCD version delta (corrected):** the operator CR pins the **server** at `2.14.15+vmware.1-vks.1`
  (2.x) while the **CLI** is `3.0.19-vcf` (3.x) — CLI ≠ server; do NOT infer the server from the CLI.
  KinD runs a 3.x server, so there IS a server-generation delta to reconcile. `make argocd-preflight`
  surfaces CLI + running server image + `kubectl explain argocd.spec.version`.
- **ArgoCD topology:** `make gitops` uses the in-cluster destination — confirm ArgoCD runs in / can
  reach the workload cluster (`make argocd-preflight` → TOPOLOGY OK/MISMATCH).

**VKS `vcf`-CLI auth flow (`--auth-type basic`) — SHIPPED as verified-SHAPE (PR #103) but NOT lab-validated; KEEP RESEARCHING before trusting the automation.** The `vcf` method in `scripts/30-vks-login.sh` now runs the real two-step context flow (it replaced the earlier FICTIONAL `vcf login --server … --kubeconfig …` stub, which NO source supports):

```text
vcf context create --endpoint https://<SUPERVISOR_HOST> --username <user>@<VKS_SSO_DOMAIN> \
    [--insecure-skip-tls-verify] --auth-type basic     # INTERACTIVE: prompts for a context NAME + password
vcf context use <VKS_CONTEXT_NAME>:<VKS_NAMESPACE>     # note the <ctx>:<ns> COLON form
# kubectl-vsphere plugin (if the guest cluster needs it) — pulled from the Supervisor:
wget --no-check-certificate https://<SUPERVISOR_HOST>/wcp/plugin/linux-amd64/vsphere-plugin.zip
# offline plugin bundle install: vcf plugin install all --local-source <bundle-dir>
```

Open research items — confirm on a real VCF/VKS 9.1 lab before relying on the automation:

1. **Non-interactive / stdin password mechanism** — `vcf context create` is INTERACTIVE (prompts for the ctx name + password); NO `--password`/`--kubeconfig` flag is confirmed in any source. Run `vcf context create --help` on a lab to find a stdin/env mechanism; until then the flow prompts interactively (a password on argv stays forbidden — security.md). `30-vks-login.sh` carries a matching `TODO(verify on a real VKS lab)`.
2. **Reaching the WORKLOAD (guest) cluster** — ANSWERED by research (documented in #107): on VCF 9 the workload-cluster kubeconfig is obtained via `vcf cluster kubeconfig get <VKS_CLUSTER_NAME> --export-file <path>` (NOT `kubectl vsphere login`, which is legacy vSphere-with-Tanzu 7/8). The Supervisor context ≠ the workload cluster; Harbor + ArgoCD install ON the Supervisor (each in its own vSphere Namespace), and the workload kubeconfig is only needed at `make gitops` deploy time. ArgoCD server pins `2.14.15+vmware.1-vks.1` (svc `argocd-server`, ns `argocd-instance-1`). Still verify the exact 9.1 CLI flags on a real lab.
3. **`.env` inputs** now documented (commented) in `.env.example` §6: `VKS_AUTH_METHOD=vcf`, `SUPERVISOR_HOST`, `VKS_NAMESPACE`, `VKS_USERNAME`, `VKS_SSO_DOMAIN`, `VKS_CONTEXT_NAME` (the vcf ctx name — DISTINCT from the kubeconfig `VKS_CONTEXT`), `VKS_INSECURE_SKIP_TLS_VERIFY`.
4. **Doc-provenance caveat** — the Broadcom **9.1** ArgoCD/Harbor techdoc pages 301-REDIRECT to the **9.0** tree, so the version facts (ArgoCD server `2.14.15+vmware.1-vks.1`, Harbor data-values fields) are 9.0 content taken as authoritative-for-9.1 — an INFERENCE; re-verify against a real 9.1 lab.
5. **Harbor-as-VCF-Service field constraints** (from Broadcom + William Lam, to verify on 9.1): `secretKey` exactly 16 chars, `core.xsrfKey` exactly 32, `tlsSecretLabels: {managed-by: vmware-vRegistry}` REQUIRED for VKS trust; `trust.additionalTrustedCAs` needs a **DOUBLE-base64** cert (`base64 -w0 ca.crt | base64 -w0`); configure Harbor cert+creds BEFORE creating guest clusters.

Primary sources: ogelbric/LAB `VCF-CLI/README.md` (raw.githubusercontent.com — a real working jump-box transcript); ogelbric `Create_Harbor` (Harbor-as-Supervisor-Service); Broadcom `install-argo-cd-service.html` (9-0 redirect); williamlam.com 2025/08 VKS private-registry quick-tip; Broadcom "Integrate VKS with a Private Registry".

**Declined (decision, not a TODO):** ArgoCD Image Updater for registry-driven redeploy — the Tekton
tag-write-back stays the primary GitOps path; revisit only to demo registry-driven deploys.
