# Adding an app

The demo is driven by `apps/registry.tsv` — seeding, Tekton, ArgoCD, the ingress, PSA and the gates
all loop over it. Adding an app is **one row**; adding a *language* is that row plus one `case`
branch in `scripts/lib/apps.sh`.

The row:

```tsv
# name        lang  src                   deploy
javawebapp    java  apps/java/javawebapp  deploy/javawebapp
gowebapp      go    apps/go/gowebapp      deploy/gowebapp
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

## What differs per LANGUAGE (measured — it is not two things)

This document used to say *"only two things differ per language"*. Measured 2026-08-22, that is
false: `scripts/lib/apps.sh` carries **ten** per-language `case` branches — `app_test_task`,
`app_set_message`, `app_builder_image`, `app_runtime_image`, `app_health_path`, `app_toolchain`,
`app_build_args`, `app_builder_base`, `app_builder_arg` — plus three more outside it
(`app-run.sh`, `app-test.sh`, `trivy-fs.sh`). And a further set is not a `case` at all but a **file
or a config key**: the Tekton task manifest (`k8s/tekton/tasks/<lang>-test.yaml`), the toolchain pin
in `.mise.toml`, two lines in `images/images.txt` (builder base + runtime base), and two tag vars in
`.env.example`.

So a **new language** is a row plus roughly a dozen edits. A new app in an **existing** language is
genuinely one row. The gates name the missing pieces rather than letting them surface at runtime:
`make check-app-toolchains` catches an unpinned toolchain, `make validate` catches a missing Tekton
task, and `make check-image-alignment` executes `app_builder_base` for every app that ships a
`Dockerfile.builder` and compares it to `images/images.txt`.

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
