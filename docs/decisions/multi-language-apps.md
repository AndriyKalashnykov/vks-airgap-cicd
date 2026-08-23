<!-- Committed 2026-08-22 from the session scratchpad. It had been reviewed by six
     adversary rounds and was still living only in /tmp, one session-end away from being lost.
     STATUS: DESIGN ONLY -- no app code exists yet (apps/ holds go and java; registry.tsv has
     two rows). Every claim here is to be refuted again before code moves. -->

# PLAN v3 — three apps (rust / nodejs / dotnet), on parametrized machinery

STATUS: DESIGN ONLY. v1 and v2 were each reviewed by adversaries; this folds in what they MEASURED
and what the owner then decided. To be refuted again before any code moves.

## OWNER DECISIONS (settled — do not re-litigate)

1. **THREE languages**: `rustwebapp`, `nodejswebapp`, `dotnetwebapp`. An adversary argued for one;
   the owner's scope stands.
2. **`nodejswebapp` is THE BUILDER APP** — it gets real npm dependencies, baked into a
   `Dockerfile.builder` on the internet side, built with `npm ci --offline`.
3. **Per-app builder tag.**
4. **Everything parametrized, configurable, productized, documented. No hardcoded values.**
5. **Every app renders the SAME UI layout**, differing only in app-specific data.

## WHAT IS ALREADY FIXED AND MERGED (out of this plan)

- `check-app-toolchains` printed FATAL, then OK, then exited **0** on an unhandled lang.
- `for_each_app` — the function ALL EIGHT callers loop through — iterated zero apps on a broken
  registry while every caller reported success (`99-verify.sh` printed "verified for EVERY app ()").
  Both were the `for x in $(fn)` / heredoc-swallows-die shape. PR #944, RED-proven both directions.

## MEASURED FACTS THIS PLAN RESTS ON (all `ran-it`)

| fact | value |
|---|---|
| `dotnet publish --network none` on `sdk:9.0-alpine` | **rc=0**, restored in 46 ms — dotnet is ZERO-DEP, not builder-like |
| `PublishAot` offline | rc=1 after 3 min (ILCompiler from nuget.org) AND `clang`/`ld.lld`/`libz.a` absent — **NativeAOT is dead on alpine SDK** |
| rust zero-dep | `cargo build --network none` rc=0; `file` → **static-pie**; `readelf -d` → no NEEDED; **ran on the exact `sha256:afa5c87…` digest in `images/images.txt`** |
| `npm ci --offline` | true single-flag analogue; cold-cache control fails **instantly** (ENOTCACHED) |
| NuGet offline | needs `NUGET_PACKAGES` **plus** `<clear/>`; miss the second → rc=0 but **59.81 s vs 102 ms** |
| per-language `case` branches | **10**, not 7 (`lib/apps.sh` ×7 + `app-test.sh` + `app-run.sh` + `trivy-fs.sh`) |
| `PSA_LEVEL_APP` | **ONE GLOBAL** for all app namespaces; no per-app override |
| `aspnet:9.0` default USER | **ROOT**. `aspnet:9.0-alpine` **48 MB**, `-noble-chiseled` uid **1654** / 49 MB |
| `node:24-alpine` default USER | **ROOT** — but `node:x:1000:1000` exists, so `USER node` is restricted-clean |
| walked docs invoking mvn/go/java/npm | **ZERO** — the walkbox installs java+maven+go and never uses them |
| scenario docs naming an app | 0 of 52 `Expect:` lines; 2 in a NEUTRALIZED block; 3 in prose |
| `make verify` timing | java 87s, **go 112s** — the zero-dep app is SLOWER (Kaniko, no cache) |
| bundle live content | **8.1 GB** (docs say "~12 GB" in 3 places — inflated by a stray 5.2 GB pre-plain-tar `.zst`) |

## PHASE A — PARAMETRIZE (no new apps)

