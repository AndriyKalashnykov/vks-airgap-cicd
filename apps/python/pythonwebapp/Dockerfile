# syntax=docker/dockerfile:1.26
# pythonwebapp — THE INTERPRETED case, and the reason it is worth having among the six.
#
# AIR-GAP: Java/Go/Rust compile their dependencies away; Python cannot. Its deps must be present at
# RUNTIME. So the builder installs into a VIRTUALENV and the runtime stage copies that venv
# wholesale — the venv IS the artifact. BUILDER_IMAGE is the pre-baked image from
# Dockerfile.builder (built on the internet side, pushed to Harbor).
#
# The runtime is the SAME python base rather than distroless/python3: measured, distroless does not
# carry a venv's interpreter shims, and pinning an interpreter twice is a second source of truth.
ARG BUILDER_IMAGE=python:3.14-alpine
ARG RUNTIME_IMAGE=python:3.14-alpine

# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build
WORKDIR /src
# ⚠️ NO venv creation and NO pip install here -- BUILDER_IMAGE already carries BOTH venvs
# (/opt/venv = the app's deps, /opt/venv-dev = those plus pytest). This stage used to run
# `python -m venv /opt/venv && pip install -r requirements.txt` followed by
# `pip install pytest`, which is the air gap leaking twice over:
#   * PIP_NO_INDEX below is what makes it EXPLICIT: --no-cache-dir, which is what used to be here,
#     is a LOCAL CACHE knob and does not stop pip dialling PyPI. That confusion is the whole bug.
#   * MEASURED under --network none: the `pip install pytest` line gave 5 NameResolutionError
#     retries then "No matching distribution found for pytest".
#   * The venv line, by contrast, measured rc=0 offline -- `python -m venv` on an EXISTING dir
#     preserves site-packages, so every requirement reported "already satisfied" and pip never
#     dialled. It was wasted work rather than a leak, but it made the leak hard to see.
# Belt and braces: if anything here ever calls pip again, it fails LOUDLY instead of reaching out.
ENV PIP_NO_INDEX=1
COPY . .
# Tests run in the BUILD stage so a broken app cannot produce an image at all, using the DEV venv --
# which the runtime stage does not copy, so pytest never ships.
RUN /opt/venv-dev/bin/python -m pytest -q

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
WORKDIR /app
# The venv, then the source. uid 65532 matches the distroless nonroot convention the Go and Rust
# apps use, so every app in the demo runs as a non-root user with an EXPLICIT uid.
COPY --from=build --chown=65532:65532 /opt/venv /opt/venv
COPY --from=build --chown=65532:65532 /src/app.py ./app.py
USER 65532:65532
EXPOSE ${APP_INTERNAL_PORT}
# The probe uses python itself: the image has no curl, and adding one for a health check is attack
# surface for nothing. HEALTHCHECK flag values are LITERALS on purpose -- they are parsed at
# Dockerfile-parse time and are NOT variable-expanded (both ARG and ENV fail there).
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('APP_INTERNAL_PORT','8080')+'/healthz').status==200 else 1)"]
ENTRYPOINT ["python", "app.py"]
