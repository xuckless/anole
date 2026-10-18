# Fastify 5 bench server (and its @grpc/grpc-js gRPC mode). Build from the repository root:
#   docker build -f bench/servers/fastify/Dockerfile -t anole-bench/fastify .
FROM node:24.22.0-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY bench/servers/fastify/package.json bench/servers/fastify/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY tests/grpc/proto/grpc/testing/ ./proto/grpc/testing/
COPY bench/servers/fastify/*.mjs ./
ENTRYPOINT ["node", "server.mjs"]