**A1. De-Maven `14-builder-build.sh`.** Four hardcodes applied to EVERY builder app: `MAVEN_SRC`
(:57), the `docker.io/library/maven` path (:62), the build-arg NAME `MAVEN_IMAGE` (:88), inside the
`BUILDER_APPS` loop (:70). A node builder would receive `MAVEN_IMAGE=<maven digest>` — an ARG its
Dockerfile never declares, **silently dropped**, leaving its base unpinned. New hooks in
`lib/apps.sh` (the gate-exempt home): `app_builder_base`, `app_builder_base_path`, `app_builder_arg`.

**A2. Per-app builder tag → a 5th column in `apps/registry.tsv`.** `check-app-hardcodes` exempts
`apps/registry.tsv` and `lib/apps.sh` by design (:17, :59) — the only home that keeps "ONE ROW"
literally true. `BUILDER_IMAGE_TAG` stays as the default for an empty column (back-compat).
⚠️ An adversary measured that per-LANGUAGE tags would also pass the gate and that the *repo* is
already per-app (`app_builder_image` derives `<app>-builder`); the owner chose per-app anyway. Cost
is one column, so this is cheap either way.

**A3. Generalize `check-image-alignment.sh`** — three Maven-specific arms (:210, :221, :229) plus an
exemption note (:256-259). Must become per-builder-app loops or it silently stops covering builder #2.

**A4. A COMPLETENESS gate.** 10 branches × 5 languages = 50 arms, nothing asserting coverage, and
**6 of 10 are LIVE-only** — a forgotten one is found by a red certification row, not by
`static-check`. Gate: for every registry `lang`, call every per-language function; fail if any dies.
⚠️ NEW CONTROL → its own idea-round before it is written.

**A5. Tekton hygiene, before the third app.** No PipelineRun pruner; every run gets a **2Gi**
`volumeClaimTemplate` owner-ref'd to the run, nothing reaps them → 5 apps = **10Gi per `make verify`,
accumulating**. And **zero `resources:`** in any task, while a warm-cluster re-run fans out N
concurrent Kaniko builds (`50-seed-gitea-repos.sh` pushes before registering the webhook).

**A6 (MOVE A — free win).** The walkbox installs java+maven+go via `make deps` on all six rows and
**never uses them** (zero invocations in either walked doc). Java is the largest artifact and has a
RECORDED cold-download failure (row 3: 13 of 17 tools installed, only java failed). Split `[tools]`
so the walk installs the infra set only. Pure de-risking of a run that must pass FIRST TIME.

**A7 (MOVE B — deferred, idea-round first).** Containerize `app-test`/`app-build` so a language needs
no host toolchain at all. Then rust and dotnet add ZERO `.mise.toml` entries and the PhotonOS
`mise install dotnet` unknown disappears instead of being managed. Costs: `trivy-fs` scans the built
jar at `<src>/target/*.jar`, so the container build must mount the artifact out; and
`check-java-alignment` + Renovate both anchor on the `.mise.toml` entries, so those anchors RELOCATE
(to `pom.xml` + `images.txt` + the Dockerfile) rather than disappear.

## PHASE B — THE SHARED UI (owner requirement 5)

Measured: the Java Thymeleaf template and the Go inline template already share the layout and the
**CSS block is duplicated verbatim**. Two hand-maintained copies today, five tomorrow, nothing
asserting they stay identical. Each app dir IS its own Gitea repo, so the markup must live in each app.

**Ship the CONTRACT first, the generator only if drift appears:**

- each app renders its page with FIXED inputs and prints it (a test mode it already needs for unit tests);
- a gate masks the app-specific fields (name, version, commit, message) and asserts the five outputs
  are **byte-identical**;

- that measures the OBSERVABLE — which is exactly what "same look and feel" means — and is
  language-agnostic, offline and deterministic.
A generator + `git diff --exit-code` drift gate PREVENTS drift instead of detecting it; it is the
right second step, not the first.

## PHASE C0 — gowebapp GAINS REAL DEPENDENCIES (owner decision)

`gowebapp`'s `go.mod` has **no `require` block and no `go.sum`** — genuinely zero-dep, and
unrealistic: a real Go service has dependencies. Giving it one unlocks the pole nobody demonstrates.

