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

# apps.sh CALLS mirror_target_ref (app_runtime_image, nodejs/python arms), which lib/mirror.sh
# defines -- so apps.sh must source it, per the rule check-lib-sourcing.sh states: a script that
# CALLS a lib function must SOURCE the lib that defines it.
#
# It did not, and the failure was real: `make e2e-kind` died at seed-gitea with
#   app 'nodejswebapp': app_runtime_image needs mirror_target_ref — source scripts/lib/mirror.sh
# AFTER seeding javawebapp and gowebapp, because only the nodejs/python arms need it. Every
# consumer of for_each_app inherits the dependency (app_export calls app_runtime_image), so fixing
# it in each caller would be the enumerated-list rot; the library declares its own dependency.
# mirror.sh carries a __VKS_MIRROR_SH_LOADED guard, so re-sourcing is a no-op.
_APPS_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/mirror.sh
. "${_APPS_SH_DIR}/mirror.sh"

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
    # Named for the LANGUAGE, matching go-test. NOT derived as "<lang>-test": `maven-test` names
    # the TOOL, and a Java app could legitimately use Gradle, which would make a derived
    # 'java-test' actively wrong. scripts/validate.sh:243 greps these names against
    # k8s/tekton/tasks/*.yaml on every PR, so a task that does not exist REDs offline.
    nodejs) printf 'nodejs-test' ;;
    python) printf 'python-test' ;;
    rust)   printf 'rust-test' ;;
    dotnet) printf 'dotnet-test' ;;
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
  # ⚠️ ESCAPE `&` BEFORE IT REACHES A sed REPLACEMENT. In `sed s#a#b#`, a bare `&` in the
  # replacement expands to THE ENTIRE MATCHED TEXT -- so a marker containing one (a timestamp, a
  # branch name, "A&B") silently produces a garbled hybrid, and sed exits 0. The `grep -q` below
  # would then also pass, because the escaped form still contains the literal message. Escape
  # `\` first or you double-escape what you just inserted.
  local esc="$msg"; esc="${esc//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//#/\\#}"
  case "$lang" in
    java)
      # application.yml:  message: ${APP_MESSAGE:Hello from vks-airgap-cicd}
      local f="${dir}/src/main/resources/application.yml"
      [ -f "$f" ] || die "app '$name': expected $f (java marker file)"
      sed -i "s#\${APP_MESSAGE:[^}]*}#\${APP_MESSAGE:${esc}}#" "$f"
      grep -qF "$msg" "$f" || die "app '$name': marker did not land in $f"
      ;;
    go)
      # main.go:  const defaultMessage = "Hello from vks-airgap-cicd"
      local f="${dir}/main.go"
      [ -f "$f" ] || die "app '$name': expected $f (go marker file)"
      sed -i "s#^const defaultMessage = \".*\"#const defaultMessage = \"${esc}\"#" "$f"
      grep -qF "const defaultMessage = \"${msg}\"" "$f" || die "app '$name': marker did not land in $f"
      ;;
    nodejs)
      # server.js:  const defaultMessage = 'Hello from vks-airgap-cicd';   (SINGLE quotes, trailing ;)
      local f="${dir}/server.js"
      [ -f "$f" ] || die "app '$name': expected $f (nodejs marker file)"
      sed -i "s#^const defaultMessage = '.*';#const defaultMessage = '${esc}';#" "$f"
      grep -qF "const defaultMessage = '${msg}';" "$f" || die "app '$name': marker did not land in $f"
        ;;
      python)
        # app.py:  DEFAULT_MESSAGE = "Hello from vks-airgap-cicd"
        local f="${dir}/app.py"
        [ -f "$f" ] || die "app '$name': expected $f (python marker file)"
        sed -i "s#^DEFAULT_MESSAGE = \".*\"#DEFAULT_MESSAGE = \"${esc}\"#" "$f"
        grep -qF "DEFAULT_MESSAGE = \"${msg}\"" "$f" || die "app '$name': marker did not land in $f"
        ;;
      rust)
        # src/main.rs:  const DEFAULT_MESSAGE: &str = "Hello from vks-airgap-cicd";
        local f="${dir}/src/main.rs"
        [ -f "$f" ] || die "app '$name': expected $f (rust marker file)"
        sed -i "s#^const DEFAULT_MESSAGE: &str = \".*\";#const DEFAULT_MESSAGE: \&str = \"${esc}\";#" "$f"
        grep -qF "const DEFAULT_MESSAGE: &str = \"${msg}\";" "$f" || die "app '$name': marker did not land in $f"
      ;;
    dotnet)
      # Program.cs:  public const string DefaultMessage = "Hello from vks-airgap-cicd";
      local f="${dir}/Program.cs"
      [ -f "$f" ] || die "app '$name': expected $f (dotnet marker file)"
      sed -i "s#DefaultMessage = \".*\";#DefaultMessage = \"${esc}\";#" "$f"
      grep -qF "DefaultMessage = \"${msg}\";" "$f" || die "app '$name': marker did not land in $f"
      ;;
    *) die "app '$name': unknown lang '$lang' — add a branch to app_set_message()" ;;
  esac
}

