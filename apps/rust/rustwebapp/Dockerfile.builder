# syntax=docker/dockerfile:1.26
# Builder image for AIR-GAPPED CI: bakes this app's full cargo registry + git cache so the
# in-cluster build needs NO crates.io. Build on the INTERNET-connected jump box, push to Harbor.
#
# Rebuild whenever Cargo.toml / Cargo.lock change. scripts/14-builder-build.sh resolves the base
# image and the ARG NAME below PER APP via lib/apps.sh.
ARG RUST_IMAGE=rust:1.97-alpine
# RUST_IMAGE default is explicitly tagged; DL3006 can't see through the ARG.
# hadolint ignore=DL3006
FROM ${RUST_IMAGE}

WORKDIR /build
# Manifests FIRST so the dependency layer caches independently of the source.
COPY Cargo.toml Cargo.lock ./
# ⚠️ THE STUB TARGET IS LOAD-BEARING, and this is where the Java shape does NOT transfer.
# manifests-first caches correctly for npm / maven / nuget, but cargo REFUSES to parse a manifest
# that declares no target. MEASURED against this app's real Cargo.toml:
#     error: failed to parse manifest ... Caused by: no targets specified in the manifest
# so `cargo fetch` on a manifests-only layer cannot run at all. A throwaway src/main.rs satisfies
# the parser; the real source arrives with the COPY below and overwrites it.
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs
# `cargo fetch` populates $CARGO_HOME without compiling; the offline build then runs
# `cargo build --offline`, which is the only mode that cannot silently reach the network.
RUN cargo fetch --locked

COPY . .
# musl target so the binary is genuinely static and distroless/static works.
RUN cargo build --release --offline --locked