- **`go mod vendor`** commits `vendor/` into the app dir — which IS the `<app>-app` Gitea repo, so
  the dependencies literally travel in GIT. That is the third air-gap strategy, and it needs NO
  builder image and NO network at build time.

- Dockerfile: `COPY go.mod go.sum ./` + `COPY vendor/ ./vendor/`, build `-mod=vendor`.
- **Router: `chi` or `echo` — OPEN, being measured** (vendor-tree bytes, file count, transitive
  module count, and whether the binary stays static). Both are pure Go; the deciding numbers are
  carry size and `net/http` compatibility.

- **Templating stays stdlib `html/template`** (owner decision) — a Go-specific UI kit would make Go's
  rendering diverge from the other four, which the shared-layout contract forbids. `templ` was
  considered and rejected on that ground plus its code-generation step (another binary across the gap
  and a generate-then-commit drift gate).

- ⚠️ **`CGO_ENABLED=0` and the static-ness gate are now load-bearing for Go too**, not just Rust: the
  runtime is `distroless/static`, which works ONLY while the binary is static. Any dependency that
  pulls C breaks it — **air-gap-only, invisible on KinD**. The chosen router must be pure Go, and
  `file <bin> | grep -q static` must be asserted in the app's own test.

- This changes an app that is CURRENTLY CERTIFIED, so it needs the same e2e proof as a new one.

## PHASE C — FIVE APPS, THREE POLES

| app | lang | pole | deps travel via | build | runtime |
|---|---|---|---|---|---|
| `javawebapp` | java | **builder image** | `~/.m2` baked | maven 166 MB | temurin-jre 99 MB |
| `gowebapp` | go | **vendored in git** ← changed | `vendor/` in the repo | golang 283 MB | distroless/static 1 MB |
| `nodejswebapp` | nodejs | **builder image** | `node_modules` baked | node:24-alpine 56 MB | same + `USER node` |
| `rustwebapp` | rust | **vendored in git** | `cargo vendor` (pure-Rust crates only) | rust:1-alpine 333 MB | distroless/static — **0 new** |
| `dotnetwebapp` | dotnet | **none** (measured) | nothing | sdk:9.0-alpine 255 MB | aspnet:9.0-alpine 48 MB |

Two apps per pole except "none", which dotnet holds alone and holds HONESTLY — measured, a
framework-only ASP.NET app publishes with `--network none` in 46 ms.

### the original PHASE C table (superseded, kept so the change is legible)

| app | story | build | runtime | PSA |
|---|---|---|---|---|
| `nodejswebapp` | **BUILDER** — real npm deps, `npm ci --offline` | `node:24-alpine` 56 MB + `<app>-builder` | same image + **`USER node`** (uid 1000) | restricted ✅ |
| `rustwebapp` | zero-dep | `rust:1-alpine` 333 MB | `distroless/static:nonroot` — **already mirrored, 0 new** | restricted ✅ |
| `dotnetwebapp` | zero-dep (measured — NOT a builder) | `sdk:9.0-alpine` 255 MB | **`aspnet:9.0-alpine` 48 MB** | needs a non-root uid — verify |

**`PSA_LEVEL_APP` STAYS `restricted`; "all five apps restricted-clean" is an acceptance criterion per
PR.** Relaxing it for one app silently downgrades the other four. If one ever genuinely needs
`baseline`, that is a design change (a per-app PSA key), never a var edit.

New mirrored bytes: 56 + 333 + 255 + 48 = **692 MB** compressed. PLUS the node builder's own tarball
in `bundle/builders/` (the Java one measures **593 MB** because `podman save` is uncompressed).

**Rust needs a static-ness gate**: it runs on distroless/static ONLY because the binary is
static-pie. The day someone adds a C-dep crate (OpenSSL, ring) it stops being static and the runtime
breaks — **air-gap-only, invisible locally**. Assert `file <bin> | grep -q static-pie` in its test.

Order: **nodejs → rust → dotnet**.