# --- per-LANGUAGE behaviour #3: the base images the app's Dockerfile is built FROM -------------
# Both are refs INTO HARBOR (the air gap has nothing else). The tags come from .env.example and are
# kept aligned with images/images.txt by `make check-image-alignment`, which reads each app's
# Dockerfile ARGs straight out of the registry — so this stays honest without a per-app gate.
# ⚠️ DERIVED FROM app_has_builder, NOT FROM A PER-LANGUAGE LITERAL. This was a `case` on the
# language, and its `go)` arm returned the MIRRORED UPSTREAM path
# (the Harbor path of the MIRRORED golang image, tag from its .env.example var) because Go had no
# builder. The moment gowebapp gained a Dockerfile.builder (2026-08-22) that arm became a
# MIRROR-CORRUPTING BUG, MEASURED:
#
#     java push-ref: harbor/cicd/javawebapp-builder:0.3.0     (a builder)
#     go   push-ref: harbor/cicd/golang:1.27.0-bookworm       (the MIRRORED UPSTREAM IMAGE)
#
# app_has_builder() is a file test, so gowebapp enrolled itself in 22-builder-push.sh, which
# computes its destination from THIS function -- and `make builder-push` would have REPLACED the
# mirrored public golang in Harbor with a locally-built derivative. Nothing would have failed:
# 23-mirror-verify.sh treats a digest mismatch as a WARN whose text blames "likely OCI-layout
# rewrap", and install-all verifies BEFORE the push (Makefile: mirror -> mirror-verify ->
# builder-image), so the clobber lands after the only check that could see it.
#
# The invariant the `case` could not express: an app that SHIPS a builder pushes to its OWN
# <app>-builder ref; an app that does not never had anything to push. Deriving from the same
# predicate that enrols the app makes those two facts one fact, so they cannot disagree again.
app_builder_image() {
  local name="$1"
  if app_has_builder "$name"; then
    # Its own ref, namespaced by app. Never collides with a mirrored upstream repo.
    printf '%s/%s/%s-builder:%s' "${HARBOR_URL:?}" "${HARBOR_INFRA_PROJECT:?}" "$name" "${BUILDER_IMAGE_TAG:?}"
  else
    # No builder: the app builds FROM the mirrored upstream base directly. mirror_target_ref is the
    # ONE mapping the mirror itself uses (lib/mirror.sh), so this cannot drift from where the image
    # actually landed -- reimplementing the <host>/<path>:<tag> rewrite here is how they diverge.
    # GUARD, not an assumption: lib/apps.sh does NOT source lib/mirror.sh (it would be circular --
    # mirror.sh sources apps.sh), so mirror_target_ref is the CALLER's to provide. Without this a
    # caller that sourced apps.sh alone gets `mirror_target_ref: command not found` on this branch
    # ONLY -- the trap lib/os.sh:1699 records for harbor_scheme. MEASURED: 24-builder-probe.sh
    # sources apps.sh and NOT mirror.sh today. The branch is currently unreachable (every app ships
    # a builder), which is exactly why it needs to fail loudly rather than rot.
    command -v mirror_target_ref >/dev/null 2>&1 \
      || die "app '$name' has no Dockerfile.builder, so its image ref comes from mirror_target_ref — but lib/mirror.sh is not sourced. Source it alongside lib/apps.sh in the calling script."
    mirror_target_ref "$(app_builder_base "$name")"
  fi
}

