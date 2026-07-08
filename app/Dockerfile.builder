# syntax=docker/dockerfile:1.7
# Builder image for AIR-GAPPED CI: bakes this app's full Maven dependency +
# plugin cache so the in-cluster build (kaniko) and the Tekton maven-test task
# need NO network. Build this on the INTERNET-connected jump box (it pulls from
# Maven Central here), push to Harbor, then reference it as BUILDER_IMAGE in the
# app Dockerfile and as the maven-test task image.
#
# Rebuild whenever pom.xml changes. See scripts/15-build-push-builder.sh.
ARG MAVEN_IMAGE=maven:3.9-eclipse-temurin-21
# MAVEN_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${MAVEN_IMAGE}

WORKDIR /build
# Copy the whole project so a full `verify` warms compile, test AND package
# plugins/deps into ~/.m2 — the completeness the air-gapped build relies on.
COPY . .
# Full build online: populates ~/.m2 with every artifact the offline build needs.
RUN ./mvnw -B verify

# The image's value is its warm ~/.m2; the build output itself is discarded when
# this image is used only as a base whose /root/.m2 the app Dockerfile inherits.