## SEQUENCING AND CERTIFICATION

Each PR: green `static-check` + a local `make e2e-kind` proving THAT app's loop end-to-end.
**The matrix runs ONCE, at the end, over the final tree — not per PR.** §A.2 certifies a TREE; three
matrices would be ~19h for one result. Saying this explicitly because a reader who conflates
"validated" with "certified" will run it three times.

⚠️ **KinD enforces NO PSA; VKS enforces `restricted`.** So a missing `seccompProfile` in a new app's
deployment is green on every PR and rejected at admission on a certification row. Each app's PSA
block is hand-written per app (`deploy/<app>/deployment.yaml`) and `check-app-hardcodes` exempts
`deploy/<app>/`. `make psa-check` is the offline read; run it before each PR merges.

## PHASE D — DOCUMENTATION (owner requirement 4)

- `docs/adding-an-app.md` says "Only two things differ per language" — **measured 10**. The SAME false
  claim is at `scripts/lib/apps.sh:6`, the header a maintainer reads while adding the branches. Fix
  both or the second re-seeds the first.

- `lib/istio.sh:501` logs "admits all three UI hosts" (checks 4 today, 7 at five apps).
- `.env.example:877` names javawebapp restricted-clean, omits gowebapp.
- `README.md:42`, `docs/tech-stack.md:15`, `docs/sizing.md:24` assert "two apps", no gate.
- `docs/sneakernet.md` says "~12 GB" in 3 places; live content is **8.1 GB**.

## STILL UNMEASURED

- Whether the chiseled/alpine dotnet runtime starts a published app under `readOnlyRootFilesystem:
  true` (the Java app needed a `/tmp` emptyDir for exactly this).

- Whether 5 concurrent Kaniko builds OOM the walkbox (builds are sequential via `for_each_app`, so
  this only bites on a warm-cluster re-run).

- Rust/dotnet Kaniko build TIMES — nobody has run either in this pipeline. Go's 112s is the anchor,
  and rustc is slower.

## ══ v3.1 — OWNER DECISIONS + MEASURED VERSION CORRECTIONS (supersedes the tables above) ══

**SIX apps. Python IN, C++ OUT** (gcc:16 is 535 MB — 42% of the whole addition — for a lesson that
partly overlaps what Go and Rust already imply via `distroless/static`).

| app | version (VERIFIED today) | build | MB | runtime | MB | USER | pole |
|---|---|---|---|---|---|---|---|
| `javawebapp` | java **25 LTS** | maven:3.9-eclipse-temurin-25 | 166 | eclipse-temurin:25-jre | 99 | — | builder image |
| `gowebapp` | go **1.27** + **chi v5.3.2** | golang:1.27-bookworm | 283 | distroless/static:nonroot | 1 | 65532 | vendored in git |
| `nodejswebapp` | node **24 LTS "Krypton"** | node:24-alpine | 56 | same + `USER node` | — | 1000 | builder image |
| `rustwebapp` | rust **1.97** | rust:1.97-alpine | 333 | distroless/static | **0 new** | 65532 | vendored in git |
| `dotnetwebapp` | .NET **10.0 LTS** | sdk:10.0-alpine | 271 | aspnet:10.0-noble-chiseled | 53 | **1654** | none |
| `pythonwebapp` | python **3.14** + **Flask** | python:3.14-alpine | 17 | distroless/python3:nonroot | 19 | 65532 | OPEN (see below) |

### version corrections — every one of my picks was stale

- **.NET 9.0 -> 10.0**: 9.0 is `support=maintenance` STS. 10.0 is `lts`, `support=active`, 10.0.11.
- **rust: pin 1.97, NOT 1.98.** 1.98.0 released 2026-08-20 = **2.02 days old**, and this repo's own
  Renovate convention is `minimumReleaseAge: 3 days` on EVERY group. Pinning it would break the same
  cooldown currently holding kubectl and Java. Let Renovate take it.

