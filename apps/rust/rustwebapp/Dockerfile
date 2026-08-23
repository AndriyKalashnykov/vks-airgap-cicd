# syntax=docker/dockerfile:1.26
# rustwebapp — the VENDORED/CACHED-DEPS case that ends in a distroless/static image.
#
# AIR-GAP: dependencies come from the BUILDER_IMAGE's warm cargo registry cache (built on the
# internet side by Dockerfile.builder, pushed to Harbor), and the build runs `--offline --locked`,
# which FAILS rather than silently reaching crates.io if that cache is incomplete.
#
# The runtime is distroless/static — the SAME base gowebapp uses — which works only because the
# binary is genuinely static. That is why the musl target and the CGO-free dependency set are
# load-bearing here and not a stylistic choice.
ARG BUILDER_IMAGE=rust:1.97-alpine
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build
WORKDIR /src
# musl-dev is needed to LINK statically on alpine; the crates themselves are pure Rust.
# hadolint ignore=DL3018
RUN apk add --no-cache musl-dev
COPY Cargo.toml Cargo.lock ./
COPY src ./src
# Tests then build, in ONE layer (hadolint DL3059), so a broken app cannot produce an image.
# --locked: the lockfile is authoritative; a resolver that wanted to CHANGE it would fail instead.
RUN cargo test --offline --locked --quiet \
    && cargo build --release --offline --locked \
    && strip target/release/rustwebapp

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT}
COPY --from=build /src/target/release/rustwebapp /rustwebapp
# distroless:nonroot already defaults to uid 65532 and has no shell and no package manager. State
# the UID EXPLICITLY anyway, so a base bump that changed it would be a visible diff.
USER 65532:65532
EXPOSE ${APP_INTERNAL_PORT}
# No HEALTHCHECK: distroless/static has no shell and no curl, and unlike Go this binary has no
# self-probe subcommand. Kubernetes probes the app over HTTP from the Deployment instead, which is
# the path that actually matters in the cluster; a container-level HEALTHCHECK would only serve
# `podman run`. Stated rather than silently omitted.
ENTRYPOINT ["/rustwebapp"]
