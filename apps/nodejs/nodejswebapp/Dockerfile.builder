# syntax=docker/dockerfile:1.26
# Builder image for AIR-GAPPED CI: bakes this app's full npm dependency tree so the in-cluster
# build (kaniko) and the Tekton test task need NO registry.npmjs.org. Build on the INTERNET-connected
# jump box, push to Harbor, then reference it as BUILDER_IMAGE in the app Dockerfile.
#
# Rebuild whenever package.json / package-lock.json change. scripts/14-builder-build.sh resolves the
# base image and the ARG NAME below PER APP via lib/apps.sh (app_builder_base / app_builder_arg).
ARG NODE_IMAGE=node:24-alpine
# NODE_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${NODE_IMAGE}

WORKDIR /build
# Manifests FIRST so the dependency layer caches independently of the source.
COPY package.json package-lock.json ./
# `npm ci` (not `install`): it installs EXACTLY the lockfile, which is the only thing that makes an
# offline rebuild reproducible. The air-gapped build then runs `npm ci --offline` against this cache.
RUN npm ci --no-audit --no-fund

COPY . .
# The image's value is its warm /build/node_modules + npm cache, inherited by the app Dockerfile.