- **node 24 was RIGHT, 26 would have been wrong**: v26.7.0 is `lts=no` (Current); v24.19.0 is
  `lts=Krypton`. "Latest" and "latest stable" diverge here.

- gcc:16 and python:3.15 checked: 3.15 ABSENT, gcc:17 ABSENT.

### Flask, measured on musl (the trap that did NOT fire)

`pip download --only-binary=:all:` inside `python:3.14-alpine`: **flask OK, 636 KB, 7 wheels**;
fastapi+uvicorn OK, 3512 KB, 13 wheels. So neither needs a source build on musl — but Flask is 5.5x
lighter and **Jinja2 ships in those 7 wheels**, which is what the shared-layout contract needs.
FastAPI is API-first and the wrong tool for a server-rendered page.

⚠️ **Python's POLE IS OPEN.** Its distinctive lesson is that an INTERPRETED language's dependencies
must be present at RUNTIME (site-packages in the final image), not compiled away. Two honest routes:
a committed **wheelhouse** (`pip install --no-index --find-links`, the canonical enterprise move,
636 KB is small enough to commit) -> vendored-in-git; or a **venv baked in a builder** and COPIEd
into the runtime -> builder image. Note node is ALSO interpreted, so it shares this property —
which weakens "python is the only one that shows it". Decide with an adversary, not by taste.

## ══ v3.2 — THREE BLOCKERS FOR PHASE C0, ALL MEASURED, ALL IN-CLUSTER-ONLY ══

Every offline gate stays GREEN on all three. Only `make e2e-kind` or a certification row goes red.

1. 🔴 **`k8s/tekton/tasks/go-test.yaml` IS AN ANTI-DEPENDENCY TRIPWIRE, BUILT ON PURPOSE.** Its own
   description: *"GOFLAGS=-mod=mod with GOPROXY=off makes that explicit — if a dependency is ever
   added, this task FAILS loudly in the air gap."* Phase C0 trips it BY CONSTRUCTION. Fix:
   `GOFLAGS: -mod=vendor`, and REWRITE the description — it currently documents the opposite intent.
   The task is shared by every future Go app.
2. 🔴 **`docs-lint` selects `*.md` DEPTH-AGNOSTICALLY** (`Makefile:1540`, only `docs/reviews/`
   excluded). chi's 4 vendored markdown files produce **233 errors** under the repo's own
   `.markdownlint.json`, and editing them is meaningless — the next `go mod vendor` reverts it.
   Fix: exclude `/vendor/` beside the existing exclusion.
3. 🔴 **`gomod` is NOT in `enabledManagers`** (`maven, dockerfile, github-actions, mise,
   custom.regex`). A `require` block yields **ZERO Renovate PRs, forever, silently** — the dep ages
   with no bot and no gate until a scheduled `trivy-fs` reddens `static-check` with nobody assigned.
   Fix: add `gomod`; re-vendoring is then automatic (Renovate runs `go mod vendor` and commits it).

## ══ v3.3 — CORRECTIONS TO MY OWN REASONING ══

- **chi is confirmed, but NOT for the reasons I gave.** With `newMux` returning `http.Handler`, the
  repo's `main_test.go` is **byte-identical and passes against BOTH** chi and echo — my "echo means
  rewriting the tests" was FALSE. Carry size does not decide it either (312 KB vs an 8.1 GB bundle).
  What decides it: **2 total modules / 0 transitive (chi) vs 20 (echo)**, and **0 vs 1 fixable HIGH
  today** — echo ships **CVE-2026-56852** (`golang.org/x/text 0.38.0`). echo also pulls
  `golang.org/x/crypto` and `golang.org/x/net`, the two modules this repo's history shows getting
  CVE'd in waves; chi has zero transitive deps so it cannot participate.

- **The router is not the requirement — HAVING A DEPENDENCY is.** On the owner's literal criterion
  ("best compatible with go native http standards") stdlib `ServeMux` wins outright: it IS the
  standard and already does method matching and `{$}`. chi's concrete gain here is small and real —
  a panicking handler gives the client `EOF` under stdlib vs a clean 500 with
  `middleware.Recoverer`. Say it this way or the next reader re-opens the router debate.