app_runtime_image() {
  local name="$1"
  case "$(app_lang "$name")" in
    java) printf '%s/%s/eclipse-temurin:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${TEMURIN_JRE_TAG:?}" ;;
    go)   printf '%s/%s/distroless/static-debian12:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${DISTROLESS_STATIC_TAG:?}" ;;
    # DERIVED from app_builder_base, not a second pin. For Node the builder base IS the runtime
    # base (images/images.txt:63 says so in as many words), so a NODE_RUNTIME_TAG var would be a
    # SECOND source of truth for one image and a fresh drift surface -- and it would sit outside
    # the `# renovate:` annotation that tracks the literal, so only one of the two would ever bump.
    # Safe here specifically because that literal carries NO digest: mirror_target_ref prefers the
    # TAG and would silently drop a digest if one were added (measured on the Go/Rust bases). If a
    # digest is ever pinned for node, this arm must stop deriving and pin explicitly.
    nodejs)
      command -v mirror_target_ref >/dev/null 2>&1 \
        || die "app '$name': app_runtime_image needs mirror_target_ref — source scripts/lib/mirror.sh"
      mirror_target_ref "$(app_builder_base "$name")" ;;
      # python: builder base IS the runtime base (both python:3.14-alpine) -- same reasoning as nodejs
      # above, and safe for the same reason: that literal carries no digest for mirror_target_ref to drop.
      python)
        command -v mirror_target_ref >/dev/null 2>&1 \
          || die "app '$name': app_runtime_image needs mirror_target_ref — source scripts/lib/mirror.sh"
        mirror_target_ref "$(app_builder_base "$name")" ;;
      # rust builds a CGO-free static binary, so it ships on the SAME distroless base as Go and reuses
      # the same pin -- one mirrored image, one tag, no second source of truth.
      rust) printf '%s/%s/distroless/static-debian12:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${DISTROLESS_STATIC_TAG:?}" ;;
      # dotnet ships on the CHISELLED aspnet base, which images/images.txt:83 already mirrors under its
      # own # renovate: annotation -- a separate image from the SDK builder base, unlike python/nodejs.
      dotnet) printf '%s/%s/dotnet/aspnet:%s' "$HARBOR_URL" "$HARBOR_INFRA_PROJECT" "${DOTNET_ASPNET_TAG:?}" ;;
    *)    die "app '$name': add a branch to app_runtime_image()" ;;
  esac
}

# --- per-LANGUAGE behaviour #4: the app's health endpoint ---------------------------------------
# `make verify` waits for the app to serve HTTP before asserting the marker. Spring Boot exposes
# actuator; the Go app exposes a plain /healthz (no actuator exists outside Spring).
app_health_path() {
  # ZERO branches, permanently. Every app serves /healthz -- 5 of 6 already did; the Java app
  # reaches it through actuator path-mapping (see its application.yml), so it is a REAL health
  # check, not a hardcoded 200. The `$1` is accepted and ignored so every caller stays unchanged.
  #
  # This was a `case` that died for any unknown language. MEASURED 2026-08-22: enrolling a third
  # app made `make creds` print FATAL, render the row anyway with a BLANK health field, and exit 0
  # -- because a `die` inside `$( )` in ARGUMENT position does not trip the caller's `set -e`.
  #
  # ⚠️ NOT a claim that the per-language rot is closed. FIVE sibling `case` lists still die for an
  # unknown language (app_test_task, app_set_message, app_runtime_image, app_toolchain,
  # app_build_args) and most are irreducibly per-language: Go and Java cannot share a runtime
  # image or a toolchain. The health path was the one branch that was a CONVENTION we own.
  : "${1:?app_health_path: an app name is required}"
  printf '/healthz'
}

