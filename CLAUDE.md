# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An **air-gapped VKS CI/CD demo**: from an internet-connected jump box (Ubuntu or
PhotonOS), mirror all required images into **Harbor**, install and wire **Gitea +
Tekton**, and demonstrate GitOps CD via **ArgoCD**. On a real VKS lab Harbor and ArgoCD
are installed as **VCF Supervisor Services** (the README real-lab flow documents that,
Scenario 1); in Scenario 2 they already exist and you discover them as a tenant. We then install
Gitea + Tekton and the demo app. The KinD stand-in installs
Harbor + ArgoCD locally to mimic that.

End-to-end flow: `git push (Gitea) → Tekton (test/build/kaniko→Harbor/tag write-back) → ArgoCD sync → web UI`.

## Common commands

| Command | What it does |
|---------|--------------|
| `make help` | List all targets (grouped) |
| `make deps` | Install jump-box toolchain (mise + `scripts/00-install-prereqs.sh`) |
| `make ci` | Offline gate: `static-check` + `docs-lint` |
| `make static-check` | `check-toolchain-alignment` + `check-java-alignment` + `check-env` + `check-env-coverage` + `check-how-provenance` + `check-image-alignment` + `lint` + `validate` + `sec` + `test-scripts` (offline script unit tests) + `app-test` |
| `make sec` | Security scans: `secrets` (gitleaks) + `prose-secrets` (credential-shaped prose in docs) + `trivy-fs` (built-jar deps) + `trivy-config` (manifests) |
| `make app-test` / `app-build` / `app-run` | Spring Boot app dev (in `apps/java/javawebapp/`, uses `./mvnw`) |
| `make mirror` | (dual-homed) pull images → push to Harbor. **Resumable:** a re-run cache-skips digest-pinned images already fully pulled (`.mirror-ok` sentinel), so an interrupted/CDN-flaky mirror resumes in seconds. `MIRROR_RETRIES` (default 5), `MIRROR_FORCE_PULL=1` |
| `make mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | sneakernet phases |
| `make mirror-verify` | Verify every mirrored image is INTACT in Harbor (`crane validate` blobs + `images.lock` digest match) — read-only; run after `make mirror` |
| `make builder-image` | build+push the offline Maven builder image (deps pre-baked) |
| `make vks-login` | Authenticate to VKS → writes `$KUBECONFIG` + context |
| `make install-vcf-clis` | On a real-VKS-lab jump box: install the Broadcom lab CLIs (`argocd-vcf` + `vcf` + plugins), OS/arch-aware + sudo-free, from operator-supplied licensed archives in `VCF_CLI_SRC_DIR=<dir>`. (The local KinD e2e doesn't need these — it uses the upstream `argocd` from `deps`.) Granular: `install-argocd-vcf` / `install-vcf-cli` / `install-vcf-plugins` |
| `make platform` | Install + wire Gitea and Tekton |
| `make gitops` | Create the ArgoCD Application |
| `make creds-show` (alias `creds`) / `make argocd-password` | Print access URLs+logins / the ArgoCD admin password (context-aware, self-resolves kubeconfig) |
| `make env-init` / `env-populate` / `env-check` / `env-validate` | `.env` lifecycle: create from `.env.example` → GENERATE the secrets we can + DISCOVER cluster values (and print the user-PROVIDE list) → presence gate → validity gate (format + KUBECONFIG/Harbor auth) |
| `make harbor-robot` / `fetch-harbor-ca` / `fetch-argocd-ca` / `fetch-argocd-kubeconfig` / `argocd-preflight` | Real-lab helpers: mint a Harbor robot (needs project-admin) · fetch a self-signed CA · fetch the Supervisor kubeconfig for ArgoCD registration · report ArgoCD CLI vs RUNNING SERVER vs supported versions |
| `make test-scripts` | Offline script-logic unit tests (mirror cache-skip/resume/prune; VCF-CLI archive resolve). Part of `static-check` |
| `make e2e-kind-both` / `verify-ingress-both` / `e2e-cross-cluster` / `e2e-sneakernet` | e2e permutations: both SSL modes · both ingress controllers · 2-cluster ArgoCD registration · two-box sneakernet |
| `make install-ingress` | Install the ingress (`INGRESS_CONTROLLER=istio` default / `istio-existing` = attach to a platform-owned mesh / `traefik`) fronting the UIs at `*.vks.local` |
| `make install-istio` / `install-traefik` | Install a specific ingress controller directly |
| `make psa-check` | Read-only: would our pods survive a real VKS guest cluster? VKS **enforces PSA `restricted` by default** (VKr v1.26+) while KinD enforces nothing — so `ci` (Kaniko builds as root) and the Gateway namespace (Istio's auto-provisioned proxy sets no seccompProfile) need `baseline` or their pods are REJECTED on the lab. Levels are MEASURED via a server-side dry-run label, not guessed. Wired into both e2e targets |
| `make istio-preflight` | Read-only: is Istio here, what `Gateway` selector does it require, what may this kubeconfig do, and what must the mesh admin grant? Run before touching a cluster you don't own |
| `make attach-istio` | Attach to an Istio the platform team ALREADY installed (`INGRESS_CONTROLLER=istio-existing`) — installs nothing, applies routes only. `ISTIO_ROUTE_API=auto` (default) prefers the Kubernetes **Gateway API** (Istio auto-provisions the proxy + LB; nothing needed from the mesh admin) and falls back to `classic` (discovered `istio:` selector + VirtualServices) |
| `make e2e-kind-istio-existing` | KinD regression test for the attach mode: a "platform team" installs Istio under FOREIGN naming, we attach with zero install (+ both REDs), then verify BOTH route APIs (gateway-api leg + classic leg) |
| `make install-all` | Full air-gap install: `mirror → builder-image → vks-login → platform → gitops` |
| `make verify` | End-to-end smoke test (LIVE cluster) |
| `make verify-ingress` / `verify-ingress-both` | Assert the `*.vks.local` UIs route through the ingress LB (one controller / both) |
| `make e2e-kind` | Full local end-to-end in KinD (cluster → Harbor → ArgoCD → pipeline → ingress → verify) |
| `make kind-up` / `install-harbor` / `install-argocd` / `install-ingress` / `kind-down` | Individual KinD steps |
| `make jumpbox` / `jumpbox-both` | Validate the README jump-box bootstrap on a real jump-box container — `JUMPBOX_OS=photon` (default, `photon:5.0`) or `JUMPBOX_OS=ubuntu` (`ubuntu:26.04`); rootless podman, joined to the kind network: runs `make deps` + engine + cluster/Harbor reach. `jumpbox-both` runs the OS matrix. Needs the KinD cluster up |

Run a single app test: `cd apps/java/javawebapp && ./mvnw -B -Dtest=<ClassName>#<method> test`.