- **My cgo gate was FALSE-GREEN on the only class that ships broken.** Measured: a cgo-ONLY dep with
  `CGO_ENABLED=0` fails LOUDLY at build time, identically everywhere (so "air-gap-only, invisible on
  KinD" was wrong); but a dep with a `!cgo` STUB (`mattn/go-sqlite3`) builds rc=0, `file` says
  "statically linked", and PANICS at first use. Keep `file | grep -q static` but restate its reason:
  it guards `CGO_ENABLED=0` being dropped from the Dockerfile. For cgo deps, assert the module graph
  (`go version -m`).

- **My justification for C0 was false against my own table.** I wrote that gowebapp deps "unlock the
  pole nobody demonstrates" — but `rustwebapp` is already assigned to vendored-in-git. The pole is
  demonstrated either way. The honest reason is REALISM plus two-apps-per-pole symmetry.

- **17 assertions across 12 files say gowebapp is stdlib-only, SIX of them IN CODE** (lib/apps.sh x3,
  the Dockerfile x3, plus `trivy-fs.sh:48`, `check-image-alignment.sh:201`, `14-builder-build.sh:48`,
  `go-test.yaml`, and `main.go`'s whole header docblock, whose thesis inverts). Sweep all 17 in the
  same PR; the code comments first.

- **A vendored dep ships its own `.gitignore` and the Gitea seeding HONOURS it** —
  `50-seed-gitea-repos.sh:266-272` does `cp -a` then `git add -A`. chi's is inert today; echo's has a
  bare `vendor` line. When it fires the Tekton clone gets an incomplete tree -> `inconsistent
  vendoring`, in-cluster only. Fix: `git add -A -f`, or assert seeded file-count parity.

- **gitleaks does NOT scan `vendor/`** (measured: an identical planted token is caught at top level,
  missed under vendor). Accepted residual — name it so nobody reads a green `make secrets` as
  covering vendored code.

## ══ v3.4 — PHASE E: DOCS AND DIAGRAMS (owner requirement, MEASURED SCOPE) ══

"Add them to all respectful *.md files and diagrams" is a concrete, enumerable job. Measured today:

### 18 `.md` files name an app — but they are THREE different kinds, and only one kind gets updated

| kind | files | action |
|---|---|---|
| **LIVE STATE** — asserts how things ARE | `CLAUDE.md` (16 hits), `README.md`, `docs/architecture.md` (3), `docs/tech-stack.md`, `docs/repository-layout.md` (2), `docs/adding-an-app.md` (2), `docs/sizing.md` (4), `docs/demo-walkthrough.md` (9), `docs/scenario-1.md` (2), `docs/scenario-2.md` (3), `docs/lab-recovery.md` (2), `docs/lab-validation-plan.md` (2), `docs/vks-services/istio.md`, `docs/decisions/istio-on-vks.md`, `docs/decisions/kind-tls-fidelity.md` (3) | **UPDATE** |
| **HISTORY** — records what was true then | `docs/reviews/2026-07-14-doc-truth-audit.md` (3), `docs/reviews/2026-07-14-vks-provenance.md` | **DO NOT TOUCH** — rewriting a dated record fabricates history |
| **BACKLOG** | `BACKLOG.md` (17 hits) | mostly historical rows; touch only rows that assert CURRENT state |

⚠️ `docs/scenario-1.md` and `docs/scenario-2.md` are **WALKED**. Their app mentions are 2 inside a
NEUTRALIZED block + 3 in prose (0 of 52 `Expect:` lines name an app), so editing them is cheap — but
they are still the documents the matrix executes, so any edit must be re-read as a walker would.

### 7 of 15 diagrams name an app, and they are BYTE-GATED

`docs/diagrams/container.puml` (12 hits), `pipeline-flow.puml` (12), `vks-topology.puml` (6),
`deployment.puml` (6), `istio-ingress.puml` (2), `airgap.puml` (1), `context.puml` (1).

`make diagrams-check` **re-renders every `.puml` and BYTE-COMPARES against the committed PNG** (8
PNGs in `docs/diagrams/out/`). So a `.puml` edit without `make diagrams` is a RED gate — the drift
is caught, but it means every diagram edit is edit + re-render + commit the PNG, in the same commit.

### The four prose rots to fix while in there (all measured)

- `docs/adding-an-app.md` **and `scripts/lib/apps.sh:6`** both say "only two things differ per
  language". Measured **10**. Fix BOTH or the code comment re-seeds the doc.

- `lib/istio.sh:501` logs "admits all three UI hosts" — checks 4 today, would check 9 at six apps.
- `.env.example:877` names javawebapp restricted-clean and omits gowebapp.
- `docs/sneakernet.md` says "~12 GB" in 3 places; live bundle content measures **8.1 GB** (the
  difference is a stray 5.2 GB pre-plain-tar `.zst` inflating `du`).

- **17 assertions across 12 files say gowebapp is stdlib-only, SIX of them IN CODE** — those invert
  the moment Phase C0 lands, and `main.go`'s header docblock needs rewriting, not patching.

## ══ v3.5 — pythonwebapp, SETTLED BY MEASUREMENT (supersedes every earlier python line) ══

| decision | value | why (all `ran-it`) |
|---|---|---|
| build **and** runtime | **`python:3.14-slim`** (ONE image, both stages) | distroless is refuted on 4 counts, below |
| pole | **vendored in git** — `wheels/`, 636 KB, 7 files | byte-identical across two independent downloads; needs NO builder image, no Harbor push, no bundle tarball (java's builder tarball is 593 MB to carry 636 KB of content) |
| framework | **Flask** | 636 KB vs fastapi's 3.5 MB; Jinja2 ships in those 7 wheels |
| lock | **`uv pip compile --generate-hashes`** on the internet side | `uv pip` has **NO `download` subcommand` — it cannot build a wheelhouse |
| install | **`pip install --no-index --find-links=wheels --require-hashes`** | uv is NOT in the python image (`NO_UV`); pip is. The air-gap box has no mise |
| test framework | **stdlib `unittest`**, not pytest | pytest is not in the flask closure; would need a second dev wheelhouse |

### distroless/python3 is REFUTED — four measured counts

1. **It has NO site-packages on `sys.path` at all**: `['', '/usr/lib/python311.zip', '/usr/lib/python3.11', '.../lib-dynload']`. A perfectly good tree gives `ModuleNotFoundError` unless `PYTHONPATH` is set explicitly.
2. **It forces cp311, and a cp311 wheelhouse CANNOT INSTALL ON THE HOST** (this box is 3.14/glibc → rc=1). `app-test.sh` runs tests on the HOST toolchain, so `make app-test` for python would be **dead on arrival**. Neither my plan nor my brief had this.
3. It needs **2** new mirrored images, and `distroless/python3` is a DIFFERENT image from the already-mirrored `distroless/static` — python does NOT get rust's and go's "0 new bytes".
4. Python 3.11 is two minors stale against this repo's latest-stable discipline.

**slim over alpine** (both are non-root-capable, so PSA does not decide it): slim is **glibc → matches the host**, so the wheelhouse installs on the host and `app-test` stays host-native, symmetric with java/go; and slim **has bash**, so the Tekton task can copy the existing `#!/usr/bin/env bash` shebang — on alpine that exits **127**. Alpine's saving costs an architectural exception for one app.

### SECURITY — the strongest reason to do it this way, all RED-proven

| arm | measured |
|---|---|
| clean + `--require-hashes` | rc=0 |
| **tampered wheel** + `--require-hashes` | **rc=1**, `THESE PACKAGES DO NOT MATCH THE HASHES` |
| **tampered wheel**, flag omitted | **rc=0 — the backdoored wheel installs SILENTLY** |

`--require-hashes` is **MANDATORY, not optional**, because nothing else in this repo can see the problem:

- **gitleaks CANNOT read inside a `.whl`** — a planted high-entropy token is CAUGHT in a plain file inside `wheels/` and **MISSED** inside the zip. There is no `wheels/` path hole (the Go `vendor/` finding does NOT transfer); it is the ZIP container, and it is **not fixable in `.gitleaks.toml`**. Accepted residual — document it.
- **`trivy rootfs wheels/` → 0 packages, exit 0.** The most natural wiring of `trivy-fs`'s python branch is a **silent false green** on the one app whose dependencies are third-party BINARIES.

### THE FILENAME TRAP — verified

`trivy fs` on the identical pinned content: **`requirements.txt` → 7 packages; `requirements.lock` → 0; `requirements-lock.txt` → 0.** The pinned+hashed file MUST literally be named `requirements.txt`. Use the conventional pair: `requirements.in` (human) → `requirements.txt` (uv-compiled, pinned + hashed). That is also what Renovate's `pip-compile` manager expects.

### MY OWN HAZARD WAS REFUTED

I wrote that a wrong-ABI wheelhouse means "a silent fallback to building from source in an image with no compiler". **It fails LOUDLY, rc=1, both ways** — wrong ABI at download time (`no matching distribution`), and an sdist offline (`Could not find ... setuptools` — the PEP 517 build deps are absent too). **Do not design a guard against this.**
The REAL silent mode is different: on a wrong-ABI-but-importable pairing, `markupsafe`'s C `_speedups` fails to import and it silently falls back to pure Python — working but degraded. For `pydantic-core`/`cryptography`/`numpy` the same shape is a hard ImportError. One sentence in the docblock, not a gate.

### PYTHON'S DISTINCTIVE LESSON — corrected

NOT "interpreted, so deps live at runtime" (node is interpreted too — my claim was weak). It is that python's dependency closure contains a **compiled C extension** (`_speedups.cpython-311-x86_64-linux-gnu.so`) that is **ABI- and libc-locked**, and getting it wrong is invisible until runtime. `node_modules` is JavaScript source and has no such property. **No other app in the six teaches this.**

### THINGS THAT MUST BE BUILT / FIXED

- **`.gitignore` drops `*.tar.gz` (`:9`) and `*.pem` (`:16`)** — verified. A committed wheelhouse works ONLY while it is 100% `.whl`; the day a dep ships no wheel, `git add` silently drops it and the failure appears in-cluster naming the PACKAGE, not the gitignore. `--only-binary=:all:` is load-bearing **for git**, not just for the compiler.
- **`python-test.yaml` is a genuinely NEW task shape** — both existing tasks have NO install step (maven relies on a pre-baked `~/.m2`, go on zero deps). Python's deps arrive in the WORKSPACE as committed wheels, so the task must install them first. Also set `PIP_NO_CACHE_DIR=1` + `PYTHONDONTWRITEBYTECODE=1` (go-test redirects `GOCACHE` for the same read-only-HOME reason).
- **A wheelhouse↔lock drift gate** — fully OFFLINE (assert every `--hash` has a matching file and vice versa), never regenerate-and-diff, which would need network in `static-check`. ⚠️ NEW CONTROL → its own idea-round.
- **Renovate**: add `pip_requirements` at minimum; `pip-compile` is better but whether it accepts a **uv**-written header is **UNVERIFIED** — settle with `make renovate-validate` + a dry run.
- **PRE-EXISTING, now forced into the open**: the repo has an undeclared host dependency on **python3 ≥ 3.11 — 70 invocations across 23 scripts**, including `static-check` gates (`check-secrets-untracked.sh` uses `tomllib` and hard-exits) — while `00-install-prereqs.sh` installs python **ZERO** times. Adding a python app improves this by forcing the declaration; budget it as work.
- ⚠️ **MY SIZE TABLE MIXES UNITS.** The MB figures elsewhere in this plan are registry-**COMPRESSED**; `docker images` reports **UNCOMPRESSED** (slim 180 MB vs my 41; alpine 73.6 vs my 17). The bundle is sized off that table — pick ONE unit and label it before quoting a total.
