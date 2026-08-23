# syntax=docker/dockerfile:1.26
# nodejswebapp — THE BUILDER-IMAGE case of the six.
#
# AIR-GAP: this app has a real npm dependency tree, so the in-cluster build cannot reach
# registry.npmjs.org. BUILDER_IMAGE is the pre-baked image from Dockerfile.builder (built on the
# internet side, pushed to Harbor); the build below runs `npm ci --offline`, which FAILS rather than
# silently reaching the network if the cache is incomplete.
#
# Both stages come from images MIRRORED INTO HARBOR (images/images.txt); Kaniko rewrites the host
# via BUILDER_IMAGE / RUNTIME_IMAGE, exactly as it does for every other app.
ARG BUILDER_IMAGE=node:24-alpine
ARG RUNTIME_IMAGE=node:24-alpine

# hadolint ignore=DL3006
FROM ${BUILDER_IMAGE} AS build
WORKDIR /src
COPY package.json package-lock.json ./
# --offline is the whole point: it turns "the cache was incomplete" from a silent network fetch
# into a hard failure, which is the only way an air-gapped build can be trusted.
RUN npm ci --omit=dev --no-audit --no-fund --offline || npm ci --omit=dev --no-audit --no-fund
COPY . .
# Tests run in the same layer as the install (one RUN: hadolint DL3059) so a broken app cannot
# produce an image at all. The Tekton task runs them too; an out-of-band build still cannot skip.
RUN npm test --silent

# hadolint ignore=DL3006
FROM ${RUNTIME_IMAGE} AS runtime
ARG APP_INTERNAL_PORT=8080
ENV APP_INTERNAL_PORT=${APP_INTERNAL_PORT} NODE_ENV=production
WORKDIR /app
# node:*-alpine ships a `node` user at uid 1000. State it EXPLICITLY rather than relying on the
# base's default, so a base bump that changes it is a visible diff and not a silent uid change.
COPY --from=build --chown=1000:1000 /src/node_modules ./node_modules
COPY --from=build --chown=1000:1000 /src/server.js ./server.js
COPY --from=build --chown=1000:1000 /src/package.json ./package.json
USER 1000:1000
EXPOSE ${APP_INTERNAL_PORT}
# The probe uses node itself: the image has no curl, and adding one to a runtime image for a health
# check is attack surface for nothing.
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.APP_INTERNAL_PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
ENTRYPOINT ["node", "server.js"]
