# Bun bench server. Build from the repository root:
#   docker build -f bench/servers/bun/Dockerfile -t anole-bench/bun .
FROM oven/bun:1.4.3-slim
ENV NODE_ENV=production
WORKDIR /app
COPY bench/servers/bun/package.json bench/servers/bun/bun.lock ./
RUN bun install --frozen-lockfile --production
COPY bench/servers/bun/server.ts bench/servers/bun/twelve.ts ./
ENTRYPOINT ["bun", "server.ts"]