## Architecture / big picture

- **Scripts are numbered by execution order** (`scripts/NN-*.sh`) and all source
  `scripts/lib/os.sh` — the shared library providing OS detection (Ubuntu `apt` /
  PhotonOS `tdnf`), `pkg_install`, logging, `load_env`, and `trust_ca`. Add new OS
  support in `lib/os.sh`, not in individual scripts.
- **`.env.example` is the single source of truth** for every tunable. The Makefile
  `-include .env` + `?=` defaults and every script's `load_env` both read it. Never
  hardcode a host/port/timeout/version — add it to `.env.example` (`make check-env-coverage`
  gates it). A var the code reads with a FALLBACK (`${X:-$(pick_port)}`, `${A:-$B}`) or a
  per-run TOGGLE must be left **commented** there — `load_env` sources the file with `set -a`,
  so an uncommented value is exported and silently CLOBBERS the fallback/override.
- **The KinD e2e IGNORES `.env`** (`SKIP_DOTENV=1`, set by `E2E_SKIP_DOTENV ?= 1` on both
  `e2e-kind` targets). It is a stand-in for a fresh operator / a CI runner, neither of which has
  a `.env`, so the you-choose secrets must be GENERATED (`05-kind-up.sh`), not read from yours.
  Without it a local run passes on values only your box has. Opt out: `E2E_SKIP_DOTENV=0`.
- **Manifest layout:** `k8s/{gitea,istio,traefik,tekton,argocd}/` = everything **we** apply to
  the cluster. `deploy/javawebapp/` is **not** applied by us — `50-seed-gitea-repos.sh` seeds it into
  the `javawebapp-deploy` Gitea repo (one dir per deploy repo); `apps/java/javawebapp/` is the content of
  the `javawebapp-app` repo. Do not nest `deploy/` inside `apps/java/javawebapp/` — that dir IS the app
  repo, so the manifests would land in it and collapse the two-repo GitOps split.
- **Mirror mode is not a variable** — dual-homed vs sneakernet is simply which mirror
  commands you run: dual-homed → `make mirror`; sneakernet → `make mirror-pull && make
  bundle` (carry the bundle) then `make bundle-load && make mirror-push`.
- **Two Git repos** in Gitea: `javawebapp-app` (source + Dockerfile + trigger binding)
  and `javawebapp-deploy` (kustomize manifests ArgoCD watches). CI writes the new image
  tag back to `javawebapp-deploy`; ArgoCD deploys from it.
- **VKS auth is isolated in `scripts/30-vks-login.sh`** — the only auth-aware step;
  everything else consumes `$KUBECONFIG`/context.
- **Internal CA trust** (self-signed Harbor) is wired **sudo-free** per consumer — jump-box
  `crane`/`curl` via `SSL_CERT_FILE` (a system-store + our-CA bundle from `lib/tls.sh`), the
  builder push via podman `--cert-dir`, each kind node's containerd via `certs.d/<ip>/ca.crt`,
  and in-cluster Kaniko via the `harbor-ca` ConfigMap. No root-owned system-store change. See
  `docs/decisions/kind-tls-fidelity.md`.
- **Air-gap Maven builds**: an in-cluster `mvn`/Kaniko build cannot reach Maven
  Central, so `scripts/15-build-push-builder.sh` builds `apps/java/javawebapp/Dockerfile.builder`
  on the internet side (bakes the full `~/.m2` via `mvn verify`) and pushes it to
  Harbor. The app `Dockerfile` (`BUILDER_IMAGE` + `MVN_OFFLINE=-o` args) and the
  Tekton `maven-test` task both consume it and build **offline**. Rebuild + bump
  `BUILDER_IMAGE_TAG` when `apps/java/javawebapp/pom.xml` deps change.
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
- **Manifest rendering**: k8s/ YAML (gitea, istio, traefik, tekton, argocd) carry `${VAR}` tokens rendered by
  the configure scripts with a RESTRICTED `envsubst` allowlist (so step-script
  `$(...)`/`${}` are untouched). Tekton install rewrites upstream image hosts
  (`gcr.io/…` → Harbor) via `sed`, matching `lib/mirror.sh`'s mapping.
