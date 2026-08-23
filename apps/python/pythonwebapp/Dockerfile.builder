# syntax=docker/dockerfile:1.26
# Builder image for AIR-GAPPED CI: bakes this app's wheels so the in-cluster build needs NO PyPI.
#
# PYTHON IS THE INTERPRETED CASE and it differs from Java/Go/Rust: the dependencies must be present
# at RUNTIME, not compiled away. So this image installs into a VIRTUALENV that the app Dockerfile
# COPYs wholesale into its runtime stage -- the venv IS the artifact.
#
# Rebuild whenever requirements.txt changes. scripts/14-builder-build.sh resolves the base image and
# the ARG NAME below PER APP via lib/apps.sh.
ARG PYTHON_IMAGE=python:3.14-alpine
# PYTHON_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${PYTHON_IMAGE}

WORKDIR /build
COPY requirements.txt ./
# --require-hashes is deliberately NOT used yet: requirements.txt carries no hashes. When it does,
# add it here -- an unhashed offline install is reproducible only as far as the wheel cache is.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

COPY . .
# The image's value is /opt/venv, which the app Dockerfile copies into its runtime stage.
