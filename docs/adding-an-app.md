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

Only two things differ per language: which Tekton task runs the tests (`maven-test` / `go-test`),
and where `verify` injects its marker. Both live in `scripts/lib/apps.sh`.

## On VKS, a new app may need grants you must request

Locally, and in [Scenario 1](scenario-1.md) where you are the admin, nothing else is needed. As a
**tenant** ([Scenario 2](scenario-2.md)), a new app's namespace and hostname may fall outside what
you were granted — see [Scenario 2 → adding an app as a tenant](scenario-2.md#adding-an-app-as-a-tenant).
