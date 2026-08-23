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

# app_host <name> — the app's ingress hostname, DERIVED: <name>.${APP_DOMAIN}.
#
# It used to be read through a per-app `<APP>_HOST` variable named in a 5th registry column — which
# made "adding an app is ONE ROW" false (the row died at `app_host` until you ALSO added the var to
# .env.example), and no gate could see that second edit. Deriving it removes the second edit instead
# of policing it: the only tunable left is the DOMAIN, and it is ONE global.
app_host() {
  printf '%s.%s' "$1" "${APP_DOMAIN:?APP_DOMAIN is not set (it is in .env.example; scripts get it via load_env)}"
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
    # maven is DELIBERATELY ABSENT. MEASURED 2026-08-22: the Java app builds with `./mvnw`, which runs
    # apache-maven-3.9.9 from its OWN wrapper dist (.mvn/wrapper/maven-wrapper.properties). mise was
    # supplying 3.9.16, which NOTHING invoked -- a live version inconsistency no gate noticed. The one
    # bare `mvn` in the tree (24-builder-probe.sh:62) runs INSIDE the builder container, not on the
    # host. So requiring a maven pin forced a download onto every walkbox for a binary never executed.
    java) printf 'java' ;;
    go)   printf 'go' ;;
    *)    die "app '$1': add a branch to app_toolchain() — and pin its tools in .mise.toml" ;;
  esac
}

# --- per-LANGUAGE behaviour #6: extra --build-arg flags for the image build ---------------------
# The Kaniko task (k8s/tekton/tasks/kaniko-build.yaml) is SHARED and app-agnostic: it knows about a
# context, a destination, a builder image and a runtime image — and nothing about a language. Any
# build-arg beyond those two images is language knowledge, so it belongs here, not in the task.
#
# Java: the app Dockerfile's `RUN ./mvnw -B ${MVN_OFFLINE} ... package` needs `-o` so the build
#       resolves everything from the pre-baked ~/.m2 in the builder image (Maven Central is
#       unreachable in the air gap). Passing it to a NON-Maven app is meaningless — Kaniko silently
#       drops a --build-arg the Dockerfile never declares, so it "worked", but it is a landmine for
#       the next language.
# Go:   none — the app is stdlib-only, so its Dockerfile declares no offline switch at all.
#
# Prints a SPACE-SEPARATED list of `--build-arg=K=V` flags (empty for a language that needs none).
# It is threaded to the Kaniko task as the `build-args` param (Trigger -> Pipeline -> Task), where
# it is word-split into individual kaniko flags — so no flag may contain whitespace.
app_build_args() {
  case "$(app_lang "$1")" in
    java) printf -- '--build-arg=MVN_OFFLINE=-o' ;;
    go)   printf '' ;;
    *)    die "app '$1': add a branch to app_build_args()" ;;
  esac
}

# app_has_builder <name> — true iff the app ships a Dockerfile.builder, i.e. it needs a pre-baked
# offline dependency cache. Keyed on the FILE, not on the language: that is what actually decides
# whether `make builder-image` has work to do, and a future language that needs one just adds the
# file. (gowebapp has none — stdlib-only.)
app_has_builder() { [ -f "${REPO_ROOT}/$(app_src "$1")/Dockerfile.builder" ]; }

# --- per-LANGUAGE behaviour #7: WHICH base image the app's Dockerfile.builder is built FROM -------
# 14-builder-build.sh enrolls EVERY app that ships a Dockerfile.builder (app_has_builder, above) --
# generic selection -- but until 2026-08-22 its body resolved ONE Maven base ABOVE the loop and
# passed it to every app as `--build-arg MAVEN_IMAGE=...`. So a node builder app would have received
# an ARG its Dockerfile never declares, and MEASURED: podman answers
#   [Warning] one or more build args were not consumed: [MAVEN_IMAGE]
# and EXITS 0. The build then uses the ARG's own default -- an UNPINNED base in an air-gap build,
# announced only by a warning nobody reads. Renaming MAVEN_* would not have helped: the value was
# resolved once, above the loop, so it physically could not vary per app.
#
# app_builder_base <name> -- the images/images.txt KEY of the builder base. Must match a line in
# that file exactly, because 14-builder-build.sh looks its DIGEST up in bundle/images.lock and a
# miss is a hard die.
app_builder_base() {
  case "$(app_lang "$1")" in
    # renovate: datasource=docker depName=maven
    java) printf 'maven:3.9-eclipse-temurin-25' ;;
    # renovate: datasource=docker depName=golang
    go)   printf 'golang:1.27.0-bookworm' ;;
    # renovate: datasource=docker depName=node
    nodejs) printf 'node:24-alpine' ;;
    # renovate: datasource=docker depName=rust
    rust) printf 'rust:1.97-alpine' ;;
    # renovate: datasource=docker depName=python
    python) printf 'python:3.14-alpine' ;;
    # renovate: datasource=docker depName=mcr.microsoft.com/dotnet/sdk
    dotnet) printf 'mcr.microsoft.com/dotnet/sdk:10.0-alpine' ;;
    *)    die "app '$1' ships a Dockerfile.builder but app_builder_base() has no branch for lang '$(app_lang "$1")' — add one, and add the image to images/images.txt so it is mirrored." ;;
  esac
}

