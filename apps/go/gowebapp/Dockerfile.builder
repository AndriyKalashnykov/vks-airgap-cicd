# syntax=docker/dockerfile:1.26
# Builder image for AIR-GAPPED CI: bakes this app's full Go MODULE cache so the in-cluster build
# (kaniko) and the Tekton go-test task need NO network. Build this on the INTERNET-connected jump
# box (it pulls from proxy.golang.org here), push to Harbor, then reference it as BUILDER_IMAGE in
# the app Dockerfile and as the go-test task image.
#
# WHY GO HAS ONE NOW. Until 2026-08-22 gowebapp was stdlib-only, so its air-gapped build fetched
# nothing and it needed no builder. It now depends on chi (its ONE real dependency, added so the
# demo actually exercises the dependency story), and every app carries a builder by decision -- one
# uniform pole instead of three, so the pipeline treats all apps identically.
#
# Rebuild whenever go.mod/go.sum change. See scripts/14-builder-build.sh, which resolves the base
# and the ARG NAME below PER APP via lib/apps.sh (app_builder_base / app_builder_arg).
ARG GO_IMAGE=golang:1.27.0-bookworm
# GO_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${GO_IMAGE}

WORKDIR /build
# go.mod + go.sum FIRST so the module download layer caches independently of the source.
COPY go.mod go.sum ./
# Populates /go/pkg/mod with every module the offline build needs.
RUN go mod download

# Then the source, and a full build+test so the BUILD cache (/root/.cache/go-build) is warm too --
# a module cache alone still leaves the offline build recompiling every dependency from source.
COPY . .
RUN CGO_ENABLED=0 go build -o /dev/null . && CGO_ENABLED=0 go vet ./...

# The image's value is its warm /go/pkg/mod + /root/.cache/go-build, which the app Dockerfile
# inherits when it uses this image as its builder base.
