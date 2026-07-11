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

> ### ⏳ SESSION HANDOFF 2026-07-11 (READ FIRST — resume here)
>
> `main` GREEN; this session merged 6 PRs (#85 handoff, #86 diagram-label, #87
> mirror-verify+cache-skip+progress+resume, #88 idempotency+shellcheck-pin, #89 docs,
> #90 cache-prune). Below: in-flight work + a de-risking backlog + a research thread.
> **Browser NOT needed: WebFetch reads techdocs.broadcom.com AND raw.githubusercontent.com.**
>
> **A. Bootstrap PR — branch `feat/bootstrap-curl-bash` PUSHED (commit a5de333), NOT merged.**
> `bootstrap-jumpbox.sh` = curl|bash jump-box bootstrap (OS-gate → check→install→verify→report);
> `jumpbox/Dockerfile.bootstrap` (ARG BASE + COPY) + `scripts/bootstrap-test.sh` + `make
> bootstrap-test` (from-nothing on a bare-OS matrix). Validated: offline gates green; OS-gate
> (ubuntu/photon supported, fedora rejected exit 1). **MATRIX RESULT (done):** ubuntu:22.04 +
> 24.04 + 26.04 + **photon:5.0** all from-nothing GREEN (all core tools present); **photon:4.0
> FAILS** (older Photon — out of scope) and **fedora-reject failed the ASSERTION** (the OS gate
> DID reject it exit≠0, but bootstrap-test.sh didn't find the `UNSUPPORTED` string — likely the
> `docker build --build-arg BASE=fedora … || true` masking a build/pull issue, OR the message
> needs de-colorizing before grep; investigate the fedora leg).
> **Before merge:** (1) **DROP `photon:4.0`** from `BOOTSTRAP_TEST_OSES` default in
> scripts/bootstrap-test.sh (keep ubuntu:22.04/24.04/26.04 + photon:5.0) + fix the fedora-reject
> assertion; the bootstrap SCRIPT works on all real targets — the 2 failures are matrix/harness,
> not script logic. (2) **README Prereqs restructure (Task 16)** — make curl|bash bootstrap the PRIMARY path,
> collapse the manual git/SSH/clone/mise/make-deps steps under `<details>`, add the curl-prereq
> note (**bare Photon 5 ships NO curl** → pipe form needs `sudo tdnf install -y curl` first;
> verified). `.markdownlint.json` has `MD033:false` so `<details>` is fine. (3) `make ci`, PR, merge.
>
> **B. Diagrams PR (Task 15) — own branch.** Deployment+Container connectors intersect; pipeline-flow
> too short. Add `skinparam nodesep`/`ranksep` to `docs/diagrams/_style.puml`; switch
> `pipeline-flow.puml` to `LAYOUT_TOP_DOWN()`. `make diagrams` + **EYEBALL each PNG** (Read the
> images) to confirm, iterate values; commit PNGs (diagrams-check gate).
>
> **C. README readability PR (Task 17) — own branch.** README is 870 lines. Wrap in
> `<details><summary>descriptive</summary>` (blank line after summary; MD033 ok): "Run against a
> real VKS lab" (339L, biggest win), "Demo walkthrough" (74L), "Detailed steps" (42L),
> "Make targets" (22L), "Repository layout" (15L), "CI/CD" (12L). KEEP expanded: intro,
> Prereqs(bootstrap), Tech stack, Quick Start, Architecture, Try-with-KinD, Access the UIs. ~250 visible.
>
> **D. Real-lab research thread (user-requested).** Compare our impl (`scripts/01-install-vcf-clis.sh`,
> `30-vks-login.sh`, README "Run against a real VKS lab") with real-jumpbox experience + Broadcom
> techdocs; fold accurate `vcf`-CLI flow into the README. Sources (all WebFetch-able):
>
> - `raw.githubusercontent.com/ogelbric/LAB/main/VCF-CLI/README.md` (FETCHED). Real flow:
>   `vcf context create --endpoint https://<sup-IP> --username administrator@WLD.SSO
>   --insecure-skip-tls-verify --auth-type basic` → name ctx; `vcf context use <ctx>:<ns>`;
>   `vcf plugin install all --local-source <bundle>`; kubectl-vsphere via
>   `wget https://<sup-IP>/wcp/plugin/linux-amd64/vsphere-plugin.zip`; `vcf package repository add`
>   then `vcf package install istio`. **GOTCHAS:** configure Harbor cert+creds BEFORE creating guest
>   clusters (else deploy fails); `kubectl label ns default pod-security…/enforce=privileged`;
>   wildcard DNS A-record → ingress LB IP.
> - ogelbric `where_is(are)/Create_Harbor` (FETCHED). Harbor-as-Supervisor-Service real flow:
>   upload `harbor-sys.yaml` + `harbor-data-values.yaml` via Supervisor Mgmt → Services → Add;
>   edit data-values: `hostname: <fqdn>`, `enableNginxLoadBalancer: true`,
>   `enableContourHttpProxy: false`, storage class `vsan-default-storage-policy`; Actions → Manage
>   Service → paste YAML; get LB IP from Network→Services; DNS FQDN→LB IP; default `admin/Harbor12345`;
>   CA into `/etc/docker/certs.d/<fqdn>/ca.crt` (strip trailing CR); `docker login <fqdn>`. GOTCHA:
>   remove trailing CR from the cert. Compare vs our README Harbor-as-VCF-Service section + fetch the
>   Broadcom "Installing and Configuring Harbor as a VCF Service" techdoc to reconcile.
> - Broadcom techdocs `.../9-1/using-argo-cd-service/install-argo-cd-service.html` (FETCHED —
>   confirms ArgoCD **server** CR `spec.version: 2.14.15+vmware.1-vks.1`; `vcf context create
>   mgmt-cluster --endpoint <IP> --type k8s`; `kubectl explain argocd.spec.version`). Also research
>   the Harbor-as-VCF-Service + VCF-CLI techdocs for real-lab accuracy.
>
> **E. De-risking backlog (holistic risk scan this session — all 4 scans returned).** All LOCAL/cheap;
> close coverage on first-class modes with none today:
>
> 1. **`make e2e-sneakernet`** — the sneakernet `bundle → bundle-load → mirror-push → mirror-verify`
>    round-trip (into a FRESH dir) has ZERO coverage; a break ships to real air-gap operators. TOP.
> 2. **Wire `mirror-verify` INTO `e2e-kind`** (after mirror) + a **RED test** (corrupt a blob →
>    assert INTEGRITY FAIL exit≠0). The integrity gate is only ever observed green.
> 3. **Dispatch/scheduled CI e2e** — CI runs ONLY offline gates; ~30 scripts (05–99) can regress +
>    merge green (a human edit to a TLS/manifest/pipeline script, or a cluster-tool MINOR bump).
>    Add `workflow_dispatch` + weekly `make e2e-kind` (or a reduced kind-up+harbor+mirror+verify
>    smoke) on a big runner; never blocks PRs.
> 4. **`trivy image` CVE scan** — `trivy-fs` scans ONLY the app jar's deps; no `trivy image` on the
>    app runtime image, the Maven builder image, or the mirrored bases → base-OS/JRE CVEs merge green.
>    Add a `trivy-image` target into `sec`.
> 5. **`make test-vcf-cli-resolve`** — synthetic fixtures (fake gz / tar.gz / nested multi-arch) for
>    01-install-vcf-clis.sh's glob/tar-vs-gz branch logic (untested; breaks only on a real lab box).
> 6. **`e2e-kind-both`** (secure+insecure matrix, mirror verify-ingress-both's pattern) — non-default
>    TLS mode can regress + merge green.
> 7. **cache-skip/resume/prune tests** (seed wrong-digest `.mirror-ok`→re-pull; correct→skip;
>    orphan→pruned) + **smoke real-lab helpers in e2e-kind** (`argocd-preflight` assert `TOPOLOGY OK`
>    string not exit-0; `fetch-argocd-ca` non-empty; `harbor-robot` env written).
> 8. Minor: `Dockerfile.builder` gets neither hadolint nor trivy-config (add to lint.sh hadolint loop);
>    `50-seed-gitea-repos.sh:46` comment ("not in argv") is misleading — the gitea-pod `ps` sees the
>    password; add a prose-secret grep gate over `*.md` to `sec`.
> 9. **[PROVEN, one-line — do it in the bootstrap branch's .env.example to avoid a conflict]** comment
>    `MIRROR_ARCH`/`MIRROR_ALL_ARCH` (.env.example:195,197) — uncommented runtime toggles, so
>    `make mirror MIRROR_ALL_ARCH=1` is silently clobbered back to single-arch (same class as the
>    already-fixed HARBOR_INSECURE; the sibling MIRROR_RETRIES/FORCE_PULL/NO_PRUNE are already
>    commented). Prove RED→GREEN: `MIRROR_ALL_ARCH=1 bash -c 'set -a;. ./.env.example;set +a;echo $MIRROR_ALL_ARCH'` must print 1.
>    Also (docs-scan): add `VKS_AUTH_METHOD` (commented) to .env.example §6 (auth selector, read by
>    30-vks-login.sh, undocumented in the source-of-truth file); `GITEA_CA_FILE` is a DEAD tunable
>    (Gitea is HTTP-only — drop or comment "reserved"); the maven **build-image** tag
>    (`maven:3.9-eclipse-temurin-25` in the two app Dockerfile ARGs + 15-build-push-builder.sh) is NOT
>    covered by check-image-alignment (extend it, or soften the CLAUDE.md coverage claim).
>
> **E2. Robustness scan findings (the `grep -q`/`head` under `set -o pipefail` SIGPIPE class — sweep it):**
>
> - **HIGH** `01-install-vcf-clis.sh:99,100,117,132` `x="$(find … | head -1)"` inside a `set -e`
>   function → on **≥2 matches** (a multi-arch bundle, expected!) `head` exits, `find` gets SIGPIPE
>   (141), pipefail aborts the script RIGHT AFTER finding the binary. Fix: `find … -print -quit`
>   (no pipe). (The `[ -n "$(find…|head -1)" ]` on :98 is safe — inside `[ ]`.)
> - **MED** `05-kind-up.sh:45` — the health-check I ADDED this session, `kubectl get nodes | grep -q
>   ' Ready'`, can SIGPIPE → false → **delete a HEALTHY cluster**. Capture-then-test: `nodes="$(kubectl
>   … || true)"; printf '%s\n' "$nodes" | grep -q ' Ready'`.
> - **MED** `98-verify-ingress.sh:81` `printf "$b" | grep -qiE` — large captured page > 64KB pipe buf →
>   printf SIGPIPEs → false "wrong backend" on a page that WAS served. Drop `-q` (grep drains all).
> - **MED** Makefile `jumpbox` recipe (:259,261) + `check-image-alignment.sh:22,58` +
>   `check-java-alignment.sh` — `x="$(grep … | cut)"` under `.SHELLFLAGS=-eu -o pipefail`: a missing
>   `.env.kind`/absent key makes grep exit 1/2 → the assignment aborts the recipe BEFORE the friendly
>   `[ -n ] || { echo ERROR; exit 1; }` guard (dead code). Add `|| true` to the grep.
> - **LOW** `50-seed-gitea-repos.sh:140` (the webhook idempotency check itself has `grep -q` — could
>   dup on a large body), `99-verify.sh:131`, `07-install-argocd.sh:131`. Same capture-then-grep fix.
>   Unifying rule already in coding-style.md; the libs + most install scripts are otherwise robust.
>
> **G. VKS-auth section is thin — rewrite + AUTOMATE (user-requested).** README "VKS authentication
> (VCF 9 + Supervisor)" (~6 lines) needs: clear ".env inputs to provide" + "commands to execute" +
> **Makefile targets/scripts automating the manual repeatable steps.** Use the real `vcf`-CLI flow
> from section D (`vcf context create --endpoint https://<sup-IP> --username <admin>@<SSO-domain>
> --insecure-skip-tls-verify --auth-type basic` → ctx name → `vcf context use <ctx>:<ns>`; kubectl-
> vsphere from `https://<sup-IP>/wcp/plugin/linux-amd64/vsphere-plugin.zip`) — compare with
> `scripts/30-vks-login.sh` (which has a `vsphere`/`kubeconfig`/`vcf(stub)` method switch) and FLESH
> OUT the `vcf` method into a real `make vks-login`-driven flow. Add `.env` vars (SUPERVISOR_HOST,
> VKS_NAMESPACE, VKS_CLUSTER_NAME, VKS_USERNAME, VKS_AUTH_METHOD=vsphere|vcf) with clear docs. Research
> the Broadcom VCF-CLI + "Install the Argo CD Service" + Harbor-as-VCF-Service techdocs (WebFetch-able)
> for exact field names before writing.
>
> **F. Global config captured this session (on disk in ~/projects/claude-config, UNCOMMITTED — commit
> that repo separately if desired):** coding-style.md (`A && B`-last-statement trips caller set -e),
> testing.md (bare-image-testing corollary), + 2 memory files (stale-peek guard;
> implement-what-user-literally-describes).
>
> **Cluster: torn down. Note:** a `make bootstrap-test` matrix + 2 risk-scan agents (robustness, docs)
> may still be running from the prior session (nohup/harness) — ignore/re-run.
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

**Declined (decision, not a TODO):** ArgoCD Image Updater for registry-driven redeploy — the Tekton
tag-write-back stays the primary GitOps path; revisit only to demo registry-driven deploys.
