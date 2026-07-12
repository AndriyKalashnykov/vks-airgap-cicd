#!/usr/bin/env bash
# scripts/lib/apps.sh — the app registry (apps/registry.tsv) and the few per-LANGUAGE behaviours.
#
# The demo runs N apps through the SAME walk: push to <app>-app (Gitea) -> Tekton (test -> Kaniko
# build -> push to Harbor -> write the new tag back to <app>-deploy) -> ArgoCD syncs -> the live
# page shows it. Only two things actually differ per language:
#
#   1. the Tekton TEST task           (maven-test vs go-test)
#   2. how `make verify` injects its marker into the source
#
# Everything else is structure, and structure lives in apps/registry.tsv. So: adding an app is one
# ROW; adding a LANGUAGE is one row plus one `case` branch in each function below. No new script.
#
# shellcheck shell=bash

[ -n "${__VKS_APPS_SH_LOADED:-}" ] && return 0
__VKS_APPS_SH_LOADED=1

APPS_REGISTRY="${APPS_REGISTRY:-${REPO_ROOT}/apps/registry.tsv}"

# app_rows — print the registry's data rows (comments/blank lines stripped), tab-separated.
app_rows() {
  [ -f "$APPS_REGISTRY" ] || die "app registry not found: $APPS_REGISTRY"
  grep -vE '^\s*(#|$)' "$APPS_REGISTRY"
}

# app_names — just the names, in registry order.
app_names() {
  app_rows | awk -F'\t' '{print $1}'
}

# app_field <name> <column-number> — read one field of one app's row.
app_field() {
  local name="$1" col="$2" v
  v="$(app_rows | awk -F'\t' -v n="$name" -v c="$col" '$1==n {print $c; found=1} END{exit !found}')" \
    || die "unknown app '$name' (not in $APPS_REGISTRY)"
  printf '%s' "$v"
}

app_lang()   { app_field "$1" 2; }
app_src()    { app_field "$1" 3; }
app_deploy() { app_field "$1" 4; }

# app_host <name> — resolve the app's ingress hostname through the .env variable named in the
# registry (indirect expansion), so hostnames stay operator-tunable in .env.example.
app_host() {
  local var; var="$(app_field "$1" 5)"
  local val="${!var:-}"
  [ -n "$val" ] || die "app '$1': ${var} is not set (add it to .env.example / .env)"
  printf '%s' "$val"
}

# --- per-LANGUAGE behaviour #1: which Tekton task runs the tests -----------------------------
# The Pipeline is rendered per app (envsubst), so the test task is just a token.
app_test_task() {
  case "$(app_lang "$1")" in
    java) printf 'maven-test' ;;
    go)   printf 'go-test' ;;
    *)    die "app '$1': unknown lang '$(app_lang "$1")' — add a branch to app_test_task()" ;;
  esac
}

# --- per-LANGUAGE behaviour #2: inject the verify marker into the source ----------------------
# `make verify` proves the WHOLE GitOps loop by rewriting the app's greeting with a unique marker,
# pushing it, and asserting the marker appears on the deployed page. Where that greeting lives is
# the only language-specific thing about it.
#
# app_set_message <name> <checkout-dir> <message>
app_set_message() {
  local name="$1" dir="$2" msg="$3" lang; lang="$(app_lang "$name")"
  case "$lang" in
    java)
      # application.yml:  message: ${APP_MESSAGE:Hello from vks-airgap-cicd}
      local f="${dir}/src/main/resources/application.yml"
      [ -f "$f" ] || die "app '$name': expected $f (java marker file)"
      sed -i "s#\${APP_MESSAGE:[^}]*}#\${APP_MESSAGE:${msg}}#" "$f"
      grep -q "$msg" "$f" || die "app '$name': marker did not land in $f"
      ;;
    go)
      # main.go:  const defaultMessage = "Hello from vks-airgap-cicd"
      local f="${dir}/main.go"
      [ -f "$f" ] || die "app '$name': expected $f (go marker file)"
      sed -i "s#^const defaultMessage = \".*\"#const defaultMessage = \"${msg}\"#" "$f"
      grep -q "const defaultMessage = \"${msg}\"" "$f" || die "app '$name': marker did not land in $f"
      ;;
    *) die "app '$name': unknown lang '$lang' — add a branch to app_set_message()" ;;
  esac
}

