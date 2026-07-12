# syntax=docker/dockerfile:1
#
# gowebapp — the Go sibling of javawebapp.
#
# AIR-GAP: the build needs NO module proxy and NO pre-baked dependency cache, because the app is
# stdlib-only (see main.go). That is the whole reason it is stdlib-only: the Maven app needs a
# builder image with ~/.m2 baked in (apps/java/javawebapp/Dockerfile.builder) precisely because an
# in-cluster `mvn` cannot reach Maven Central. `go build` here reaches nothing.
#
# Both stages come from images MIRRORED INTO HARBOR (images/images.txt); Kaniko rewrites the host
# via BUILDER_IMAGE / RUNTIME_IMAGE, exactly as it does for the Java app.

ARG BUILDER_IMAGE=golang:1.25.5-bookworm
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot

# BUILDER_IMAGE default is explicitly tagged; DL3006 cannot see through the ARG.
# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build

WORKDIR /src

# No `go mod download` step and no cache mount: there are no external modules to fetch.
COPY go.mod ./
COPY *.go ./

# CGO_ENABLED=0 -> a fully static binary, which is what the distroless *static* base requires.
# Safe here ONLY because nothing in the dependency graph needs cgo (stdlib-only; no sqlite driver,
# no confluent-kafka). A cgo-requiring dep would build green and then panic at runtime.
# -trimpath + -ldflags -s -w: reproducible, smaller binary.
#
# Version/commit are NOT baked in with -ldflags -X: the app reads APP_VERSION / APP_COMMIT from the
# environment at runtime (main.go), exactly like javawebapp does, and the Deployment supplies them.
# Baking them in as well would create a second source of truth that silently disagrees.
RUN CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -ldflags="-s -w" \
        -o /out/gowebapp .

# Run the tests in the image build too, so a broken app cannot produce an image at all.
RUN CGO_ENABLED=0 go test ./...

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime

ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT}

# distroless:nonroot already runs as uid 65532 — no user creation needed, and no shell exists.
COPY --from=build /out/gowebapp /gowebapp

EXPOSE ${APP_INTERNAL_PORT}

# The distroless runtime has NO shell and NO curl, so the binary probes ITSELF (`-healthcheck`
# exits 0 iff /healthz returns 200). The flag DURATIONS are parsed at build time and are NOT
# variable-expanded — they must be literals (the CMD body is not, but here it is an exec-form
# array anyway).
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/gowebapp", "-healthcheck"]

ENTRYPOINT ["/gowebapp"]