- **Istio: two scenarios** (see `docs/decisions/istio-on-vks.md`). `INGRESS_CONTROLLER=istio`
  (default) INSTALLS the mesh; `istio-existing` attaches to one the platform team already
  installed and installs NOTHING. **Istio has no credentials** — it exposes no login, no bearer
  token, and no admin API; mesh
  access is kubectl RBAC (the only credential-shaped object is a TLS Secret named by
  `Gateway.tls.credentialName`, which lives in the gateway's namespace → you REQUEST it).
  The load-bearing fact: the `istio/gateway` helm chart derives the gateway's `istio:` label from
  the **helm RELEASE NAME**, so a foreign mesh is NOT labelled `ingressgateway` — the selector must
  be DISCOVERED (`scripts/lib/istio.sh`: the Service exposing port **15021** with a
  `spec.selector.istio` key; istiod has no 15021, which excludes the control plane). A
  non-matching selector is **accepted by the API server with no error** and binds nothing →
  connection refused; a VirtualService naming the Gateway by **bare name** from another ns
  resolves namespace-locally → 404. VirtualServices therefore live in their BACKEND's namespace
  with a `<gw-ns>/<gw-name>` ref (the only layout a locked-down tenant can use). `make
  istio-preflight` is the read-only "what do I have / what must the mesh admin grant me" helper;
  `make e2e-kind-istio-existing` is the regression test (a "platform team" installs Istio under
  FOREIGN naming, then we attach — plus both REDs).
- **Pluggable ingress**: `INGRESS_CONTROLLER` (`istio` default / `istio-existing` / `traefik`)
  selects the controller. `scripts/44-install-ingress.sh` dispatches to `46-install-istio.sh` (helm
  control plane + gateway LB; istio images from Harbor via the `global.hub` override),
  `47-attach-istio.sh` (discover + attach only), or
  `45-install-traefik.sh` (single-binary LB). All expose the SAME `*.vks.local` hosts
  (`GITEA_HOST`/`JAVAWEBAPP_HOST`/`TEKTON_DASHBOARD_HOST` — **not** ArgoCD, which has its own LB) behind ONE LoadBalancer and
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
- **`.env.example` clobber rule (BLOCKING, bites repeatedly):** `load_env` sources `.env.example`
  with `set -a`, so **every uncommented line becomes an exported env var** — applied AFTER make put
  a per-run override in the environment. So a var that the code reads with a **dynamic fallback**
  (`${VAR:-$(pick_port)}`, `${VAR:-${OTHER}}`) or that a make target **overrides per-run**
  (`make bundle BUNDLE_OUT_DIR=…`) MUST stay **COMMENTED** there, or the sourced value silently
  wins. It has broken real things three times: `GITEA_LOCAL_PORT` killed the ephemeral-port
  parallel-safety; `BUNDLE_OUT_DIR` made `tar` archive a directory into itself; `BUNDLE_TARBALL`
  made `bundle-load` look in the wrong place. `make check-env-clobber` now enforces it.
- **Security + alignment gates** (`static-check`, internet/CI side): `check-toolchain-alignment`
  (kubectl pin in `.mise.toml` == `.env.example` `KUBECTL_VERSION`), `check-java-alignment`
  (Java major identical across `apps/java/javawebapp/pom.xml`, `.mise.toml`, `ci.yml`, the `apps/java/javawebapp/Dockerfile`
  build+runtime images, and `images/images.txt` — Renovate tracks the maven build image and
  the eclipse-temurin runtime image separately, so it can split them; the build once compiled
  for 21 but ran on 25), `sec` (gitleaks +
  trivy fs on the built jar + trivy config on manifests; `.trivyignore` documents the two
  accepted-by-design misconfigs — gitea RO-rootfs, Traefik secrets RBAC). trivy/gitleaks/shellcheck
  are `.mise.toml`-provided (pinned) so local `make static-check`/`make lint` use the SAME versions as
  CI — an unpinned system shellcheck drifts and flags SC2015 that a newer local build doesn't
  (green-local/red-CI).
- **The `.env.example` gates** — `check-env` (it exists), `check-env-coverage` (every operator-settable
  var the scripts read is documented; it scans **every operator-run script** and PRINTS ITS DENOMINATOR
  — it used to glob `[0-8][0-9]-*.sh` and was blind to `99-verify.sh`, which is exactly why the
  `GITEA_LOCAL_PORT` clobber survived), `check-env-clobber` (the rule above), `check-how-provenance`
  (every `# how:` command must be one WE run, a real make target, or provenance-tagged — a fabricated
  `vcf` command shipped once). `test-scripts` (offline script-logic unit tests) is also in
  `static-check`; it previously had targets that **nothing invoked**.
- **A gate is trusted only after a demonstrated RED.** Every gate here has been proven to fail on the
  defect it claims to catch. Two of them were found *passing by not looking*: `check-env-coverage`
  (above) and `lint`, which listed the manifest dirs by name and silenced yamllint's stderr — when a
  dir moved it failed with "findings above" and **nothing above**.

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

## VKS services — the living record

`docs/vks-services/` is the tracked, updatable record of what VMware/Broadcom actually ships and how
we consume it: [`harbor.md`](docs/vks-services/harbor.md), [`argocd.md`](docs/vks-services/argocd.md),
[`istio.md`](docs/vks-services/istio.md). Each fact carries a **provenance grade** (lab-verified /
KinD-verified / 9.0-doc-inferred-for-9.1 / community / UNVERIFIED) — the Broadcom 9.1 doc URLs
301-redirect to the 9.0 tree, so most vendor facts are *inferences about 9.1*. **When a lab run
confirms or refutes something, update the grade in place** (and correct the fact, with a note) rather
than re-deriving it next session. The load-bearing split: Harbor + ArgoCD are **Supervisor Services**
(they run beside your workload cluster → discover + request + register); Istio is a **guest-cluster
Standard Package** (→ attach, never install; there are no Istio credentials).

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

## Naming history

**`webui` was renamed to `javawebapp`** (2026-07-12) when a second app (`gowebapp`) arrived — the
name had to say WHICH app. The rename covered the source tree (`apps/java/javawebapp`, Java package
`com.vmware.vks.demo.javawebapp`), the Gitea repos (`javawebapp-app` / `javawebapp-deploy`), the
Harbor path (`apps/javawebapp`), the Tekton objects, the deploy dir (`deploy/javawebapp`) and the
ingress host (`javawebapp.vks.local`). **The dated handoff entries below still say `webui`** — that
is what those PRs actually touched, and rewriting them would falsify the record.

## Backlog / resume state

> ### ▶️ HANDOFF 2026-07-12d — MULTI-APP (javawebapp + gowebapp). Branch: refactor/webui-to-javawebapp
>
> ### ⚠️ DO THIS FIRST — the two-app walk is NOT yet proven green
>
> Run: `make kind-down && make e2e-kind`
>
> At handoff the 4th e2e attempt was still running. **Nothing below is "verified" until it is.**
> Each previous attempt failed on a REAL multi-app bug (all now fixed) and got one stage further:
>
> | # | Died at | Cause (a real bug, not a flake) | Fixed |
> |---|---|---|---|
> | 1 | `builder-image` | `app_has_builder "$a" && printf …` — a bare `A && B` returns NON-ZERO when A is false, and gowebapp (stdlib-only, no `Dockerfile.builder`) is LAST -> `set -e` killed the script | ✅ `if…fi` everywhere |
> | 2 | `seed-gitea` | leftover `: "${APP_NAME:?}"` require of a global the refactor deleted | ✅ + swept every script |
> | 3 | `gowebapp-ci` | `CouldntGetTask` — the `go-test` Task was never added to `k8s/tekton/tasks/` | ✅ added + **GATE** in `make validate` (RED-proven) |
>
> **What attempt 3 DID prove** (the two things that could not be checked statically):
>
> - the SHARED EventListener's `labelSelector` **does** discover the per-app `Trigger` CRs, and
> - the CEL filter on `body.repository.name` routes each repo's push to its OWN pipeline —
>   `javawebapp-ci` **Succeeded** while `gowebapp-ci` fired from a push to `gowebapp-app`.
> - **A green javawebapp did NOT hide the broken gowebapp** — which is exactly why `verify` was
>   rewritten per-app. That property is the single most valuable thing in this refactor.
>
> **Still unproven** (what the next run must show): the Go app's Kaniko build OFFLINE against the
> mirrored `golang` + digest-pinned distroless; its tag write-back; its ArgoCD sync; and BOTH pages
> serving their own markers. Expect: `verify [javawebapp] SUCCESS` **and** `verify [gowebapp] SUCCESS`.
>
> #### What shipped (on the branch, NOT yet merged — PRs #139 docs-sync, #140 rename+multi-app)
>
> - **`webui` -> `javawebapp`** (a second app arrived; the name must say WHICH app). CLAUDE.md's
>   dated history deliberately still says `webui` — rewriting it would falsify the record.
> - **`gowebapp`**: Go, **stdlib-only** on purpose — with zero modules the air-gapped build fetches
>   nothing, so it needs NO pre-baked dependency cache (the Maven app needs `Dockerfile.builder`
>   precisely because an in-cluster `mvn` cannot reach Maven Central). distroless/static, uid 65532,
>   digest-pinned base (the `nonroot` tag MOVES).
> - **`apps/registry.tsv` + `scripts/lib/apps.sh`**: the single source of truth. Seeding, Tekton,
>   ArgoCD, ingress, PSA, preflights, validate, lint, trivy-fs, builder-image, app-test/build/run
>   and verify ALL loop over it. **Adding an app is ONE ROW**; a new LANGUAGE is that row + one
>   `case` branch (test task, marker file, health path, base images).
> - **Tekton**: ONE shared EventListener (`labelSelector`) discovering a per-app standalone
>   `Trigger` CR (CEL-filtered on `body.repository.name` — VERIFIED against Gitea's docs); ONE
>   pipeline template rendered per app; shared tasks + a shared `apps-ci` ServiceAccount.
> - **`make verify` proves EACH app independently**: own marker, own PipelineRun (matched by the
>   `tekton.dev/pipeline=<app>-ci` label, not "some new run appeared"), own deployed-image change,
>   own page. A green javawebapp can no longer hide a broken gowebapp.
> - **NEW GATE `check-app-hardcodes`** (in static-check): no shared file may NAME an app. It found
>   4 REAL bugs on first run — the write-back commit message said "ci: deploy javawebapp" for EVERY
>   app; a route-API switch deleted only javawebapp's routes; hadolint never linted the Go
>   Dockerfile; several hardcoded paths.
> - `trivy-fs` now scans EVERY app's ARTIFACT (jar + the compiled Go binary — a stdlib-only app has
>   no modules, so scanning go.mod would miss Go-STDLIB CVEs entirely).
>
> #### TODO (small, known)
>
> 1. **`ARGOCD_PROJECT`** — `k8s/argocd/application.yaml:9` hardcodes `project: default`. Fine for
>    KinD/Scenario 1 (admin); a TENANT has their own AppProject. Make it a var (default `default`).
> 2. **Diagrams** show one app — re-render (`make diagrams`; the drift gate will catch it).
> 3. **CLAUDE.md "Common commands"** still says one app in places; README got the multi-app pass
>    (new "Adding an app" section incl. the real-lab grant table).
> 4. Merge #139, then #140.
>
> #### Real-lab facts established this session (no lab needed to re-derive)
>
> | Concern | Verdict |
> |---|---|
> | Harbor robot | **Project-scoped** (`22-harbor-robot.sh:40`) -> a 2nd app needs NO new credential. |
> | ArgoCD AppProject | A TENANT must have the new namespace in `spec.destinations` AND the new `<app>-deploy` URL in `spec.sourceRepos`. The ONLY universal tenant request. Scenario 1: none (`default` permits all). |
> | Ingress host | Only an issue on the CLASSIC shared-Gateway path (its `hosts:` belongs to the mesh admin). On the **Gateway-API** path (default; what Broadcom uses) Istio auto-provisions the gateway from OUR Gateway in OUR namespace -> self-service, no request. |
> | Namespace | One per app (operator's decision). Apps COULD share one; that would remove the AppProject request but weaken isolation. |
>
> #### 📋 BACKLOG — DEEP-RESEARCH the real-lab grant table, then adversarially verify it
>
> The README's "Adding an app -> on a REAL lab" table gives commands (ArgoCD AppProject
> `spec.destinations`/`spec.sourceRepos` patch; Istio shared-Gateway `hosts:` patch). The FACTS are
> sourced (ArgoCD docs; our own 22-harbor-robot.sh; the Istio Gateway host model) but the **exact
> invocations are INFERRED and never run on a lab** — and the lab's ArgoCD SERVER is 2.14.x while
> ours is 3.x. This repo has a gate against exactly this class (`check-how-provenance`), so:
>
> 1. **Deep-research** each cell against PRIMARY sources for the PINNED versions (ArgoCD 2.14 docs,
>    Broadcom VKS ArgoCD/Harbor/Istio package docs, Istio 1.30 Gateway API + classic).
> 2. **Run the result past a devil's-advocate SPECIALIST** (VKS/VCF + Kubernetes + ArgoCD + Harbor +
>    Istio) briefed with the portfolio conventions — and note that in this session FOUR agents idled
>    without ever delivering, so do not block on one: verify yourself and use the agent as a check.
> 3. Correct the table, and grade every cell (lab-verified / doc-cited / INFERRED).
> Open question to settle: does a 2.14 AppProject reject the Application with a distinguishable
> error, and does a VKS-managed ArgoCD even let a tenant see their AppProject?
>
> #### Traps hit this session (do not repeat)
>
> - **`A && B` as a loop body returns NON-ZERO when A is false** -> under `set -e` the whole script
>   dies. `app_has_builder "$a" && printf ...` killed `builder-image` (gowebapp is last and has no
>   builder). Use `if ...; then ...; fi`.
> - **A `${VAR}` inside a YAML FLOW mapping is a syntax error** (`{ name: ${X} }`) — block style only.
> - **Never edit a script while a long run is executing it** (bash reads scripts incrementally).
> - **Agents idle without reporting**: 4 devil's-advocate/research agents idled with no deliverable.
>   Their key questions were answered directly instead (Gitea payload field, Harbor robot scope,
>   Gateway-API self-service). Do not block on an agent; verify yourself.

