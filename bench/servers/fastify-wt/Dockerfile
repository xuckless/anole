# Node WebTransport bench server (@fails-components/webtransport 1.6.8, Chromium's QUICHE,
# draft-02). Build from the repository root:
#   docker build -f bench/servers/fastify-wt/Dockerfile -t anole-bench/fastify-wt .
# trixie, not bookworm like the other Node images: the prebuilt QUICHE addon
# needs glibc 2.38 (bookworm has 2.36). The addon ships inside the npm tarball,
# so its install script (a source build fallback) is not needed.
FROM node:24.22.0-trixie-slim@sha256:7f486cabe892bff8fef04c0f7da8dba84a560be3e4e2740b7a86afc57ebec315
ENV NODE_ENV=production
WORKDIR /app
COPY bench/servers/fastify-wt/package.json bench/servers/fastify-wt/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY bench/servers/fastify-wt/server.mjs ./
ENTRYPOINT ["node", "server.mjs"]
