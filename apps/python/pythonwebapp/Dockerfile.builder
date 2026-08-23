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

# A SECOND venv carrying the TEST tooling. Two venvs, not one, because the runtime stage copies
# /opt/venv WHOLESALE (../Dockerfile: COPY --from=build /opt/venv /opt/venv) -- so anything installed
# into it SHIPS. pytest in a production image is bloat and attack surface for nothing.
#
# It must be baked HERE, on the internet side. MEASURED: the app build stage's
# `pip install pytest` produced 5 NameResolutionError retries then "No matching distribution found
# for pytest" under --network none. There is also no wheelhouse to fall back on -- measured, this
# image's pip cache is EMPTY (`ls /root/.cache/pip` -> No such file), because --no-cache-dir above
# deliberately keeps it that way. So the VENV is the only carrier, and the test venv needs its own.
#
# It gets its OWN full install (requirements + pytest), NOT --system-site-packages.
# MEASURED: `--system-site-packages` exposes the SYSTEM site-packages, and Flask is in /opt/venv,
# which is not the system -- so `pytest` collected and died with
#     app.py:23: from flask import Flask, Response
#     E  ModuleNotFoundError: No module named 'flask'
# The duplicate Flask (636 KB, measured) exists ONLY in the builder; the runtime stage copies
# /opt/venv, never /opt/venv-dev, so nothing about the shipped image changes.
RUN python -m venv /opt/venv-dev \
    && /opt/venv-dev/bin/pip install --no-cache-dir -r requirements.txt pytest

COPY . .
# The image's value is /opt/venv, which the app Dockerfile copies into its runtime stage.