---|---|---|
> | istio + secure TLS (default) | `make e2e-kind` | ✅ marker deployed, 3 UIs 200, PSA OK |
> | both ingress controllers | `make verify-ingress-both` | ✅ istio + traefik routes |
> | traefik + secure TLS | `make e2e-kind INGRESS_CONTROLLER=traefik` | ✅ |
> | istio + INSECURE (plain HTTP) | `make e2e-kind HARBOR_INSECURE=1 ARGOCD_INSECURE=1` | ✅ (mode read from the log banner, not inferred) |
> | attach to a platform-owned Istio | `make e2e-kind-istio-existing` | ✅ both REDs, DISCOVERY OK, both route APIs |
> | cross-cluster ArgoCD registration | `make e2e-kind-cross-cluster` | ✅ |
> | two-box sneakernet | `make e2e-sneakernet` | ✅ `JUMPBOX_SNEAKERNET_OK` |
>
> **`make deps` now installs `kind`** (pinned in `.mise.toml`) — verified on a bare `ubuntu:26.04`
> container with no kind on PATH. It previously installed it NOWHERE, so the flagship KinD path was
> unrunnable on a fresh box and only worked because dev boxes already had it.
>
> Next session: pick up the backlog below. Re-run any e2e permutation you touch code for.

---

