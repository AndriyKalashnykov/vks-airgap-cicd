# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An **air-gapped VKS CI/CD demo**: from an internet-connected jump box (Ubuntu or
PhotonOS), mirror all required images into the VKS-provided **Harbor**, install and
wire **Gitea + Tekton**, and demonstrate GitOps CD via the VKS-provided **ArgoCD**.
Harbor and ArgoCD are pre-provided by VKS; we install Gitea + Tekton and the demo app.

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
| `make mirror` | (dual-homed) pull images → push to Harbor |
| `make mirror-pull` / `bundle` / `bundle-load` / `mirror-push` | sneakernet phases |
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
| `make jumpbox` / `jumpbox-both` | Validate the README jump-box bootstrap on a real jump-box container — `JUMPBOX_OS=photon` (default, `photon:5.0`) or `JUMPBOX_OS=ubuntu` (`ubuntu:24.04`); rootless podman, joined to the kind network: runs `make deps` + engine + cluster/Harbor reach. `jumpbox-both` runs the OS matrix. Needs the KinD cluster up |

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
  accepted-by-design misconfigs — gitea RO-rootfs, Traefik secrets RBAC). trivy/gitleaks
  are `.mise.toml`-provided so local `make static-check` mirrors the CI job.

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

## Backlog / resume state (2026-07-10)

Snapshot for picking up next session exactly where this one left off.

**✅ COMPLETE — KinD self-signed-TLS fidelity + VCF/VKS lab CLIs (branch `feat/kind-tls-fidelity`; both e2e modes validated; PR-ready)**

Goal (met): make the KinD stand-in mimic **VCF/VKS 9.1's self-signed TLS** for the VKS-provided
Harbor + ArgoCD, so `make e2e-kind` predicts lab behavior instead of hiding the CA-trust path.
Design + cited research: `docs/decisions/kind-tls-fidelity.md` (rewritten to the **LB-IP sudo-free**
variant + a **"Fidelity vs a real VCF/VKS 9.1 lab" readiness section**). Endpoint = the LB IP
(SAN=IP), CA trusted sudo-free via crane `SSL_CERT_FILE` / podman `--cert-dir` / containerd
`certs.d ca=` / Kaniko `additional-ca-cert-bundle`. Toggles `HARBOR_INSECURE`/`ARGOCD_INSECURE`
(default `0` = secure). ArgoCD on its OWN LB (not the `*.vks.local` ingress), like VKS.

**BOTH modes VALIDATED end-to-end this session (the 4-way matrix, all green):**

- **secure e2e-kind** (fresh, default): `Harbor/ArgoCD mode: SECURE`, CA minted **0644** in-path,
  34 images crane-pushed over TLS, Kaniko built over TLS, `End-to-end verified` + istio ingress `SUCCESS`.
- **insecure e2e-kind** (`HARBOR_INSECURE=1 ARGOCD_INSECURE=1`): `mode: INSECURE`, full loop green.
- **`make jumpbox-both` secure** (Photon + Ubuntu 26.04): Harbor HTTPS+CA reach `HTTP 200`, real lab CLIs installed.
- **`make jumpbox-both` insecure** (both OSes): Harbor HTTP reach `HTTP 200`.

**3 real bugs found + fixed by actually running it (each invisible to a green exit):**

1. **CA-perms uid asymmetry** — `tls.sh` minted certs `umask 077` (0600); Ubuntu 26.04's default
   `ubuntu` user (uid 1000) pushes the jump-box `vks` to uid 1001, which couldn't read the mounted
   0600 CA → misleading `error adding trust anchors from file` (real cause: Permission denied;
   `curl -k` = 200). Fix: CA/leaf are PUBLIC → `chmod 0644` (keys stay 0600). Only the Ubuntu target surfaced it.
2. **jumpbox harness Harbor check hardcoded `http://`** — broken by the secure-TLS default; now TLS-mode-aware.
3. **`make e2e-kind HARBOR_INSECURE=1` silently ran SECURE** — `load_env`'s `set -a; . .env.example`
   clobbered the make-cmdline override; caught by reading the mid-run mode log, not the exit code.
   Fix: comment the toggles in `.env.example` (proven RED→GREEN). Insecure mode was likely never
   truly validated before this.

**NEW feature — `make install-vcf-clis`** (+ granular `install-argocd-vcf`/`install-vcf-cli`/`install-vcf-plugins`):
OS/arch-aware, sudo-free (`~/.local/bin`) install of the Broadcom-LICENSED lab CLIs (`argocd-vcf`,
`vcf` Consumption CLI, plugins). Licensed artifacts operator-supplied via `VCF_CLI_SRC_DIR` (air-gap)
or a gitignored links file; versions pinned in `.env.example`. **Verified with the REAL binaries on
BOTH jumpboxes**: `argocd v3.0.19+…-vcf`, `vcf v9.1.0.0.25296329` (GA), all 7 vcf plugins installed.
Lab-only (the pipeline wires via `kubectl`); documented in the README real-lab flow.

