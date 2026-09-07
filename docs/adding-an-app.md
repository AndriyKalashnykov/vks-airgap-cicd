# Adding an app

The demo is driven by `apps/registry.tsv` — seeding, Tekton, ArgoCD, the ingress, PSA and the gates
all loop over it. Adding an app is **one row**; adding a *language* is that row plus one `case`
branch in `scripts/lib/apps.sh`.

The row:

```tsv
# name        lang    src                       deploy
javawebapp    java    apps/java/javawebapp      deploy/javawebapp
gowebapp      go      apps/go/gowebapp          deploy/gowebapp
nodejswebapp  nodejs  apps/nodejs/nodejswebapp  deploy/nodejswebapp
pythonwebapp  python  apps/python/pythonwebapp  deploy/pythonwebapp
rustwebapp    rust    apps/rust/rustwebapp      deploy/rustwebapp
dotnetwebapp  dotnet  apps/dotnet/dotnetwebapp  deploy/dotnetwebapp
```

Each app gets: its own Gitea repos (`<app>-app` + `<app>-deploy`), its own Tekton `Pipeline`
(`<app>-ci`) and `Trigger`, its own Harbor repo, its own namespace, its own ArgoCD `Application`,
its own ingress host — and `make verify` proves **each app independently** (its own marker on its
own page). `make check-app-hardcodes` fails the build if any shared file (**including
`.env.example`**) names an app — that is the gate that keeps "one row" true.

The **ingress hostname is derived, not configured**: an app is reachable at
**`<app>.${APP_DOMAIN}`** (`APP_DOMAIN=vks.local`, one global in `.env.example`). There is no
per-app `<APP>_HOST` variable — there used to be, and it meant a new row silently died until you
*also* edited `.env.example`, so "one row" was a lie the gates could not see.

## What differs per LANGUAGE

More than you would guess, and the exact set moves — so **derive it, do not trust a list**:

```sh
awk '/^[a-z_][a-z0-9_]*\(\)/{fn=$1; sub(/\(\).*/,"",fn)}
     /case[[:space:]]+"\$\(app_lang/ || /case[[:space:]]+"\$\{?_?lang\}?"/ {if(fn)print fn}' \
  scripts/lib/apps.sh | sort -u
```

Each function it prints has one branch per language, plus three more outside `apps.sh`
(`app-run.sh`, `app-test.sh`, `trivy-fs.sh`). And a further set is not a `case` at all but a **file
or a config key**: the Tekton task manifest (`k8s/tekton/tasks/<lang>-test.yaml`), the toolchain pin
in `.mise.toml`, two lines in `images/images.txt` (builder base + runtime base), and two tag vars in
`.env.example`.

So a **new language** is a row plus roughly a dozen edits. A new app in an **existing** language is
genuinely one row **plus one file** — see below. The gates name the missing pieces rather than
letting them surface at runtime: `make check-app-toolchains` catches an unpinned toolchain,
`make validate` catches a missing Tekton task, `make check-image-alignment` executes
`app_builder_base` for every app that ships a `Dockerfile.builder` and compares it to
`images/images.txt`, and `make check-app-gitignore` catches the one file below.

## The one file every new app needs: its own `.gitignore`

`make seed-gitea` force-pushes each app directory **verbatim** into a fresh Gitea repo, and the root
`.gitignore` cannot protect that repo — its build-output rules are `apps/**/`-anchored, and at the
fresh repo's root there is no `apps/` prefix left to match. Measured 2026-09-07 on a built box: of
911 staged files the outer repo ignores **845**, and the fresh-repo anchoring ignores **3**.

⚠️ **And it is not only build output.** The seeded repo is created **`"private":false`** and
force-pushed, and the root `.gitignore`'s *secret* patterns (`.env`, `*.key`, `*.pem`,
`*.kubeconfig`) are **unanchored** — so they protect the outer repo at any depth and are **absent**
from the seeded one. Every per-app file therefore mirrors those lines too, negation included. Keep
them when you write a new one; nothing in the tree matches them today, so they cost nothing and they
are what stops a stray kubeconfig becoming public.

So write `apps/<lang>/<app>/.gitignore` for whatever your app builds locally. `gitignore(5)` says
those patterns match *relative to the file's own location*, which is exactly why this works in both
repos at once. `make check-app-gitignore` fails until it is **tracked** — present-but-untracked does
not count, because `cp -a` copies it while nobody else ever receives it.

⚠️ **Do not copy your `.dockerignore` into it.** The grammars differ on anchoring:
`apps/go/gowebapp/.dockerignore` carries a bare `gowebapp` token, which as a gitignore line would
also exclude `cmd/gowebapp/` and `internal/gowebapp/`. The go file uses an anchored `/gowebapp`
instead. Run **`make app-gitignore-show`** to see every app's rules beside the root's `apps/**` rules
before you write yours — it prints and never gates, because which patterns an app needs is a
judgement call.

## Every app must render the SAME page

`make check-ui-contract` renders every app with fixed inputs and requires the results to be
**identical** once whitespace is normalised — the owner requirement is that the look and feel is the
same and only app-specific data differs. Each app supplies an executable
`apps/<lang>/<app>/ui-contract.sh` that writes its rendered page to `$1`; the gate finds them by
convention, so a new language adds a **file** rather than another `case`.

It is wired into `make static-check` (not the per-PR half — it runs each app's real test pipeline
and costs ~2 min). A one-app run is refused: comparing a single page proves nothing.

## On VKS, a new app may need grants you must request

Locally, and in [Scenario 1](scenario-1.md) where you are the admin, nothing else is needed. As a
**tenant** ([Scenario 2](scenario-2.md)), a new app's namespace and hostname may fall outside what
you were granted — see [Scenario 2 → adding an app as a tenant](scenario-2.md#adding-an-app-as-a-tenant).

---

[← back to the README](../README.md)