# --- per-LANGUAGE behaviour #5: the toolchain the app needs to BE TESTED ------------------------
# `make app-test` / `make trivy-fs` run each app's tests and scan its built artifact. CI gets its
# toolchain from .mise.toml (mise-action) — so a language whose tools are NOT pinned there simply
# cannot be tested or scanned on a clean runner, while passing on any dev box that happens to have
# them. That is how the Go app shipped with an unpinned toolchain AND a CVE'd stdlib.
# `make check-app-toolchains` gates it.
app_toolchain() {
  # EMPTY BY DESIGN as of 2026-08-23. Every consumer of a host app-toolchain is now containerised —
  # app-test, check-ui-contract, trivy-fs and app-run all run inside the app's own builder image.
  # MEASURED: all four exit 0 with java/go/cargo/dotnet/node stripped from PATH entirely.
  #
  # The invariant this used to protect ("CI can actually build and test this app") did not vanish;
  # it MOVED, and is now asserted by a stronger mechanism. check-image-alignment.sh:239-244 executes
  # app_builder_base() PER APP and asserts its tag against images/images.txt. Since the tests now run
  # INSIDE that image, "the toolchain that tests == the toolchain that builds" is an IDENTITY rather
  # than an assertion.
  #
  # Two of the pins this removes never worked anyway. MEASURED on a cold MISE_DATA_DIR:
  #   rust 1.98.0 -> "(symlink)", 8.0K, 1 file, no binary
  #   dotnet 10   -> "(symlink)", 8.0K, 1 file, no binary
  # i.e. mise did not install them; it symlinked this box's rustup and system dotnet. They resolved
  # only because the dev box already had them — the hidden-dev-box-state class. On a walkbox, which
  # has neither, that path had never been exercised, and every one of the six matrix rows runs
  # `make deps` (scenario-1 Step 1) which would have been the first place to try it.
  #
  # node is NOT here and is still pinned: it is INFRA (npx markdownlint, npx renovate), not an app
  # toolchain.
  :
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
# Go:   none — `go build` takes its offline behaviour from GOFLAGS/GOPROXY in the Dockerfile, not
#       from a --build-arg. (It is no longer stdlib-only: it depends on chi and ships a builder.)
#
# Prints a SPACE-SEPARATED list of `--build-arg=K=V` flags (empty for a language that needs none).
# It is threaded to the Kaniko task as the `build-args` param (Trigger -> Pipeline -> Task), where
# it is word-split into individual kaniko flags — so no flag may contain whitespace.
app_build_args() {
  case "$(app_lang "$1")" in
    java) printf -- '--build-arg=MVN_OFFLINE=-o' ;;
    go)   printf '' ;;
    # Empty, like Go: the Node Dockerfile hardcodes `npm ci --offline`, so the air gap needs no
    # build arg to switch it on. (Java is the exception -- its offline flag is a VALUE, `-o`, that
    # exists nowhere in its Dockerfile except a comment, so it must be passed.)
    nodejs) printf '' ;;
    # Empty for the same reason as Go and Node: the Dockerfile hardcodes the offline switch
    # (pip's PIP_NO_INDEX / cargo's --offline --locked), so the air gap needs no build arg.
    python) printf '' ;;
    rust)   printf '' ;;
    # Empty: the Dockerfile hardcodes --no-restore, so the air gap needs no build arg.
    dotnet) printf '' ;;
    *)    die "app '$1': add a branch to app_build_args()" ;;
  esac
}

# app_has_builder <name> — true iff the app ships a Dockerfile.builder, i.e. it needs a pre-baked
# offline dependency cache. Keyed on the FILE, not on the language: that is what actually decides
# whether `make builder-image` has work to do, and a future language that needs one just adds the
# file. As of 2026-08-22 all six apps ship one, so this predicate is true for every app -- but it
# stays a FILE TEST, because that is what makes adding a language a file rather than a branch.
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
    rust) printf 'rust:1.98-alpine' ;;
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
