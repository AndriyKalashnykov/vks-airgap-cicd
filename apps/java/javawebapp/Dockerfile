# syntax=docker/dockerfile:1.26
# Multi-stage build for the air-gapped VKS CI/CD demo web UI.
# Built by the Tekton pipeline (kaniko) and pushed to the VKS-provided Harbor.

# ---- build stage ----------------------------------------------------------
# BUILDER_IMAGE defaults to public Maven (local `docker build` works online).
# In the air gap, CI passes BUILDER_IMAGE=<harbor>/cicd/javawebapp-builder:<ver> (a
# builder with this pom's dependencies pre-baked — see app/Dockerfile.builder and
# scripts/15-build-push-builder.sh) plus MVN_OFFLINE=-o so `package` needs no network.
ARG BUILDER_IMAGE=maven:3.9-eclipse-temurin-25
ARG RUNTIME_IMAGE=eclipse-temurin:25.0.4_7-jre-jammy
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
# No `clean`: the build context is a fresh git clone (nothing to clean), and it
# would need the clean plugin cached offline for no benefit.
RUN ./mvnw -B ${MVN_OFFLINE} -DskipTests package \
    && cp target/*.jar /workspace/app.jar

# ---- runtime stage --------------------------------------------------------
# RUNTIME_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime

ARG APP_INTERNAL_PORT=8080
ARG APP_UID=10001
ARG APP_GID=10001

ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT}

# ⚠️ NO apt-get HERE, DELIBERATELY. This stage is what kaniko builds IN-CLUSTER, where there is no
# egress, so `apt-get update` cannot work — MEASURED: a --network none build died here with
# "E: Unable to locate package curl". Two things used to live on this line and both are gone:
#
#   apt-get install curl  -- only ever fed the HEALTHCHECK below, which now probes with `java`
#                            itself (JavaWebappApplication --healthcheck). Every sibling app already
#                            probed with its own runtime; this one predated them all.
#   apt-get upgrade       -- patched base-OS CVEs. That protection now comes from the PIN:
#                            images/images.txt carries eclipse-temurin under a `# renovate:`
#                            annotation, so a CVE fix arrives as a base-image bump that is mirrored
#                            like any other image. That is already how the other four apps get
#                            patched -- two are distroless and have no package manager AT ALL, so
#                            they could never have done this.
#
# Residual, stated not hidden: between a temurin CVE fix and the Renovate bump landing, the
# deployed image carries the unpatched base. Nothing in this repo scans the built APP IMAGE today
# (trivy-fs scans the JAR), so that window is UNMEASURED either way -- removing the apt-get does not
# lose a gate, because there was none.

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
# DL3025 (new in hadolint 2.15) wants JSON/exec notation. It MUST NOT be applied here: the
# exec form does NOT expand variables, and this CMD interpolates ${APP_INTERNAL_PORT}. It
# would curl a LITERAL '${APP_INTERNAL_PORT}' and fail forever. Shell form is deliberate.
# NOTE: the ignore comment must be the LINE IMMEDIATELY BEFORE the instruction -- an
# intervening comment silently detaches it (measured: the finding came straight back).
# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
    CMD ["java", "-jar", "/app/app.jar", "--healthcheck"]

ENTRYPOINT ["sh", "-c", "java -jar /app/app.jar --server.port=${APP_INTERNAL_PORT}"]