# --- per-LANGUAGE behaviour #3: the base images the app's Dockerfile is built FROM -------------
# Both are refs INTO HARBOR (the air gap has nothing else). The tags come from .env.example and are
# kept aligned with images/images.txt by `make check-image-alignment`, which reads each app's
# Dockerfile ARGs straight out of the registry — so this stays honest without a per-app gate.
app_builder_image() {
  local name="$1"
  case "$(app_lang "$name")" in
    # Java needs a PRE-BAKED builder image (its ~/.m2 holds every dependency) because an in-cluster
    # `mvn` cannot reach Maven Central. That image is built + pushed by 15-build-push-builder.sh.
    java) printf '%s/%s/%s-builder:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "$name" "${BUILDER_IMAGE_TAG:?}" ;;
    # Go needs NO builder image: the app is stdlib-only, so the offline build fetches nothing and
    # the mirrored upstream golang image is enough.
    go)   printf '%s/%s/golang:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${GOLANG_BUILD_TAG:?}" ;;
    *)    die "app '$name': add a branch to app_builder_image()" ;;
  esac
}

app_runtime_image() {
  local name="$1"
  case "$(app_lang "$name")" in
    java) printf '%s/%s/eclipse-temurin:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${TEMURIN_JRE_TAG:?}" ;;
    go)   printf '%s/%s/distroless/static-debian12:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${DISTROLESS_STATIC_TAG:?}" ;;
    *)    die "app '$name': add a branch to app_runtime_image()" ;;
  esac
}

# --- per-LANGUAGE behaviour #4: the app's health endpoint ---------------------------------------
# `make verify` waits for the app to serve HTTP before asserting the marker. Spring Boot exposes
# actuator; the Go app exposes a plain /healthz (no actuator exists outside Spring).
app_health_path() {
  case "$(app_lang "$1")" in
    java) printf '/actuator/health' ;;
    go)   printf '/healthz' ;;
    *)    die "app '$1': add a branch to app_health_path()" ;;
  esac
}

# --- per-LANGUAGE behaviour #5: the toolchain the app needs to BE TESTED ------------------------
# `make app-test` / `make trivy-fs` run each app's tests and scan its built artifact. CI gets its
# toolchain from .mise.toml (mise-action) — so a language whose tools are NOT pinned there simply
# cannot be tested or scanned on a clean runner, while passing on any dev box that happens to have
# them. That is how the Go app shipped with an unpinned toolchain AND a CVE'd stdlib.
# `make check-app-toolchains` gates it.
app_toolchain() {
  case "$(app_lang "$1")" in
    java) printf 'java maven' ;;
    go)   printf 'go' ;;
    *)    die "app '$1': add a branch to app_toolchain() — and pin its tools in .mise.toml" ;;
  esac
}

# app_has_builder <name> — true iff the app ships a Dockerfile.builder, i.e. it needs a pre-baked
# offline dependency cache. Keyed on the FILE, not on the language: that is what actually decides
# whether `make builder-image` has work to do, and a future language that needs one just adds the
# file. (gowebapp has none — stdlib-only.)
app_has_builder() { [ -f "${REPO_ROOT}/$(app_src "$1")/Dockerfile.builder" ]; }

# app_image <name> — the app's image repo in Harbor (no tag; the pipeline tags it with the commit).
app_image() { printf '%s/%s/%s' "$HARBOR_URL" "$HARBOR_APP_PROJECT" "$1"; }

# app_export <name> — export the APP_* tokens the manifests are rendered with (envsubst), so a
# single set of templates (k8s/tekton/*, k8s/argocd/*, the ingress route) serves every app.
app_export() {
  local name="$1"
  APP_NAME="$name"
  APP_LANG="$(app_lang "$name")"
  APP_SRC="$(app_src "$name")"
  APP_DEPLOY_DIR="$(app_deploy "$name")"
  APP_HOST="$(app_host "$name")"
  APP_TEST_TASK="$(app_test_task "$name")"
  APP_NAMESPACE="$name"                    # one namespace per app, named after it
  APP_GIT_REPO="${name}-app"               # Gitea source repo
  APP_DEPLOY_REPO="${name}-deploy"         # Gitea deploy repo (ArgoCD's source)
  APP_IMAGE="$(app_image "$name")"         # Harbor repo for the built image (tagged with the commit)
  APP_BUILDER_IMAGE="$(app_builder_image "$name")"
  APP_RUNTIME_IMAGE="$(app_runtime_image "$name")"
  export APP_NAME APP_LANG APP_SRC APP_DEPLOY_DIR APP_HOST APP_TEST_TASK \
         APP_NAMESPACE APP_GIT_REPO APP_DEPLOY_REPO APP_IMAGE \
         APP_BUILDER_IMAGE APP_RUNTIME_IMAGE
}

# for_each_app <fn> — run <fn> <app> for every app, in registry order, with app_export already
# done. Every per-app loop in the repo goes through this, so "adding an app" is one registry row
# and nothing else. NOTE the `while read` (not `for x in $(...)`): the login shell may be zsh,
# which does NOT word-split an unquoted expansion, so a `for` loop would run ONCE on the whole blob.
for_each_app() {
  local fn="$1" app
  while read -r app; do
    [ -n "$app" ] || continue
    app_export "$app"
    "$fn" "$app"
  done <<EOF
$(app_names)
EOF
}
