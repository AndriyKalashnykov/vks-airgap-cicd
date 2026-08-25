# syntax=docker/dockerfile:1.26
# dotnetwebapp — the CHISELLED case: an ASP.NET Core app on a base with no shell and no package
# manager, which is what makes the runtime-stage air-gap invariant free rather than enforced.
#
# AIR-GAP: BUILDER_IMAGE is the pre-baked image from Dockerfile.builder (built on the internet-side
# jump box, pushed to Harbor) and carries a warm ~/.nuget/packages. `--no-restore` below is the
# offline switch: it forbids resolving packages, so if that cache is incomplete this FAILS here
# rather than dialling nuget.org from a kaniko pod that has no egress.
ARG BUILDER_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0-alpine
ARG RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled

# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build
WORKDIR /src
# The SDK phones home on first run and emits a first-use banner; both are noise in a build log and
# the telemetry is a network call we do not want in an air-gapped stage even when it is harmless.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
COPY . .
# `dotnet restore --source` FIRST, then --no-restore on the rest.
#
# ⚠️ THIS USED TO BE `--no-restore` ALONE, and it only ever worked by accident. The comment claimed
# "the builder already restored, and this is the flag that proves it" -- but the builder restores at
# WORKDIR /build while this stage builds at /src, so `/src/obj/project.assets.json` was never
# produced by it. What supplied that file was `COPY . .` picking up the DEVELOPER'S LOCAL `obj/`
# from the build context. MEASURED 2026-08-25: the instant a .dockerignore excluded `obj/`, the
# in-cluster build failed in ten seconds with
#     error NETSDK1004: Assets file '/src/obj/project.assets.json' not found
# i.e. the air-gapped build depended on an untracked artifact from someone's working tree, and a
# clean CI checkout would have failed the same way.
#
# The restore is OFFLINE and stays offline: --source points at the builder's warm
# ~/.nuget/packages (see Dockerfile.builder, whose stated value is exactly that cache), and
# --no-cache stops NuGet consulting any configured remote feed. If this ever needs the network it
# will FAIL rather than silently reach out, which is the property an air-gap build needs.
RUN dotnet restore --no-cache --source /root/.nuget/packages \
    && dotnet build --no-restore -c Release \
    && dotnet publish --no-restore -c Release -o /app

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT} \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    # Kestrel binds from Program.cs (UseUrls) using APP_INTERNAL_PORT, so ASPNETCORE_URLS is
    # deliberately NOT set: two binding mechanisms would be two sources of truth.
    ASPNETCORE_HTTP_PORTS=
WORKDIR /app
COPY --from=build /app ./
# 1654 is the `app` user baked into the chiselled images. It is NOT the Java app's 10001, the Go and
# Rust 65532, or the Node 1000 -- each base ships its own, and a uid the image does not define makes
# the kubelet refuse to start the container. deploy/dotnetwebapp/deployment.yaml must match.
USER 1654:1654
EXPOSE ${APP_INTERNAL_PORT}
# NO HEALTHCHECK, deliberately, and rustwebapp is the precedent. A chiselled base has no shell and no
# curl, so a probe would have to be an exec-form call into the app binary -- i.e. a --healthcheck flag
# on Program.cs. Kubernetes does not need it: deploy/dotnetwebapp/deployment.yaml probes /healthz over
# httpGet, and the KUBELET makes that request, not the container. A HEALTHCHECK here would serve only
# a local `docker run`, at the cost of new code on the shipping path.
ENTRYPOINT ["dotnet", "dotnetwebapp.dll"]