> ### ✅ DONE 2026-07-12c — all three former backlog items shipped (#135–#138)
>
> **Operator-journey framing + "tenant" defined (#135).** The three paths now say what the operator
> IS DOING: (1) KinD — *see it work*; (2) real lab — *I install Harbor + ArgoCD*; (3) real lab — *I'm
> a tenant*. The whole difference between the real-lab paths is **install** vs **discover + request**,
> and that is what decides the Harbor robot, the ArgoCD registration, and install-vs-attach Istio.
> "Tenant" is defined in Scenario 2's own section (self-service / must-request / needed-regardless /
> the surprise: **Istio has no credentials**).
>
> **The `Needs` column is a real checklist (#135).** Each path now gives **Have: / Reachable: / Run:**
> — concrete requirements and the commands, no rationale. (Feedback that stuck: *docs say what you
> need, how to get it, and what to run — the reasoning is not the reader's problem.*)
>
> **Document-correctness audit, claim-by-claim (#138).** 40 candidate findings, adversarially
> verified → 29 confirmed / 11 refuted, then each re-checked against the code by hand. It found
> **three real bugs**, not just prose:
>
> | Bug | Why it mattered |
> |---|---|
> | **`make deps` never installed `kind`** | The flagship KinD path was **unrunnable on a fresh box**. Nothing in the repo installed kind, yet the README promised it and `05-kind-up.sh` does `require_cmd kind`. It only ever worked because dev boxes already had it (CI curled its own copy). Now pinned in `.mise.toml` — **verified on a bare `ubuntu:26.04` container**. |
> | **`e2e-sneakernet` was broken** | `.env.example` clobbered the per-run `BUNDLE_OUT_DIR` → `tar` archived a directory into itself; fixing that exposed the same bug in `BUNDLE_TARBALL`. |
> | **`check-env-coverage` was blind to 19 scripts** | Incl. `99-verify.sh` — which is exactly why the `GITEA_LOCAL_PORT` clobber (killing ephemeral-port parallel-safety) survived. |
>
> Also killed: 12 false "Harbor/ArgoCD are **VKS-provided**" claims (they are Supervisor Services you
> install, or that already exist), "`make verify` curls app.vks.local" (it port-forwards), "an
> off-cluster ArgoCD is not supported" (it is — that is what `make argocd-register-guest` does), and
> a dead `ARGOCD_HOST` knob advertising a route that does not exist.
>
> **New gates (each RED-proven, in `static-check`):** `check-env-clobber` (three instances of one bug
> class is a missing gate, not bad luck) and a widened `check-env-coverage` that prints its
> denominator. `test-scripts` (offline unit tests that **nothing invoked**) is now wired in too.

---

> ### ✅ RESOLVED (2026-07-12b) — `ARGOCD_KUBECONFIG` acquisition → `make fetch-argocd-kubeconfig`
>
> It was briefly recorded as "nothing creates it, command UNKNOWN" — which silently meant **both
> real-lab scenarios could not complete `make gitops`**. That was a research failure, not a real
> unknown: one search found it in Broadcom's own docs.
>
> ArgoCD is a **Supervisor Service**, so registration needs a **Supervisor** kubeconfig (not the
> workload one `make vks-login` gives you). Per Broadcom (*Connect to the Supervisor as a vCenter SSO
> User* + *VCF CLI Context, Architecture, and Configuration*): `vcf context create --endpoint
> https://<SUPERVISOR> --username <u>@<domain> --ca-certificate <ca>` creates a Supervisor context,
> and *"the VCF CLI respects the KUBECONFIG environment variable for writing to alternate
> locations"*. `scripts/31-fetch-argocd-kubeconfig.sh` points `KUBECONFIG` at `$ARGOCD_KUBECONFIG`,
> selects the `<ctx>:<ARGOCD_NAMESPACE>` context, and **proves** `argocd-server` is visible.
>
> - **Scenario 1** (you are the admin): `make fetch-argocd-kubeconfig` → `make gitops` auto-registers.
> - **Scenario 2** (tenant): registration is **ADMIN-only** — do NOT set `ARGOCD_KUBECONFIG`;
>   **request** that the platform team register your guest cluster.
>
> ⚠️ **Provenance: INFERRED** (Broadcom 9.0-tree docs; the 9.1 URLs redirect). Never run on a lab, and
> **interactive** (the CLI prompts for the password). **Next lab session: run it and upgrade the grade.**

---

> ### 📋 BACKLOG — document-correctness audit (claim-by-claim, NOT a keyword grep)
>
> **Why it exists:** two doc defects shipped in one session because every README review was scoped
> to the *feature just built* — a grep for `istio|ingress|gateway` finds only claims that mention
> those words. The defects it could never have found:
>
> - the **lead paragraph** said "Harbor and ArgoCD are **provided by VKS**" — contradicting
>   Scenario 1 (where the operator installs them) and omitting Istio entirely;
> - the **"Choose your path"** table told every newcomer the KinD path *"Needs: Docker"*, with no
>   mention that the repo is **podman-preferred** (`CONTAINER_ENGINE ?= podman || docker`) and that
>   Docker is required **only** by the KinD stand-in.
>
> Both were caught by the user, not the review. A diff-scoped grep inherits the blind spot of the
> feature you just wrote; the document's *correctness* is not bounded by your diff.
>
> **The task:** audit every tracked doc (`README.md`, `CLAUDE.md`, `docs/**/*.md`) by its **CLAIMS**,
> independent of what was last changed. A README is a set of factual assertions about the system —
> enumerate them and verify each against the code:
>
> | Claim type | Verify against |
> |---|---|
> | prerequisites / "Needs: X" | the real toolchain — is X *required*, one *option*, the *fallback*, or needed by only one path? |
> | defaults ("uses Y by default") | the `?=` / `${VAR:-}` default in the Makefile/script — not memory |
> | commands | the target exists **and** is the right command *in each scenario the doc describes* |
> | versions / names / endpoints | the pinned value in code |
> | "X is not needed" | grep that it truly is not invoked |
> | capability claims ("zero-config", "one command") | run it on a **clean checkout** |
> | who-installs-what (Supervisor Service vs guest package vs ours) | `docs/vks-services/` |
>
> **Method (both, not either):** (1) read each doc top-to-bottom *as a stranger*, listing every
> sentence that asserts a fact, then verify that list; (2) grep for **claim vocabulary**, not feature
> vocabulary: `grep -niE 'needs?:|requires?|by default|only|must|never|no .* (needed|required)|zero|one command'`.
>
> Also fold in: every documented settable must have a grep-verified consumer (the dead-`RUN_MODE`
> lesson), and every `.env`-consuming script's variables must appear in `.env.example` (5 of the 8
> cross-cluster-registration vars were missing until 2026-07-12).
>
> Rule captured in the `/readme` skill ("Audit the README by its CLAIMS, never by a keyword grep
> scoped to your diff").

---

> ### ⏳ SESSION HANDOFF 2026-07-12b
>
> `main` GREEN, **0 open PRs**. Merged **#125–#131**. Both e2e targets PASSED at session end.
>
> **THE QUESTION ANSWERED:** *how is Istio meant to be used on VKS, and how do we use it if we don't
> install it?*
>
> - **There are NO Istio credentials.** No login, no bearer token, no admin API, no UI — mesh access
>   is plain **kubectl RBAC**. The only credential-shaped object is a TLS Secret named by
>   `Gateway.tls.credentialName`, which lives in the GATEWAY's namespace → you **request** it.
>   (Harbor/ArgoCD do have admin passwords; Istio does not. The question was a category error.)
> - **Configuring a mesh you didn't install = discovery + RBAC + attaching routes** →
>   `INGRESS_CONTROLLER=istio-existing` (#125). `make istio-preflight` tells a tenant what to request.
>
> **VERIFIED (Broadcom TechDocs + VMware VCF blog; 9.1 URLs 301-redirect to 9.0 — grade accordingly):**
> Istio IS a **VKS Standard Package on the GUEST cluster** (`istio.kubernetes.vmware.com`,
> `vcf package install istio` / `vcf addon install create istio`). Its **ingress gateway is DISABLED
> by default**, air-gap uses `meshConfig.imagePullSecrets`, and **Broadcom routes with the Kubernetes
> GATEWAY API** (`gatewayClassName: istio`). ⇒ on a real lab the mesh is THEIRS → attach.
> Harbor + ArgoCD are **Supervisor Services** (beside the workload cluster). Full living record with
> per-fact provenance grades: **`docs/vks-services/{README,harbor,argocd,istio}.md`**.
>
> **THE BUG THAT FOUND:** the `istio/gateway` helm chart derives the gateway's `istio:` label from the
> **HELM RELEASE NAME**, so a hardcoded `selector: {istio: ingressgateway}` binds NOTHING on a foreign
> mesh — and the API server **accepts it with no error** (→ connection refused, not 404). The selector
> is now DISCOVERED (the Service exposing port **15021**; istiod has none).
>
> **SHIPPED:** #125 attach mode · #126 **Gateway API** support (`ISTIO_ROUTE_API=auto|gateway-api|classic`;
> Istio auto-provisions the proxy AND its LoadBalancer, air-gap-safe for free) · #127 **PSA** (VKS enforces
> `restricted` by default; **Kaniko and the Istio-provisioned proxy would be REJECTED** — both namespaces
> need `baseline`; `make psa-check`) + LB diagnostics · #128 handoff · #129 **default-path 404 fix**
> (`envsubst` renders an UNEXPORTED var EMPTY → the Gateway landed in `default`) + a registry `flock` ·
> #130 `docs/vks-services/` + `.env` completeness · #131 **README made truly scenario-based**.
>
> **THREE NEW CI GATES** (rules that were BLOCKING, loaded, and violated anyway — so they became checks):
> `check-env-coverage` (every operator var must be in `.env.example` — found 8 undocumented) ·
> `check-how-provenance` (every `# how:` must be runnable-by-us / a real target / provenance-tagged —
> caught 2 fabricated `vcf` commands) · `check-readme-scenarios` (every scenario must answer every
> decision in its OWN section). Also `make check-tools` (required vs optional CLIs; records that
> **istioctl is NOT needed** and the **argocd CLI is optional** — registration is declarative kubectl).
>
> **BLOCKED — real-lab only:** `ARGOCD_KUBECONFIG` acquisition (nothing creates it; the command is
> UNKNOWN — see the backlog), vcf-CLI auth (#9), exact 9.1 package version strings.
>
> ---
>
> ### ⏳ SESSION HANDOFF 2026-07-11c
>
> `main` GREEN, **0 open PRs**. Session 2026-07-11c merged **#109, #102, #110, #111, #112, #113**
> (see the SESSION 2026-07-11c summary below); the ONLY remaining backlog item (vcf-CLI real-lab
> auth) is blocked on a real VCF/VKS 9.1 lab. Earlier session (2026-07-11b) merged 13 PRs
> (#93–#107); that history is retained below.
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
> **SESSION 2026-07-11c — every in-flight item SHIPPED (`main` green, 0 open PRs):**
>
> - **#98 / #102 / #109** — `e2e-kind-smoke` dispatched on `main` → **GREEN on a fresh runner** (verifies #109's zero-config throwaway passwords fix the #98 smoke); #102 (sneakernet + mirror-verify-in-e2e + integrity RED test) merged + live-validated.
> - **#110** — pipeline-flow diagram: was **CLIPPED at PlantUML's 4096px `PLANTUML_LIMIT_SIZE`** (the `webui` node + legend truncated) — folded to a complete 2-lane directional-`Rel` layout (3101×672), `PLANTUML_LIMIT_SIZE=16384` render backstop, click-to-enlarge README embed.
> - **#111** — real-lab README: **each scenario is now self-contained end-to-end** (no "Part A/Part B / as in Scenario 1" cross-refs; the ~200-line shared run-steps tail is duplicated into each; redundant "Scenario N —" summary prefixes stripped).
> - **#112** — env-UX (**TASK #13**): `scripts/02-env.sh` + `make env-init`/`env-populate`/`env-check`/`env-validate` + `creds`→`creds-show`; models GENERATE/DISCOVER/user-PROVIDE; Harbor auth in `env-validate` via a `umask 077` `curl -K` file (no argv). Verified on a clean checkout, both gates RED-proven, idempotent; README uses `make env-init` everywhere.
> - **#113** — faithful **TWO-BOX e2e-sneakernet**: the air-gap half (`bundle-load`→`mirror-push`→`mirror-verify`) runs INSIDE a FRESH `make jumpbox` container (`JUMPBOX_MODE=airgap-half`) with ONLY the carried tarball — no more same-machine `mv` relocate-sim. Fidelity assert (`bundle/` must be empty) guards host-cache leakage; push creds via `-e` name-only. Live run: 34 images reconstructed→pushed→verified intact, `JUMPBOX_SNEAKERNET_OK`.
> - **Backlog audit:** `bootstrap-jumpbox.sh` + `mirror-prune` (auto in `make mirror-pull`) were already DONE (the old backlog line was stale).
> - **Skill learnings committed** to `~/projects/claude-config`: architecture-diagrams (4096px silent clip + fold + click-to-enlarge), readme (self-contained scenario collapsibles), work-principles (front-load-parallel / fan-out-at-t0 — after a ~3h no-commit stretch the user flagged as procrastination). Earlier lessons (render-scale, bg-job detect/kill, worktree-gate pollution, `.env` runbook, K1.6 EventListener-CaBundle race) also captured.
>
> **ONLY remaining — BLOCKED on external infra (cannot do from here):**
>
> - **vcf-CLI real-lab auth** — `scripts/30-vks-login.sh` ships the verified SHAPE (#103); the open items (non-interactive/stdin password mechanism, exact VCF/VKS 9.1 CLI flags, 9.0→9.1 doc-provenance) ALL require a real VCF/VKS 9.1 lab. NOT reproducible on KinD — see the vcf-CLI research block below.
>
> **Skill lessons captured this session** (`~/projects/claude-config`, UNCOMMITTED — commit that repo): **faithful-over-convenient** (work-principles) · local-`.env`-hides-CI + verify-zero-config-on-clean-checkout (configuration) · K1.6 EventListener-CaBundle webhook race (ci-workflow) · diagram render-scale (architecture-diagrams) · robust background-job detect/kill (git-workflow) · worktree-agents pollute tree-walking gates (agents) · multi-stage `.env` runbook (configuration).
>
> ---

`main` is GREEN. KinD self-signed-TLS fidelity + VCF/VKS lab-CLI + **real-lab install runbook &
helpers** are merged. Design rationale: `docs/decisions/kind-tls-fidelity.md`; real-lab flow:
README §"Run against a real VKS lab" — Scenario 1 (you install Harbor+ArgoCD as Supervisor Services) and Scenario 2 (they already exist; you are a tenant: discover + request). Each scenario is self-contained end to end.

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

**✅ Both former "PENDING next" items are SHIPPED** (the block that listed them was stale):
`bootstrap-jumpbox.sh` exists (curl|bash jump-box entrypoint, OS-gated, validated by the bare-OS
harness), and cache pruning ships as `mirror_prune_cache` (`lib/mirror.sh`), run automatically by
`10-mirror-pull.sh` — there is deliberately no separate `make mirror-prune` target.

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
