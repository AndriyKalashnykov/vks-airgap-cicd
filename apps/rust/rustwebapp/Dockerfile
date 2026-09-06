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
ARG BUILDER_IMAGE=rust:1.98-alpine
ARG RUNTIME_IMAGE=gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build
# ⚠️ /build, NOT /src — AND THAT IS THE POINT. Dockerfile.builder builds at /build, so the builder
# image already carries a warm `/build/target` (111.6 MB of compiled dependencies). cargo's target
# dir is PATH-ANCHORED, so building at /src threw all of it away and recompiled from scratch every
# time. MEASURED in the real builder image with --network none: 26s at /src vs 13s at /build;
# together with the `--release` test below, 26s -> 4s.
#
# Only RUST benefits. Measured the same way for all six apps: java (~/.m2), go ($GOCACHE), dotnet
# (~/.nuget) and python (a venv at /opt) cache OUTSIDE the working directory, so their times were
# identical at /src and /build; nodejs's node_modules IS path-anchored but `npm ci` wipes it anyway.
# Do not "fix" the other five to match — there is nothing to gain.
#
# ⚠️ WHY A WARM target/ IS SAFE, and it is NOT the builder-freshness stamp: that hash covers
# Dockerfile.builder and the dependency manifests, NOT src/. What makes it safe is cargo's own
# fingerprinting, which is content- and size-aware rather than "is the source newer". Measured three
# ways, including source deliberately made 92 minutes OLDER than the cached artefact, and source
# with an mtime set exactly equal to the builder's: recompiled FRESH every time.
WORKDIR /build
# musl-dev is needed to LINK statically on alpine; the crates themselves are pure Rust.
# hadolint ignore=DL3018
RUN apk add --no-cache musl-dev
COPY Cargo.toml Cargo.lock ./
# Land the source elsewhere and purge inside the RUN below — a separate `RUN rm -rf` would cost an
# extra kaniko layer and a full-filesystem snapshot. The purge matters because the builder's own
# `COPY . .` left ITS copy of src/ here: without it, a file the app DELETES would survive.
COPY src /tmp/newsrc
# Tests then build, in ONE layer (hadolint DL3059), so a broken app cannot produce an image.
# --locked: the lockfile is authoritative; a resolver that wanted to CHANGE it would fail instead.
# ⚠️ `--release` ON THE TEST IS THE PERFORMANCE FIX, and it is one word. A dev-profile `cargo test`
# followed by `cargo build --release` compiles the ENTIRE dependency graph TWICE, into target/debug
# and target/release. Sharing the profile makes the second compile reuse the first's artefacts.
# MEASURED in the real builder image, --network none: 26s -> 16s, with all 4 tests still running.
# (`RUN_TESTS=0` was considered and REJECTED: it saves less AND makes the path that SHIPS the path
# that never runs tests.)
# Cost, stated so nobody re-derives it: --release disables debug_assertions and integer-overflow
# checks. None of this app's tests rely on either; a future test that does would be silently
# weakened, so keep k8s/tekton/tasks/rust-test.yaml on the DEV profile — that keeps both profiles
# exercised in the pipeline and makes this copy complementary rather than duplicate.
#
# `strip` is NOT here: Cargo.toml already sets [profile.release] strip = true. MEASURED — the
# binary is byte-identical (1,418,216 bytes) with and without it, so the explicit strip was dead.
RUN rm -rf /build/src && mv /tmp/newsrc /build/src \
    && cargo test --release --offline --locked --quiet \
    && cargo build --release --offline --locked

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT}
COPY --from=build /build/target/release/rustwebapp /rustwebapp
# distroless:nonroot already defaults to uid 65532 and has no shell and no package manager. State
# the UID EXPLICITLY anyway, so a base bump that changed it would be a visible diff.
USER 65532:65532
EXPOSE ${APP_INTERNAL_PORT}
# No HEALTHCHECK: distroless/static has no shell and no curl, and unlike Go this binary has no
# self-probe subcommand. Kubernetes probes the app over HTTP from the Deployment instead, which is
# the path that actually matters in the cluster; a container-level HEALTHCHECK would only serve
# `podman run`. Stated rather than silently omitted.
ENTRYPOINT ["/rustwebapp"]