# app_builder_arg <name> -- the --build-arg NAME the app's Dockerfile.builder actually declares.
# 14-builder-build.sh VERIFIES the Dockerfile declares it before building, so a mismatch is a loud
# die instead of the silent unpinned base described above.
app_builder_arg() {
  case "$(app_lang "$1")" in
    java) printf 'MAVEN_IMAGE' ;;
    go)   printf 'GO_IMAGE' ;;
    nodejs) printf 'NODE_IMAGE' ;;
    rust) printf 'RUST_IMAGE' ;;
    python) printf 'PYTHON_IMAGE' ;;
    dotnet) printf 'DOTNET_SDK_IMAGE' ;;
    *)    die "app '$1' ships a Dockerfile.builder but app_builder_arg() has no branch for lang '$(app_lang "$1")' — add one naming the ARG its Dockerfile.builder declares." ;;
  esac
}

# app_builder_base_path <name> -- the pullable path for that base, DERIVED, so it is not a third
# per-language site to forget. A key containing '/' is already a full path (mcr.microsoft.com/...);
# a bare name is a Docker Hub official image and lives under docker.io/library/.
app_builder_base_path() {
  local key; key="$(app_builder_base "$1")"
  local repo="${key%%:*}"
  case "$repo" in
    */*) printf '%s' "$repo" ;;
    *)   printf 'docker.io/library/%s' "$repo" ;;
  esac
}

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
  APP_BUILD_ARGS="$(app_build_args "$name")"   # extra kaniko --build-arg flags (may be empty)
  export APP_NAME APP_LANG APP_SRC APP_DEPLOY_DIR APP_HOST APP_TEST_TASK \
         APP_NAMESPACE APP_GIT_REPO APP_DEPLOY_REPO APP_IMAGE \
         APP_BUILDER_IMAGE APP_RUNTIME_IMAGE APP_BUILD_ARGS
}

# for_each_app <fn> — run <fn> <app> for every app, in registry order, with app_export already
# done. Every per-app loop in the repo goes through this, so "adding an app" is one registry row
# and nothing else. NOTE the `while read` (not `for x in $(...)`): the login shell may be zsh,
# which does NOT word-split an unquoted expansion, so a `for` loop would run ONCE on the whole blob.
for_each_app() {
  local fn="$1" app names n=0
  # CAPTURE FIRST, and FLOOR the count. `done <<EOF\n$(app_names)\nEOF` swallows a die: app_names
  # exits inside the command substitution, the heredoc is EMPTY, the loop runs ZERO times, and the
  # caller then prints its success line. All EIGHT callers share that failure -- no ingress routes,
  # no ArgoCD Applications, no Gitea repos, no Tekton pipelines, no Istio routes -- each reported as
  # success. Measured on 99-verify.sh: "End-to-end verified for EVERY app ()" at rc=0.
  #
  # This is the same FILE-vs-ITEM floor that check-app-hardcodes (`pairs`) and check-app-toolchains
  # (`checked`) already carry, and that this function -- the thing they all loop through -- lacked.
  # Zero apps is never legitimate for any caller: the registry ships two.
  names="$(app_names)"
  while read -r app; do
    [ -n "$app" ] || continue
    app_export "$app"
    "$fn" "$app"
    n=$((n + 1))
  done <<EOF
$names
EOF
  [ "$n" -gt 0 ] || die "for_each_app: iterated 0 app(s) running '$fn' — apps/registry.tsv is empty or app_names is broken. The caller's success message would be VACUOUS."
}