**Research + empirical fact-check (readiness):** Harbor 2.14.3 + ArgoCD (Broadcom operator, 3.x) in
VKS 9.1. Empirical beat doc-inference — the ArgoCD-on-9.0 docs imply 2.14.x, but the operator's real
9.1 `argocd` CLI is **3.0.19-vcf (3.x)**, so our KinD ArgoCD (3.4.5) is the RIGHT generation (did NOT
downgrade). Top residual lab risk (documented, not KinD-reproducible): the workload cluster trusts the
Harbor CA **declaratively** via the Cluster spec `trust.additionalTrustedCAs` + a double-base64
`<cluster>-user-trusted-ca-secret`, not per-node `certs.d`; plus private-project robot accounts + FQDN addressing.

**Learnings captured to `claude-config`** (committed, main, unpushed): empirical-version-beats-doc-inference
and CA-perms-uid-asymmetry (version-discipline), docs-lint-lint-tracked-files (makefile §10 #18),
runtime-toggle-must-be-commented (configuration). `links.md` was removed after both jumpboxes passed (owner's instruction).

**Remaining:** `make ci` (final offline gate) → open PR → merge on green → post-merge sync + watch triggered workflows.

**Merged THIS session (2026-07-10):**

- PR #60 — jumpbox Photon+Ubuntu OS matrix + demo walkthrough.
- PR #62 — backlog refresh.
- PR #63 — air-gap connectivity diagram + README scannability + fixed stale skopeo diagram labels.
- PR #64 — Ubuntu **26.04** rootless-podman `pasta` fix + harness `.env`/`.env.kind` gitignored
  tar-exclude (Renovate had bumped the jumpbox base 24.04→26.04, exposing podman-5's pasta default).
- PR #65 — README: VKS-lab section FIRST + context-split KinD-vs-VKS-lab UI table + `make fetch-harbor-ca`.
- PR #66 — KinD-TLS-fidelity design doc.

Two portfolio rules captured to `claude-config/rules/common/version-discipline.md` (Ubuntu
air-gap jump-box gotchas; no-concurrent-load-during-mirror).

---

**Where things stand:** `main` GREEN. Earlier this arc landed a large hardening + rename set, all merged:

- `/project-review` in full — gates/foundation, ingress-e2e, diagrams, docs, verify-race.
- Whole toolchain aligned to **Java 25** + a `check-java-alignment` drift gate (RED-proven;
  build image `maven:*-temurin-25` and runtime `eclipse-temurin:25-jre` are separate Renovate
  deps, so the gate stops them re-splitting).
- Security gates in `static-check`: `secrets` (gitleaks) + `trivy-fs` (scans the built jar via
  `trivy rootfs`) + `trivy-config` (`.trivyignore` waives gitea RO-rootfs + Traefik secrets RBAC).
- `make verify` ArgoCD race fixed (`refresh=hard` + wait for the deployed image to change).
- Ingress e2e: `verify-ingress` / `verify-ingress-both` (K1.5 route-readiness) + per-host body markers.
- MIT LICENSE; argocd CLI aligned to the server (`v3.4.4`).
- Renovate hardening: cluster-only-tool **MAJORS require Dependency-Dashboard approval**
  (CI has no cluster job); the two kubectl pins (`.mise.toml` + `.env.example`) grouped.
- **Repo renamed `vks-cicd` → `vks-airgap-cicd`** (all in-repo refs aligned; GitHub redirects the old URL).
- **App relocated `./app` → `./apps/java/webui`** (PR #48 — `apps/<lang>/<name>` layout; `APP_DIR`/`MVN`,
  builder/seed/alignment/lint scripts, README, CLAUDE.md, `.env.example` updated; `trivy-config --skip-dirs`
  moved with the tree). README `Prerequisites` now precedes `Tech stack`. Verified offline (`make ci`) + live
  (`make builder-image` from the new path pushed to Harbor).
- **Ingress body markers LIVE-CONFIRMED** (istio `e2e-kind`): `gitea.vks.local` / `argocd.vks.local` /
  `app.vks.local` each served its own UI through the LB — the `gitea`/`argo`/`class="message"` asserts in
  `scripts/98-verify-ingress.sh` match real served HTML.
- **Context-aware credentials UX** (PR #50): `make creds` (URLs + logins table) + `make argocd-password`
  (self-resolves the kubeconfig; `.env` value → generated secret → VKS-lab guidance). KinD install can set
  the ArgoCD admin password from `ARGOCD_ADMIN_PASSWORD` (`.env`).
- **Tekton Dashboard** (PR #52): read-only web UI at `tekton.vks.local` — mirrored air-gap
  (ghcr.io → Harbor), installed into `tekton-pipelines`, ingress-routed on **both** istio + traefik; added
  to the C4 diagrams. Also fixed `44-install-ingress` so an explicit `INGRESS_CONTROLLER` override wins
  over `.env.kind` (so `verify-ingress-both` actually flips controllers).
- **Photon 5 / Ubuntu jump-box bootstrap** (PR #53): README "Bootstrap a bare jump box" (tdnf TLS-stack
  refresh, SSH keypair, clone) + `make deps` split into atomic `deps-mise` / `deps-prereqs`.
- **crane replaces skopeo as the mirror engine** (PR #54): static Go binary, mise-native
  (`.mise.toml` `crane = "0.21.7"`); `lib/mirror.sh` `mirror_platform_arg` + retry helper, `10-mirror-pull.sh`
  `crane pull --format=oci`, `21-mirror-push.sh` `crane auth login` + `crane push --insecure`. Multi-arch by
  default. Verified: 34 images mirrored to Harbor, 0 failures. Chosen after 3-agent research (imgpkg ruled out).
- **`make jumpbox` — Photon 5 validation harness** (PR #54): runs the README bootstrap on a real `photon:5.0`
  container (rootless podman, joined to the kind network). Caught + fixed **5** real bootstrap bugs:
  `mise trust`, `tkn` arch-404 (uname vs Go arch), skopeo-not-on-Photon, missing `crun`, commented-only
  `unqualified-search-registries` (all now in `00-install-prereqs.sh`, the real path).
- **Uniform brightgreen badges** (PR #57): fixed the yellow MIT license badge; all four badges the same shade.
- **Jump-box OS matrix — Photon + Ubuntu (PR #60):** the Photon-only harness became an OS matrix.
  `make jumpbox JUMPBOX_OS=photon|ubuntu` (default `photon`) + `make jumpbox-both`; `Dockerfile.jumpbox`
  → `jumpbox/Dockerfile.{photon,ubuntu}` (both hadolinted via `scripts/lint.sh`); `jumpbox-run.sh` is
  OS-generic with an `ENGINE` var. **Live-validated on real `photon:5.0` AND `ubuntu:24.04` — both reach
  `JUMPBOX_OK`** — which surfaced 2 real Ubuntu jump-box bugs, fixed in the REAL `make deps` path (not
  just the harness image):
  1. `apt --no-install-recommends podman` pulls `crun` (a Depends) but DROPS `uidmap`/`slirp4netns`
     (Recommends) → rootless `make builder-image` would fail `newuidmap: command not found`.
     `00-install-prereqs.sh` now installs the rootless deps per distro (apt → `uidmap`+`slirp4netns`;
     tdnf → `crun`, since Photon's podman pulls uidmap/slirp4netns but not crun). `Dockerfile.ubuntu`
     no longer pre-bakes uidmap/slirp4netns, so the harness genuinely VALIDATES that make-deps install.
  2. `jumpbox-run.sh` excludes `./secrets` from the work-dir tar: `secrets/` is gitignored (mode 0600,
     host-uid-owned) and `ubuntu:24.04` ships a default `ubuntu` user at uid 1000, so the container's
     `vks` lands on uid 1001 and couldn't read them → tar failed before `make deps` ran.
  Also dropped a stale dead-code `KUBECTL_VERSION:-v1.31.4` default. `make ci` + `make jumpbox-both` green.
- **README demo walkthrough (PR #60):** new "Demo walkthrough — drive the GitOps loop by hand" — edit the
  greeting in the Gitea web UI → Tekton test/build (Kaniko) → Harbor → tag write-back to `webui-deploy` →
  ArgoCD sync → the live page changes; grounded in real repo names/paths and mirrored by `make verify`.
  Plus OS-matrix wording for the jump box + a per-OS rootless-dep note.

**To resume the stack (if the cluster is down):**

1. `git fetch origin && git checkout main && git reset --hard origin/main` (sync `main`).
2. `make e2e-kind` (full KinD end-to-end). Mirror engine is **crane** (mise-provided, no skopeo).
   `make jumpbox-both` validates the jump-box bootstrap on Photon + Ubuntu (needs the cluster up).

**Open / next-session items (none blocking):**

- [ ] (optional) **ArgoCD Image Updater** for registry-driven redeploy — considered and
      **declined** this session; the Tekton tag-write-back stays the primary GitOps path. Revisit
      only to demo registry-driven deploys or to track externally-built (non-pipeline) images.
- Done (housekeeping): the `spike-crane:*` test images were pruned from Harbor's `cicd` project;
  the jump-box Dockerfiles (`jumpbox/Dockerfile.{photon,ubuntu}`) are hadolinted in the `lint` gate.
- CI runs offline gates only; the KinD e2e is **local by design** (verification-honesty) — a
      decision, not a TODO.
