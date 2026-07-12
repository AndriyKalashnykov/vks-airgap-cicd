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
  export APP_NAME APP_LANG APP_SRC APP_DEPLOY_DIR APP_HOST APP_TEST_TASK \
         APP_NAMESPACE APP_GIT_REPO APP_DEPLOY_REPO
}
