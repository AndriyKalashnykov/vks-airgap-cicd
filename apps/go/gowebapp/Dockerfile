# syntax=docker/dockerfile:1
#
# gowebapp — the Go sibling of javawebapp.
#
# AIR-GAP: this app DOES have a dependency (chi), so the in-cluster build needs a warm module
# cache. It comes from apps/go/gowebapp/Dockerfile.builder, built on the internet side and pushed
# to Harbor; the pipeline passes it as BUILDER_IMAGE (Tekton -> kaniko-build.yaml -> this ARG),
# resolved per app by lib/apps.sh app_builder_image().
#
# This header claimed the opposite until 2026-08-22 -- "the build needs NO module proxy and NO
# pre-baked dependency cache, because the app is stdlib-only". That stopped being true the moment
# chi was added, and the file still COPY'd only go.mod (not go.sum), so the Kaniko build failed with
# `missing go.sum entry`. Both are fixed; the comment is kept as the record of why.
#
# The ARG DEFAULT below is deliberately the plain upstream golang image, NOT the builder: a bare
# local `podman build` has no Harbor to pull a builder from, and fetching chi from the proxy on a
# dev box is correct. In the pipeline the default is always overridden.
#
# Both stages come from images MIRRORED INTO HARBOR (images/images.txt); Kaniko rewrites the host
# via BUILDER_IMAGE / RUNTIME_IMAGE, exactly as it does for the Java app.

ARG BUILDER_IMAGE=golang:1.27.0-bookworm
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

# BUILDER_IMAGE default is explicitly tagged; DL3006 cannot see through the ARG.
# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build

WORKDIR /src

# GOTOOLCHAIN=local — the DEFAULT is `auto`, which is a NETWORK MODE. MEASURED (impl round,
# 2026-08-22): with a go.mod directive ABOVE the image's toolchain, `auto` responds by trying to
# DOWNLOAD one -- `go: downloading go1.28.0 ... toolchain not available` -- which inside air-gapped
# Kaniko is fatal, and no offline gate catches it because it only fires in a live build. `local`
# converts that silent network dependency into a clear local error:
#   `go.mod requires go >= 1.28.0 (running go 1.27.0)`.
# NOTE the header above says the build needs no module proxy. That is true of MODULES and was
# SILENT about the TOOLCHAIN, which is a different fetch on a different trigger.
ENV GOTOOLCHAIN=local

# go.mod AND go.sum. gowebapp is no longer stdlib-only -- it depends on chi -- so the build needs
# the checksum file, and the modules themselves come from the BUILDER IMAGE's warm /go/pkg/mod
# (apps/go/gowebapp/Dockerfile.builder, built on the internet side and pushed to Harbor). This
# comment used to say "there are no external modules to fetch"; that stopped being true on
# 2026-08-22 and the COPY was one file short, which would have failed the build outright.
COPY go.mod go.sum ./
COPY *.go ./

# -mod=mod against the builder's warm module cache. GOFLAGS is set here rather than on each command
# so `go test` and `go build` below cannot disagree about it.
ENV GOFLAGS=-mod=mod

# CGO_ENABLED=0 -> a fully static binary, which is what the distroless *static* base requires.
# Safe here ONLY because nothing in the dependency graph needs cgo (stdlib-only; no sqlite driver,
# no confluent-kafka). A cgo-requiring dep would build green and then panic at runtime.
# -trimpath + -ldflags -s -w: reproducible, smaller binary.
#
# Version/commit are NOT baked in with -ldflags -X: the app reads APP_VERSION / APP_COMMIT from the
# environment at runtime (main.go), exactly like javawebapp does, and the Deployment supplies them.
# Baking them in as well would create a second source of truth that silently disagrees.
# Tests run FIRST, in the same layer as the build (one RUN: hadolint DL3059), so a broken app
# cannot produce an image at all — the Tekton pipeline also runs them in its own `go-test` task,
# but an image built out-of-band still cannot skip them.
RUN CGO_ENABLED=0 go test ./... \
    && CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -ldflags="-s -w" \
        -o /out/gowebapp .

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime

ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT}

# distroless:nonroot already defaults to uid 65532 and the image has no shell and no package
# manager, so there is no user to create. State the UID EXPLICITLY anyway: relying on the base
# image's default is implicit (a base bump could change it), a scanner cannot see through the ARG
# (trivy DS-0002), and it must match deploy/gowebapp/deployment.yaml's runAsUser — if the two ever
# disagree, the kubelet refuses to start the container.
COPY --from=build /out/gowebapp /gowebapp

ARG APP_UID=65532
ARG APP_GID=65532
USER ${APP_UID}:${APP_GID}

EXPOSE ${APP_INTERNAL_PORT}

# The distroless runtime has NO shell and NO curl, so the binary probes ITSELF (`-healthcheck`
# exits 0 iff /healthz returns 200). The flag DURATIONS are parsed at build time and are NOT
# variable-expanded — they must be literals (the CMD body is not, but here it is an exec-form
# array anyway).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/gowebapp", "-healthcheck"]

ENTRYPOINT ["/gowebapp"]
