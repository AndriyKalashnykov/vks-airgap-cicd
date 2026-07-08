# syntax=docker/dockerfile:1.7
# Multi-stage build for the air-gapped VKS CI/CD demo web UI.
# Built by the Tekton pipeline (kaniko) and pushed to the VKS-provided Harbor.

# ---- build stage ----------------------------------------------------------
# BUILDER_IMAGE defaults to public Maven (local `docker build` works online).
# In the air gap, CI passes BUILDER_IMAGE=<harbor>/cicd/webui-builder:<ver> (a
# builder with this pom's dependencies pre-baked — see app/Dockerfile.builder and
# scripts/15-build-push-builder.sh) plus MVN_OFFLINE=-o so `package` needs no network.
ARG BUILDER_IMAGE=maven:3.9-eclipse-temurin-21
ARG RUNTIME_IMAGE=eclipse-temurin:21-jre-jammy
# BUILDER_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build
ARG MVN_OFFLINE=
WORKDIR /workspace

COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
COPY src/ src/
# With the pre-baked builder image the ~/.m2 cache already holds every dependency,
# so `-o` (offline) succeeds with no registry access. Locally MVN_OFFLINE is empty.
RUN ./mvnw -B ${MVN_OFFLINE} -DskipTests clean package \
    && cp target/*.jar /workspace/app.jar

# ---- runtime stage --------------------------------------------------------
# RUNTIME_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime

ARG APP_INTERNAL_PORT=8080
ARG APP_UID=10001
ARG APP_GID=10001

ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT}

# curl is needed by the HEALTHCHECK probe; slim install, no recommends.
# DL3008 ignored: the jammy curl is pulled fresh with the base image's security
# updates; pinning an exact patch version would break reproducibly on base bumps
# and defeats getting curl's own CVE fixes.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Non-root runtime user.
RUN groupadd -g ${APP_GID} app \
    && useradd -l -u ${APP_UID} -g app -s /usr/sbin/nologin -m app

WORKDIR /app
COPY --from=build --chown=app:app /workspace/app.jar /app/app.jar

USER ${APP_UID}
EXPOSE ${APP_INTERNAL_PORT}

# HEALTHCHECK flag durations are parsed at build time and are NOT variable-expanded
# (they must be literals); the CMD body runs under /bin/sh and DOES honor ${ENV}.
# 127.0.0.1 (not localhost) avoids the IPv6 ::1-first resolution trap.
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -sf "http://127.0.0.1:${APP_INTERNAL_PORT}/actuator/health/liveness" || exit 1

ENTRYPOINT ["sh", "-c", "java -jar /app/app.jar --server.port=${APP_INTERNAL_PORT}"]
